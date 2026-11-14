import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../codecs/tuya_codec.dart';
import '../storage/secret_store.dart';
import '../template/template_renderer.dart';
import '../transports/packet_tap.dart';
import '../transports/udp_transport.dart';
import 'channels.dart';
import 'device.dart';

/// A status update a Tuya device sent on its own (command 8).
class TuyaPush {
  const TuyaPush(this.deviceId, this.body);

  final String deviceId;
  final Map<String, Object?> body;
}

/// Starts the timer that drives a connection's heartbeat. Tests pass one
/// they fire by hand.
typedef TuyaHeartbeatTimer = Timer Function(
  Duration every,
  void Function() beat,
);

Timer _periodic(Duration every, void Function() beat) =>
    Timer.periodic(every, (_) => beat());

Uint8List _secureRandom(int length) {
  final random = Random.secure();
  return Uint8List.fromList([
    for (var i = 0; i < length; i++) random.nextInt(256),
  ]);
}

/// Tuya local protocol over a persistent TCP connection per device.
///
/// The rendered command is `{"cmd": "control", "dps": {...}}` or
/// `{"cmd": "query"}`. The channel adds the device id and timestamp, encrypts
/// with the local key from the secret store (setting `localKey`), and waits
/// for the reply with the same command code. A device accepts one local
/// connection, so the connection is kept and reused.
///
/// The protocol version is the device's `version` setting, else the
/// transport's `version`, else 3.3. A 3.4 or 3.5 connection first agrees a
/// session key ([TuyaSession]) and sends `0x0d` control and `0x10` query
/// frames. Their replies nest the data points under `data`, which the
/// channel lifts to `dps` so drivers read one shape.
class TuyaChannel implements DriverChannel {
  TuyaChannel(
    this._secrets, {
    this._tap,
    this._renderer = const TemplateRenderer(),
    DateTime Function()? clock,
    this._connectTimeout = const Duration(seconds: 3),
    this._heartbeatEvery = const Duration(seconds: 10),
    TuyaHeartbeatTimer? heartbeatTimer,
    Uint8List Function(int length)? random,
  }) : _clock = clock ?? DateTime.now,
       _heartbeatTimer = heartbeatTimer ?? _periodic,
       _random = random ?? _secureRandom;

  final SecretStore _secrets;
  final PacketTap? _tap;
  final TemplateRenderer _renderer;
  final DateTime Function() _clock;
  final Duration _connectTimeout;
  final Duration _heartbeatEvery;
  final TuyaHeartbeatTimer _heartbeatTimer;
  final Uint8List Function(int length) _random;
  final _connections = <String, _TuyaConnection>{};
  final _pushes = StreamController<TuyaPush>.broadcast();

  Stream<TuyaPush> get pushes => _pushes.stream;

  /// The protocol version [device] speaks.
  static String versionOf(Device device, Map<String, Object?> options) {
    final raw = device.settings['version'] ?? options['version'] ?? '3.3';
    final version = '$raw'.trim();
    if (!tuyaProtocolVersions.contains(version)) {
      throw ArgumentError(
        '${device.id} has Tuya version "$version", which must be one of '
        '${tuyaProtocolVersions.join(', ')}',
      );
    }
    return version;
  }

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final device = request.device;
    final rendered = _renderer.render(request.command, request.context);
    if (rendered is! Map) {
      throw ArgumentError('a Tuya command renders to an object');
    }
    final version = versionOf(device, request.manifest.transport.options);
    final legacy = version == '3.3';
    final isControl = switch (rendered['cmd'] ?? 'control') {
      'control' => true,
      'query' => false,
      final other => throw ArgumentError('unknown Tuya cmd "$other"'),
    };
    final command = isControl
        ? (legacy ? TuyaCommand.control : TuyaCommand.controlNew)
        : (legacy ? TuyaCommand.dpQuery : TuyaCommand.dpQueryNew);
    final devId = device.settings['devId'];
    if (devId is! String) {
      throw ArgumentError('${device.id} has no devId setting');
    }
    final keyName = deviceSecretKey(device.id, 'localKey');
    final localKey = await _secrets.read(keyName);
    if (localKey == null) throw MissingSecretException(keyName);

    final seconds = _clock().millisecondsSinceEpoch ~/ 1000;
    final dps = rendered['dps'] ?? const {};
    final Map<String, Object?> body = switch ((legacy, isControl)) {
      (true, true) => {
        'devId': devId,
        'uid': devId,
        't': '$seconds',
        'dps': dps,
      },
      (true, false) => {
        'gwId': devId,
        'devId': devId,
        'uid': devId,
        't': '$seconds',
      },
      (false, true) => {
        'protocol': 5,
        't': seconds,
        'data': {'dps': dps},
      },
      (false, false) => const {},
    };

