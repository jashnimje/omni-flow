import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'adb_key.dart';
import 'adb_tls.dart';
import 'adb_protocol.dart';
import 'raw_link.dart';

/// The connection ended. [acknowledged] says whether the device had already
/// accepted the stream, so whether the command may have run.
class AdbConnectionClosedException implements Exception {
  AdbConnectionClosedException(this.message, {this.acknowledged = false});

  final String message;
  final bool acknowledged;

  @override
  String toString() => 'AdbConnectionClosedException: $message';
}

/// The device did not accept the key: it timed out on the prompt, or asked
/// for a token again after the public key was sent.
class AdbAuthException implements Exception {
  AdbAuthException(this.message, {required this.promptShown});

  final String message;

  /// True once the public key was sent and the TV showed its prompt.
  final bool promptShown;

  @override
  String toString() => 'AdbAuthException: $message';
}

/// The device does not know the key, and the caller did not allow offering
/// it (which would show "Allow USB debugging?" on the TV).
class AdbKeyNotAllowedException implements Exception {
  @override
  String toString() => 'AdbKeyNotAllowedException';
}

/// The device switched to TLS and then refused this engine's key, which a
/// Wireless Debugging device does until it is paired with its code.
class AdbTlsRefusedException implements Exception {
  @override
  String toString() =>
      'AdbTlsRefusedException: the device did not accept the key over TLS';
}

/// The device presented a TLS certificate other than the one pinned for
/// it, so the host that answered is not the paired device.
class AdbIdentityException implements Exception {
  @override
  String toString() =>
      'AdbIdentityException: the device is not the one that was paired';
}

class AdbHandshakeTimeoutException implements Exception {
  @override
  String toString() => 'AdbHandshakeTimeoutException';
}

class AdbShellTimeoutException implements Exception {
  AdbShellTimeoutException({required this.acknowledged});

  final bool acknowledged;

  @override
  String toString() => 'AdbShellTimeoutException';
}

class AdbStreamRefusedException implements Exception {
  @override
  String toString() =>
      'AdbStreamRefusedException: the device refused the shell';
}

const _maxShellOutput = 256 * 1024;

/// One authenticated ADB transport to a device, carrying any number of
/// shell streams.
class AdbConnection {
  AdbConnection._(this._link, this.host, this.port, this._acceptCertificate) {
    _link.listen(_onData, _end);
  }

