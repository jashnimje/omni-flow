import 'dart:async';
import 'dart:io';
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

/// Tuya local protocol over a persistent TCP connection per device.
///
/// The rendered command is `{"cmd": "control", "dps": {...}}` or
/// `{"cmd": "query"}`. The channel adds the device id and timestamp, encrypts
/// with the local key from the secret store (setting `localKey`), and waits
/// for the reply with the same command code. A device accepts one local
/// connection, so the connection is kept and reused.
class TuyaChannel implements DriverChannel {
  TuyaChannel(
    this._secrets, {
    this._tap,
    this._renderer = const TemplateRenderer(),
    DateTime Function()? clock,
    this._connectTimeout = const Duration(seconds: 3),
  }) : _clock = clock ?? DateTime.now;

  final SecretStore _secrets;
  final PacketTap? _tap;
  final TemplateRenderer _renderer;
  final DateTime Function() _clock;
  final Duration _connectTimeout;
  final _connections = <String, _TuyaConnection>{};
  final _pushes = StreamController<TuyaPush>.broadcast();

  Stream<TuyaPush> get pushes => _pushes.stream;

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final device = request.device;
    final rendered = _renderer.render(request.command, request.context);
    if (rendered is! Map) {
      throw ArgumentError('a Tuya command renders to an object');
    }
    final command = switch (rendered['cmd'] ?? 'control') {
      'control' => TuyaCommand.control,
      'query' => TuyaCommand.dpQuery,
      final other => throw ArgumentError('unknown Tuya cmd "$other"'),
    };
    final devId = device.settings['devId'];
    if (devId is! String) {
      throw ArgumentError('${device.id} has no devId setting');
    }
    final keyName = deviceSecretKey(device.id, 'localKey');
    final localKey = await _secrets.read(keyName);
    if (localKey == null) throw MissingSecretException(keyName);

    final t = (_clock().millisecondsSinceEpoch ~/ 1000).toString();
    final body = command == TuyaCommand.control
        ? {
            'devId': devId,
            'uid': devId,
            't': t,
            'dps': rendered['dps'] ?? const {},
          }
        : {'gwId': devId, 'devId': devId, 'uid': devId, 't': t};

    final reliability = request.manifest.reliability;
    final port = device.port ?? request.manifest.transport.port ?? 6668;
    for (var attempt = 0; attempt <= reliability.retries; attempt++) {
      final connection = await _connection(device, port, TuyaCodec(localKey));
      try {
        final frame = await connection.request(
          command,
          body,
          Duration(milliseconds: reliability.timeoutMs),
        );
        if (frame.retcode != null && frame.retcode != 0) {
          throw CommandFailedException(
            '${device.id} returned code ${frame.retcode}',
          );
        }
        return ChannelReply(frame.body);
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

  Future<_TuyaConnection> _connection(
    Device device,
    int port,
    TuyaCodec codec,
  ) async {
    final existing = _connections[device.id];
    if (existing != null && existing.host == device.host && !existing.closed) {
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
      socket,
      codec,
      _tap,
      (body) {
        if (!_pushes.isClosed) _pushes.add(TuyaPush(device.id, body));
      },
    );
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
    this._socket,
    this._codec,
    this._tap,
    this._onPush,
  ) {
    _socket.listen(
      _onData,
      onError: (_) => close(),
      onDone: close,
      cancelOnError: true,
    );
    // A write the device reset is reported on done; close handles it.
    unawaited(_socket.done.then((_) {}, onError: (Object _) => close()));
  }

  final String deviceId;
  final String host;
  final Socket _socket;
  final TuyaCodec _codec;
  final PacketTap? _tap;
  final void Function(Map<String, Object?> body) _onPush;
  final _splitter = TuyaFrameSplitter();
  final _waiting = <int, Completer<TuyaFrame>>{};
  var _seq = 0;
  var closed = false;

  Future<TuyaFrame> request(
    int command,
    Map<String, Object?> body,
    Duration timeout,
  ) {
    if (closed) throw const SocketException('connection closed');
    final waiter = Completer<TuyaFrame>();
    _waiting[command]?.completeError(TimeoutException('superseded'));
    _waiting[command] = waiter;
    final frame = _codec.encode(seq: ++_seq, command: command, body: body);
    _tap?.record(
      CapturedPacket(
        transport: 'tuya',
        direction: PacketDirection.outgoing,
        remote: '$host:${_socket.remotePort}',
        bytes: frame,
      ),
    );
    _socket.add(frame);
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiting[command], waiter)) _waiting.remove(command);
        throw TimeoutException('no reply to command $command');
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
      final TuyaFrame frame;
      try {
        frame = _codec.decode(raw);
      } on TuyaDecodeException {
        continue;
      }
      final waiter = _waiting.remove(frame.command);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(frame);
      } else if (frame.command == TuyaCommand.status && frame.body != null) {
        _onPush(frame.body!);
      }
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    for (final w in _waiting.values) {
      if (!w.isCompleted) {
        w.completeError(const SocketException('connection closed'));
      }
    }
    _waiting.clear();
    _socket.destroy();
  }
}