    final reliability = request.manifest.reliability;
    final timeout = Duration(milliseconds: reliability.timeoutMs);
    final port = device.port ?? request.manifest.transport.port ?? 6668;
    for (var attempt = 0; attempt <= reliability.retries; attempt++) {
      try {
        final connection = await _connection(
          device,
          port,
          devId,
          localKey,
          version,
          timeout,
        );
        final frame = await connection.request(command, body, timeout);
        if (frame.retcode != null && frame.retcode != 0) {
          throw CommandFailedException(
            '${device.id} returned code ${frame.retcode}',
          );
        }
        return ChannelReply(liftDps(frame.body));
      } on TimeoutException {
        continue;
      } on SocketException {
        _drop(device.id);
        continue;
      }
    }
    _drop(device.id);
    throw TransportTimeoutException(
      'no reply from ${device.id} at ${device.host}:$port',
    );
  }

  /// A v3.4 or v3.5 body nests its data points as `data.dps`. They are
  /// copied to `dps`, as tinytuya does, so a driver's `$.dps` reads both.
  static Map<String, Object?>? liftDps(Map<String, Object?>? body) {
    if (body == null || body.containsKey('dps')) return body;
    final data = body['data'];
    if (data is Map && data['dps'] is Map) {
      return {...body, 'dps': data['dps']};
    }
    return body;
  }

  Future<_TuyaConnection> _connection(
    Device device,
    int port,
    String devId,
    String localKey,
    String version,
    Duration timeout,
  ) async {
    final codec = TuyaCodec(localKey, version: version, random: _random);
    final existing = _connections[device.id];
    if (existing != null &&
        existing.host == device.host &&
        existing.version == codec.version &&
        !existing.closed) {
      return existing;
    }
    existing?.close();
    final Socket socket;
    try {
      socket = await Socket.connect(
        device.host,
        port,
        timeout: _connectTimeout,
      );
    } on SocketException catch (e) {
      throw TransportTimeoutException(
        'cannot reach ${device.id} at ${device.host}:$port (${e.message})',
      );
    }
    final connection = _TuyaConnection(
      device.id,
      device.host,
      devId,
      socket,
      codec,
      _tap,
      (body) {
        if (!_pushes.isClosed) _pushes.add(TuyaPush(device.id, body));
      },
      _heartbeatEvery,
      _heartbeatTimer,
    );
    if (codec.negotiatesSession) {
      try {
        await connection.negotiate(
          Uint8List.fromList(utf8.encode(localKey)),
          _random(TuyaSession.nonceLength),
          timeout,
        );
      } catch (_) {
        connection.close();
        rethrow;
      }
    }
    _connections[device.id] = connection;
    return connection;
  }

  void _drop(String deviceId) => _connections.remove(deviceId)?.close();

  Future<void> close() async {
    for (final c in _connections.values) {
      c.close();
    }
    _connections.clear();
    await _pushes.close();
  }
}

class _TuyaConnection {
  _TuyaConnection(
    this.deviceId,
    this.host,
    this._devId,
    this._socket,
    this._codec,
    this._tap,
    this._onPush,
    this._heartbeatEvery,
    TuyaHeartbeatTimer heartbeatTimer,
  ) : version = _codec.version {
    _socket.listen(
      _onData,
      onError: (_) => close(),
      onDone: close,
      cancelOnError: true,
    );
    // A write the device reset is reported on done; close handles it.
    unawaited(_socket.done.then((_) {}, onError: (Object _) => close()));
    _heartbeat = heartbeatTimer(_heartbeatEvery, _beat);
  }

  final String deviceId;
  final String host;
  final String version;
  final String _devId;
  final Socket _socket;
  TuyaCodec _codec;
  final PacketTap? _tap;
  final void Function(Map<String, Object?> body) _onPush;
  final Duration _heartbeatEvery;
  final _splitter = TuyaFrameSplitter();
  final _waiting = <int, Completer<TuyaFrame>>{};
  Timer? _heartbeat;
  var _lastRequest = DateTime.now();
  var _unanswered = 0;
  var _seq = 0;
  var _negotiating = false;
  var closed = false;