  /// Connects and authenticates with [key].
  ///
  /// The first TOKEN gets a signature. A second TOKEN means the device does
  /// not know the key, so the public key goes out and the device shows
  /// "Allow USB debugging?". [onPrompt] runs then, and the wait for the
  /// user's answer is [pairingTimeout] instead of [handshakeTimeout]. With
  /// [offerKey] false the key is never offered, and a second TOKEN throws
  /// [AdbKeyNotAllowedException]. [onOpened] gets the connection as soon as
  /// the socket is up, before the handshake, so the caller can close it.
  ///
  /// A Wireless Debugging device answers the CNXN with STLS. The host
  /// answers STLS, the socket becomes TLS 1.3 with [key]'s certificate as
  /// the client certificate, and the device's CNXN follows inside it, with
  /// no AUTH: the device knows the key from pairing or refuses the
  /// handshake, which throws [AdbTlsRefusedException].
  ///
  /// [acceptCertificate] judges the device's TLS certificate: false ends
  /// the handshake with [AdbIdentityException], so a host that is not the
  /// paired device gets nothing.
  static Future<AdbConnection> connect(
    String host,
    int port, {
    required AdbHostKey key,
    required String keyName,
    Duration connectTimeout = const Duration(seconds: 3),
    Duration handshakeTimeout = const Duration(seconds: 5),
    Duration pairingTimeout = const Duration(seconds: 60),
    void Function()? onPrompt,
    void Function(AdbConnection connection)? onOpened,
    bool offerKey = true,
    bool Function(X509Certificate certificate)? acceptCertificate,
  }) async {
    final link = await RawLink.connect(host, port, timeout: connectTimeout);
    final connection = AdbConnection._(link, host, port, acceptCertificate);
    onOpened?.call(connection);
    try {
      await connection._handshake(
        key,
        keyName,
        handshakeTimeout,
        pairingTimeout,
        onPrompt,
        offerKey,
      );
      return connection;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  final RawLink _link;
  final bool Function(X509Certificate certificate)? _acceptCertificate;
  var _certificateRefused = false;

  /// The device's TLS certificate, once the connection is TLS.
  X509Certificate? get peerCertificate => _link.peerCertificate;

  /// Where the connection was opened.
  final String host;
  final int port;
  final _reader = AdbMessageReader();
  final _inbox = ListQueue<AdbMessage>();
  Completer<void>? _arrived;
  final _streams = <int, _Stream>{};

  /// Whether another stream (a file transfer, a long command) is open.
  bool get busy => _streams.isNotEmpty;
  var _nextLocalId = 1;
  var _ready = false;
  var _closed = false;
  var _deviceMaxData = adbMaxData;

  /// The device's CNXN banner, `device::ro.product.name=...;...`.
  String banner = '';

  bool get isClosed => _closed;

  /// Whether the device switched the connection to TLS (Wireless
  /// Debugging).
  bool get isTls => _tls;
  var _tls = false;

  Future<void> _handshake(
    AdbHostKey key,
    String keyName,
    Duration handshakeTimeout,
    Duration pairingTimeout,
    void Function()? onPrompt,
    bool offerKey,
  ) async {
    _send(
      AdbMessage(
        AdbCommand.cnxn,
        adbVersion,
        adbHostMaxData,
        Uint8List.fromList(ascii.encode('host::\x00')),
      ),
    );
    var signed = false;
    var offeredKey = false;
    var deadline = DateTime.now().add(handshakeTimeout);
    while (true) {
      final AdbMessage message;
      try {
        message = await _nextHandshakeMessage(deadline);
      } on TimeoutException {
        if (offeredKey) {
          throw AdbAuthException(
            'the device did not accept the key in time',
            promptShown: true,
          );
        }
        throw AdbHandshakeTimeoutException();
      }
      if (message.command == AdbCommand.stls && !_tls) {
        await _startTls(key, deadline);
        continue;
      }
      if (message.command == AdbCommand.cnxn) {
        _deviceMaxData = message.arg1 == 0 ? adbMaxData : message.arg1;
        banner = utf8
            .decode(message.data, allowMalformed: true)
            .replaceAll('\x00', '');
        _ready = true;
        return;
      }
      if (message.command != AdbCommand.auth ||
          message.arg0 != AdbAuthType.token) {
        continue;
      }
      if (!signed) {
        signed = true;
        _send(
          AdbMessage(
            AdbCommand.auth,
            AdbAuthType.signature,
            0,
            key.sign(message.data),
          ),
        );
      } else if (!offeredKey) {
        if (!offerKey) throw AdbKeyNotAllowedException();
        offeredKey = true;
        _send(
          AdbMessage(
            AdbCommand.auth,
            AdbAuthType.rsaPublicKey,
            0,
            key.publicKeyPayload(keyName),
          ),
        );
        deadline = DateTime.now().add(pairingTimeout);
        onPrompt?.call();
      } else {
        throw AdbAuthException(
          'the device rejected the key',
          promptShown: true,
        );
      }
    }
  }

  Future<void> _startTls(AdbHostKey key, DateTime deadline) async {
    _send(AdbMessage(AdbCommand.stls, adbStlsVersion, 0));
    Duration left() {
      final rest = deadline.difference(DateTime.now());
      return rest > Duration.zero ? rest : Duration.zero;
    }

    try {
      await _link.flush().timeout(left());
      // The device sends nothing more until our ClientHello, so no bytes
      // are left behind in the plain socket. A timeout closes the socket,
      // so a device that never finishes TLS is not left holding it.
      await _link.secure(
        context: adbTlsContext(key),
        onBadCertificate: (certificate) {
          final ok = _acceptCertificate?.call(certificate) ?? true;
          if (!ok) _certificateRefused = true;
          return ok;
        },
        timeout: left(),
      );
    } on TimeoutException {
      _end();
      throw AdbHandshakeTimeoutException();
    } on Exception {
      _end();
      if (_certificateRefused) throw AdbIdentityException();
      throw AdbTlsRefusedException();
    }
    _tls = true;
  }

  Future<AdbMessage> _nextHandshakeMessage(DateTime deadline) async {
    while (_inbox.isEmpty) {
      if (_closed) {
        // TLS 1.3 judges the client certificate after the client finished,
        // so a key the device refuses shows as the connection closing.
        if (_tls) throw AdbTlsRefusedException();
        throw AdbConnectionClosedException(
          'the device closed the connection during the handshake',
        );
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('adb handshake');
      final arrived = _arrived = Completer<void>();
      await arrived.future.timeout(left);
    }
    return _inbox.removeFirst();
  }

  /// Runs `shell:<command>` and returns everything the device wrote before
  /// closing the stream.
  Future<String> shell(String command, {required Duration timeout}) async {
    final stream = _open('shell:$command', _CollectingStream.new);
    try {
      return await stream.collected.future.timeout(timeout);
    } on TimeoutException {
      _abandon(stream);
      throw AdbShellTimeoutException(acknowledged: stream.remoteId != 0);
    }
  }

  /// Opens [service] (`sync:`, `shell:`, `exec:...`) as a two-way stream.
  /// Throws [AdbStreamRefusedException] when the device refuses it.
  Future<AdbStream> openStream(
    String service, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stream = _open(service, AdbStream._);
    try {
      await stream._opened.future.timeout(timeout);
    } on TimeoutException {
      _abandon(stream);
      throw AdbShellTimeoutException(acknowledged: false);
    }
    return stream;
  }

  T _open<T extends _Stream>(
    String service,
    T Function(AdbConnection connection, int localId) create,
  ) {
    if (_closed) {
      throw AdbConnectionClosedException('the connection is closed');
    }
    final payload = Uint8List.fromList([...utf8.encode(service), 0]);
    if (payload.length > min(_deviceMaxData, adbMaxData)) {
      throw ArgumentError('shell command is too long');
    }
    final localId = _nextLocalId;
    _nextLocalId = _nextLocalId == 0x7fffffff ? 1 : _nextLocalId + 1;
    final stream = create(this, localId);
    _streams[localId] = stream;
    _send(AdbMessage(AdbCommand.open, localId, 0, payload));
    return stream;
  }

  void _abandon(_Stream stream) {
    _streams.remove(stream.localId);
    if (stream.remoteId != 0 && !_closed) {
      _send(AdbMessage(AdbCommand.clse, stream.localId, stream.remoteId));
    }
    stream._ended(
      AdbConnectionClosedException(
        'the stream was abandoned',
        acknowledged: stream.remoteId != 0,
      ),
    );
  }

  /// The largest WRTE payload the device takes.
  int get _writeLimit => min(_deviceMaxData, adbHostMaxData);

  void _onData(Uint8List chunk) {
    final List<AdbMessage> messages;
    try {
      messages = _reader.add(chunk);
    } on AdbProtocolException {
      _end();
      return;
    }
    for (final message in messages) {
      if (_ready) {
        _dispatch(message);
      } else {
        _inbox.add(message);
      }
    }
    if (_inbox.isNotEmpty) _wake();
  }

  void _dispatch(AdbMessage message) {
    final stream = _streams[message.arg1];
    switch (message.command) {
      case AdbCommand.okay:
        if (stream == null) return;
        if (stream.remoteId == 0) {
          stream.remoteId = message.arg0;
          stream._accepted();
        } else {
          stream._acknowledged();
        }
      case AdbCommand.wrte:
        if (stream == null) return;
        if (stream.remoteId == 0) {
          stream.remoteId = message.arg0;
          stream._accepted();
        }
        stream._received(message.data);
        _send(AdbMessage(AdbCommand.okay, stream.localId, message.arg0));
      case AdbCommand.clse:
        if (stream == null) return;
        _streams.remove(stream.localId);
        if (stream.remoteId == 0 && message.arg0 == 0) {
          stream._ended(AdbStreamRefusedException());
          return;
        }
        _send(AdbMessage(AdbCommand.clse, stream.localId, message.arg0));
        stream._ended(null);
    }
  }

  void _send(AdbMessage message) {
    if (_closed) return;
    _link.add(message.encode());
  }

  void _wake() {
    final arrived = _arrived;
    _arrived = null;
    if (arrived != null && !arrived.isCompleted) arrived.complete();
  }

  void _end() {
    if (_closed) return;
    _closed = true;
    _link.destroy();
    _wake();
    for (final stream in _streams.values) {
      stream._ended(
        AdbConnectionClosedException(
          'the device closed the connection',
          acknowledged: stream.remoteId != 0,
        ),
      );
    }
    _streams.clear();
  }

  void close() => _end();
}

/// One ADB stream on a connection: the device's id for it, and what
/// happens as messages for it arrive.
abstract class _Stream {
  _Stream(this._connection, this.localId);

  final AdbConnection _connection;
  final int localId;
  int remoteId = 0;

  void _accepted() {}
  void _acknowledged() {}
  void _received(Uint8List data);

  /// The stream ended: closed by the device when [error] is null.
  void _ended(Object? error);
}

/// A shell stream whose output is gathered until the device closes it.
class _CollectingStream extends _Stream {
  _CollectingStream(super.connection, super.localId);

  final _output = BytesBuilder(copy: false);
  final collected = Completer<String>();

  @override
  void _received(Uint8List data) {
    final room = _maxShellOutput - _output.length;
    if (room > 0) {
      _output.add(
        data.length <= room ? data : Uint8List.sublistView(data, 0, room),
      );
    }
  }

  @override
  void _ended(Object? error) {
    if (collected.isCompleted) return;
    if (error == null) {
      collected.complete(utf8.decode(_output.toBytes(), allowMalformed: true));
    } else {
      // A shell that timed out is abandoned with nobody waiting.
      collected.future.ignore();
      collected.completeError(error);
    }
  }
}

/// A two-way ADB stream, as the sync protocol and an interactive shell use
/// it. Reads are exact-length or chunk by chunk; each write waits for the
/// device's OKAY, as legacy ADB allows one unacknowledged WRTE per stream.
class AdbStream extends _Stream {
  AdbStream._(super.connection, super.localId);

  final _opened = Completer<void>();
  final _chunks = ListQueue<Uint8List>();
  var _buffered = 0;
  Completer<void>? _arrived;
  Completer<void>? _ack;
  Object? _error;
  var _done = false;
  final _closed = Completer<void>();

  /// Completes when the device or [close] ends the stream.
  Future<void> get done => _closed.future;

  bool get isDone => _done;

  /// Why the stream ended, when it was not closed cleanly by either side.
  Object? get error => _error;

  @override
  void _accepted() {
    if (!_opened.isCompleted) _opened.complete();
  }

  @override
  void _acknowledged() {
    final ack = _ack;
    _ack = null;
    if (ack != null && !ack.isCompleted) ack.complete();
  }

  @override
  void _received(Uint8List data) {
    if (data.isEmpty) return;
    _chunks.add(data);
    _buffered += data.length;
    _wakeReader();
  }

  @override
  void _ended(Object? error) {
    if (_done) return;
    _done = true;
    _error = error;
    if (!_opened.isCompleted) {
      _opened.completeError(error ?? AdbStreamRefusedException());
      // Nobody may be waiting on it once the open timed out.
      _opened.future.ignore();
    }
    final ack = _ack;
    _ack = null;
    if (ack != null && !ack.isCompleted) {
      ack.completeError(
        error ?? AdbConnectionClosedException('the device closed the stream'),
      );
    }
    _wakeReader();
    if (!_closed.isCompleted) _closed.complete();
  }

  void _wakeReader() {
    final arrived = _arrived;
    _arrived = null;
    if (arrived != null && !arrived.isCompleted) arrived.complete();
  }

  Exception _endedError() => _error is Exception
      ? _error! as Exception
      : AdbConnectionClosedException('the device closed the stream');

  Future<void> _waitForData(Duration? timeout) async {
    if (_done) throw _endedError();
    final arrived = _arrived = Completer<void>();
    if (timeout == null) {
      await arrived.future;
    } else {
      await arrived.future.timeout(timeout);
    }
  }

  /// Exactly [length] bytes. Throws when the stream ends first, or
  /// [TimeoutException] when no data comes for [timeout].
  Future<Uint8List> read(int length, {Duration? timeout}) async {
    while (_buffered < length) {
      await _waitForData(timeout);
    }
    final out = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      final head = _chunks.first;
      final take = min(head.length, length - filled);
      out.setRange(filled, filled + take, head);
      filled += take;
      if (take == head.length) {
        _chunks.removeFirst();
      } else {
        _chunks
          ..removeFirst()
          ..addFirst(Uint8List.sublistView(head, take));
      }
    }
    _buffered -= length;
    return out;
  }

  /// The next bytes the device sent, or null once the stream has ended and
  /// everything was read.
  Future<Uint8List?> readChunk({Duration? timeout}) async {
    while (_chunks.isEmpty) {
      if (_done) return null;
      await _waitForData(timeout);
    }
    final head = _chunks.removeFirst();
    _buffered -= head.length;
    return head;
  }

  /// Sends [data], split to the device's message size.
  Future<void> write(List<int> data, {Duration? timeout}) async {
    final limit = _connection._writeLimit;
    for (var offset = 0; offset < data.length; offset += limit) {
      if (_done) throw _endedError();
      final end = min(offset + limit, data.length);
      final ack = _ack = Completer<void>();
      _connection._send(
        AdbMessage(
          AdbCommand.wrte,
          localId,
          remoteId,
          Uint8List.fromList(data.sublist(offset, end)),
        ),
      );
      if (timeout == null) {
        await ack.future;
      } else {
        await ack.future.timeout(timeout);
      }
    }
  }

  /// Closes the stream from this side.
  void close() {
    if (_done) return;
    _connection._streams.remove(localId);
    if (remoteId != 0 && !_connection._closed) {
      _connection._send(AdbMessage(AdbCommand.clse, localId, remoteId));
    }
    _ended(null);
  }
}
