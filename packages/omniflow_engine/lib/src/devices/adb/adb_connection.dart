import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'adb_key.dart';
import 'adb_protocol.dart';

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
  AdbConnection._(this._socket) {
    _socket.listen(_onData, onError: (_) => _end(), onDone: _end);
    unawaited(_socket.done.then<void>((_) {}, onError: (_) {}));
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
  }) async {
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    final connection = AdbConnection._(socket);
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

  final Socket _socket;
  final _reader = AdbMessageReader();
  final _inbox = ListQueue<AdbMessage>();
  Completer<void>? _arrived;
  final _streams = <int, _ShellStream>{};
  var _nextLocalId = 1;
  var _ready = false;
  var _closed = false;
  var _deviceMaxData = adbMaxData;

  /// The device's CNXN banner, `device::ro.product.name=...;...`.
  String banner = '';

  bool get isClosed => _closed;

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
        adbMaxData,
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

  Future<AdbMessage> _nextHandshakeMessage(DateTime deadline) async {
    while (_inbox.isEmpty) {
      if (_closed) {
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
    if (_closed) {
      throw AdbConnectionClosedException('the connection is closed');
    }
    final payload = Uint8List.fromList([...utf8.encode('shell:$command'), 0]);
    if (payload.length > min(_deviceMaxData, adbMaxData)) {
      throw ArgumentError('shell command is too long');
    }
    final localId = _nextLocalId;
    _nextLocalId = _nextLocalId == 0x7fffffff ? 1 : _nextLocalId + 1;
    final stream = _streams[localId] = _ShellStream(localId);
    _send(AdbMessage(AdbCommand.open, localId, 0, payload));
    try {
      return await stream.done.future.timeout(timeout);
    } on TimeoutException {
      _streams.remove(localId);
      if (stream.remoteId != 0 && !_closed) {
        _send(AdbMessage(AdbCommand.clse, localId, stream.remoteId));
      }
      throw AdbShellTimeoutException(acknowledged: stream.remoteId != 0);
    }
  }

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
        if (stream != null && stream.remoteId == 0) {
          stream.remoteId = message.arg0;
        }
      case AdbCommand.wrte:
        if (stream == null) return;
        if (stream.remoteId == 0) stream.remoteId = message.arg0;
        stream.add(message.data);
        _send(AdbMessage(AdbCommand.okay, stream.localId, message.arg0));
      case AdbCommand.clse:
        if (stream == null) return;
        _streams.remove(stream.localId);
        if (stream.remoteId == 0 && message.arg0 == 0) {
          stream.done.completeError(AdbStreamRefusedException());
          return;
        }
        _send(AdbMessage(AdbCommand.clse, stream.localId, message.arg0));
        stream.done.complete(stream.output);
    }
  }

  void _send(AdbMessage message) {
    if (_closed) return;
    _socket.add(message.encode());
  }

  void _wake() {
    final arrived = _arrived;
    _arrived = null;
    if (arrived != null && !arrived.isCompleted) arrived.complete();
  }

  void _end() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    _wake();
    for (final stream in _streams.values) {
      stream.done.completeError(
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

class _ShellStream {
  _ShellStream(this.localId);

  final int localId;
  int remoteId = 0;
  final _output = BytesBuilder(copy: false);
  final done = Completer<String>();

  void add(Uint8List data) {
    final room = _maxShellOutput - _output.length;
    if (room > 0) {
      _output.add(
        data.length <= room ? data : Uint8List.sublistView(data, 0, room),
      );
    }
  }

  String get output => utf8.decode(_output.toBytes(), allowMalformed: true);
}