  /// Agrees the session key under [keyBytes], the local key the codec
  /// holds now, then switches the codec to it. A device that answers with a
  /// proof under another key fails the command. One that does not answer
  /// times out.
  Future<void> negotiate(
    Uint8List keyBytes,
    Uint8List localNonce,
    Duration timeout,
  ) async {
    _negotiating = true;
    try {
      final answer = await _await(
        TuyaCommand.sessionKeyResponse,
        timeout,
        () => _sendBytes(TuyaCommand.sessionKeyStart, localNonce),
      );
      final remote = TuyaSession.remoteNonce(
        answer.plain ?? Uint8List(0),
        keyBytes,
        localNonce,
      );
      if (remote == null) {
        throw CommandFailedException(
          '$deviceId refused the Tuya $version session: check its local key '
          'and version',
        );
      }
      _sendBytes(
        TuyaCommand.sessionKeyFinish,
        TuyaSession.hmac(keyBytes, remote),
      );
      _codec = _codec.withSessionKey(
        TuyaSession.sessionKey(version, keyBytes, localNonce, remote),
      );
    } on TimeoutException {
      throw TransportTimeoutException(
        'no answer from $deviceId at $host to the Tuya $version session '
        'handshake',
      );
    } finally {
      _negotiating = false;
    }
  }

  Future<TuyaFrame> request(
    int command,
    Map<String, Object?> body,
    Duration timeout,
  ) {
    if (closed) throw const SocketException('connection closed');
    _lastRequest = DateTime.now();
    return _await(command, timeout, () => _send(command, body));
  }

  Future<TuyaFrame> _await(int reply, Duration timeout, void Function() send) {
    if (closed) throw const SocketException('connection closed');
    final waiter = Completer<TuyaFrame>();
    _waiting[reply]?.completeError(TimeoutException('superseded'));
    _waiting[reply] = waiter;
    send();
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiting[reply], waiter)) _waiting.remove(reply);
        throw TimeoutException('no reply to command $reply');
      },
    );
  }

  void _onData(Uint8List chunk) {
    for (final raw in _splitter.add(chunk)) {
      _tap?.record(
        CapturedPacket(
          transport: 'tuya',
          direction: PacketDirection.incoming,
          remote: '$host:${_socket.remotePort}',
          bytes: raw,
        ),
      );
      try {
        final frame = _codec.decodeBytes(raw);
        if (frame.command == TuyaCommand.sessionKeyResponse) {
          _onFrame(frame);
        } else {
          _onFrame(
            TuyaFrame(
              seq: frame.seq,
              command: frame.command,
              retcode: frame.retcode,
              body: TuyaChannel.liftDps(
                TuyaCodec.parseBody(frame.plain!, frame.command),
              ),
            ),
          );
        }
      } on TuyaDecodeException catch (e) {
        final refused = e.deviceMessage;
        final waiter = refused == null || e.command == null
            ? null
            : _waiting.remove(e.command);
        if (refused != null && waiter != null && !waiter.isCompleted) {
          waiter.completeError(
            CommandFailedException('$deviceId refused the command: $refused'),
          );
        }
      } catch (_) {
        // One bad frame from the device must not take the engine down.
      }
    }
  }

  void _onFrame(TuyaFrame frame) {
    _unanswered = 0;
    final waiter = _waiting.remove(frame.command);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(frame);
    } else if (frame.command == TuyaCommand.status && frame.body != null) {
      _onPush(frame.body!);
    }
  }

  /// A device drops a local connection that stays quiet, and then pushes
  /// nothing until the next command, so an idle connection sends a
  /// heartbeat. Two heartbeats in a row with no frame back mean the device
  /// is gone.
  void _beat() {
    if (closed || _negotiating) return;
    if (_unanswered >= 2) {
      close();
      return;
    }
    if (DateTime.now().difference(_lastRequest) < _heartbeatEvery) return;
    _unanswered++;
    _send(TuyaCommand.heartbeat, {'gwId': _devId, 'devId': _devId});
  }

  void _send(int command, Map<String, Object?> body) =>
      _write(_codec.encode(seq: ++_seq, command: command, body: body));

  void _sendBytes(int command, Uint8List payload) => _write(
    _codec.encodeBytes(seq: ++_seq, command: command, payload: payload),
  );

  void _write(Uint8List frame) {
    _tap?.record(
      CapturedPacket(
        transport: 'tuya',
        direction: PacketDirection.outgoing,
        remote: '$host:${_socket.remotePort}',
        bytes: frame,
      ),
    );
    _socket.add(frame);
  }

  void close() {
    if (closed) return;
    closed = true;
    _heartbeat?.cancel();
    for (final w in _waiting.values) {
      if (!w.isCompleted) {
        w.completeError(const SocketException('connection closed'));
      }
    }
    _waiting.clear();
    _socket.destroy();
  }
}
