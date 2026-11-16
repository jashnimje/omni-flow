import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'adb_key.dart';
import 'adb_tls.dart';
import 'raw_link.dart';
import 'spake2.dart';

// Android Wireless Debugging pairing, the client side of AOSP's
// pairing_connection.cpp:
//
// 1. TLS 1.3 to the pairing port, presenting this engine's ADB key.
// 2. Both sides key SPAKE2 with the six-digit code plus 64 bytes of the
//    connection's exporter, so a code read off the screen is useless on any
//    other connection.
// 3. Each side sends its 8192-byte peer info under AES-128-GCM keyed from
//    the SPAKE2 key: ours carries the public key, the phone's its guid.
//
// Only a phone that derived the same key can read our key, so a wrong code
// fails on its side and the phone closes the connection.

/// Why a pairing failed. None of them carries the code.
enum AdbPairingFailure {
  /// Nothing answered at the pairing port.
  unreachable,

  /// The TLS handshake failed.
  tls,

  /// The phone closed the connection after our encrypted key, which is what
  /// a wrong code looks like, or our check of its reply failed.
  wrongCode,

  /// The phone answered something this client does not understand.
  protocol,

  /// The phone stopped answering.
  timeout,
}

class AdbPairingFailedException implements Exception {
  AdbPairingFailedException(this.failure, this.message);

  final AdbPairingFailure failure;
  final String message;

  @override
  String toString() => 'AdbPairingFailedException(${failure.name}): $message';
}

/// The phone's answer: its guid, which is also the instance name of its
/// `_adb-tls-connect._tcp` service.
class AdbPairingResult {
  const AdbPairingResult(this.guid);

  final String guid;
}

/// The packet header version pairing speaks (kCurrentKeyHeaderVersion).
const _headerVersion = 1;
const _spake2Message = 0;
const _peerInfoMessage = 1;

/// PeerInfo is one type byte and 8191 bytes of data (kMaxPeerInfoSize).
const adbPeerInfoSize = 8192;
const _peerInfoRsaPublicKey = 0;
const _peerInfoDeviceGuid = 1;

/// The largest payload the phone may announce (kMaxPayloadSize).
const _maxPayload = adbPeerInfoSize * 2;

final _aesKeyInfo = ascii.encode('adb pairing_auth aes-128-gcm key');

/// A guid the phone may report: `adb-<serial>-<suffix>` in practice, kept
/// to the characters an mDNS instance and a device id can carry.
final adbGuidPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');

/// The pairing code as the phone shows it: six digits.
final adbPairingCodePattern = RegExp(r'^[0-9]{6}$');

/// Pairs with the phone at [host]:[port] using [code], and returns its
/// guid. The phone then accepts [key] on its TLS connect port.
///
/// [keyName] is the name the phone lists the key under. [spake2] fixes
/// the SPAKE2 context, and [onExported] gets the exporter bytes, for a
/// loopback phone in tests, as `dart:io` gives a TLS server no keyLog.
/// How long a paired connection waits for the phone to close it.
const _closeGrace = Duration(seconds: 2);

Future<AdbPairingResult> pairAdbDevice({
  required String host,
  required int port,
  required String code,
  required AdbHostKey key,
  required String keyName,
  Duration timeout = const Duration(seconds: 15),
  Spake2? spake2,
  void Function(Uint8List exported)? onExported,
}) async {
  Uint8List? exporterSecret;
  // One deadline covers the whole pairing: connecting, TLS and each reply,
  // so a peer that accepts the connection and then goes quiet cannot hold
  // android.pair open.
  final deadline = DateTime.now().add(timeout);
  Duration left() {
    final rest = deadline.difference(DateTime.now());
    return rest > Duration.zero ? rest : Duration.zero;
  }

  final RawLink socket;
  try {
    socket = await RawLink.connect(host, port, timeout: left());
  } on SocketException catch (e) {
    throw AdbPairingFailedException(
      AdbPairingFailure.unreachable,
      'cannot reach $host:$port (${e.osError?.message ?? e.message})',
    );
  }
  try {
    await socket.secure(
      context: adbTlsContext(key),
      onBadCertificate: (_) => true,
      timeout: left(),
      keyLog: (line) {
        exporterSecret ??= keyLogSecret(line, 'EXPORTER_SECRET');
      },
    );
  } on TimeoutException {
    throw AdbPairingFailedException(
      AdbPairingFailure.timeout,
      'no TLS answer from $host:$port',
    );
  } on Exception {
    throw AdbPairingFailedException(
      AdbPairingFailure.tls,
      'the TLS handshake with $host:$port failed',
    );
  }
  final reader = _SocketReader(socket);
  try {
    final secret = exporterSecret;
    if (secret == null) {
      throw AdbPairingFailedException(
        AdbPairingFailure.tls,
        'the TLS connection gave no exporter secret',
      );
    }
    final exported = tlsExporter(
      secret,
      adbExporterLabel,
      adbExportedKeyLength,
    );
    onExported?.call(exported);
    final auth = spake2 ?? Spake2.adbClient();
    final ours = auth.generateMessage([...utf8.encode(code), ...exported]);
    socket.add(_packet(_spake2Message, ours));
    await socket.flush().timeout(left());

    final theirs = await _readPacket(reader, _spake2Message, left());
    final Uint8List shared;
    try {
      shared = auth.processMessage(theirs);
    } on Spake2Exception {
      throw AdbPairingFailedException(
        AdbPairingFailure.protocol,
        'the phone sent a bad pairing message',
      );
    }
    final cipher = _PairingCipher(
      hkdf(SHA256Digest.new, shared, _aesKeyInfo, 16),
    );
    final peerInfo = Uint8List(adbPeerInfoSize)..[0] = _peerInfoRsaPublicKey;
    final publicKey = key.publicKeyPayload(keyName);
    if (publicKey.length > adbPeerInfoSize - 1) {
      throw ArgumentError('the key name is too long');
    }
    peerInfo.setRange(1, 1 + publicKey.length, publicKey);
    socket.add(_packet(_peerInfoMessage, cipher.encrypt(peerInfo)));
    await socket.flush().timeout(left());

    final Uint8List sealed;
    try {
      sealed = await _readPacket(reader, _peerInfoMessage, left());
    } on _Closed {
      throw AdbPairingFailedException(
        AdbPairingFailure.wrongCode,
        'the phone did not accept the pairing code',
      );
    }
    final info = cipher.decrypt(sealed);
    if (info == null) {
      throw AdbPairingFailedException(
        AdbPairingFailure.wrongCode,
        'the phone did not accept the pairing code',
      );
    }
    if (info.length != adbPeerInfoSize || info[0] != _peerInfoDeviceGuid) {
      throw AdbPairingFailedException(
        AdbPairingFailure.protocol,
        'the phone answered without its guid',
      );
    }
    final end = info.indexOf(0, 1);
    final guid = ascii.decode(
      Uint8List.sublistView(info, 1, end < 0 ? info.length : end),
      allowInvalid: true,
    );
    if (!adbGuidPattern.hasMatch(guid)) {
      throw AdbPairingFailedException(
        AdbPairingFailure.protocol,
        'the phone sent a guid this engine cannot use',
      );
    }
    // The phone closes the connection once it has read our key. Closing
    // first could drop the TLS bytes that carry the key before they leave,
    // so wait for the phone (briefly) before tearing the link down.
    await socket.done.timeout(_closeGrace, onTimeout: () {});
    return AdbPairingResult(guid);
  } on _Closed {
    throw AdbPairingFailedException(
      AdbPairingFailure.wrongCode,
      'the phone closed the pairing connection',
    );
  } on TimeoutException {
    throw AdbPairingFailedException(
      AdbPairingFailure.timeout,
      'the phone stopped answering during pairing',
    );
  } on SocketException {
    throw AdbPairingFailedException(
      AdbPairingFailure.wrongCode,
      'the phone closed the pairing connection',
    );
  } finally {
    socket.destroy();
  }
}

/// A pairing packet: version, type, then the big-endian payload length.
Uint8List _packet(int type, List<int> payload) {
  final out = Uint8List(6 + payload.length);
  out[0] = _headerVersion;
  out[1] = type;
  ByteData.sublistView(out).setUint32(2, payload.length);
  out.setRange(6, out.length, payload);
  return out;
}

Future<Uint8List> _readPacket(
  _SocketReader reader,
  int type,
  Duration timeout,
) async {
  final header = await reader.read(6, timeout);
  final length = ByteData.sublistView(header).getUint32(2);
  if (header[0] != _headerVersion ||
      header[1] != type ||
      length == 0 ||
      length > _maxPayload) {
    throw AdbPairingFailedException(
      AdbPairingFailure.protocol,
      'the phone sent an unexpected pairing packet',
    );
  }
  return reader.read(length, timeout);
}

/// AES-128-GCM with the nonce AOSP uses (aes_128_gcm.cpp): twelve bytes,
/// the first eight a little-endian count of messages sent (or received)
/// so far.
class _PairingCipher {
  _PairingCipher(this._key);

  final Uint8List _key;
  var _sent = 0;
  var _received = 0;

  Uint8List encrypt(Uint8List plain) => _gcm(true, _sent++).process(plain);

  /// Null when the tag does not match.
  Uint8List? decrypt(Uint8List sealed) {
    try {
      return _gcm(false, _received++).process(sealed);
    } on InvalidCipherTextException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  GCMBlockCipher _gcm(bool encrypt, int sequence) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(0, sequence, Endian.little);
    return GCMBlockCipher(AESEngine())..init(
      encrypt,
      AEADParameters(KeyParameter(_key), 128, nonce, Uint8List(0)),
    );
  }
}

class _Closed implements Exception {}

/// Exact-length reads from a socket.
class _SocketReader {
  _SocketReader(RawLink socket) {
    socket.listen((chunk) {
      _chunks.add(chunk);
      _buffered += chunk.length;
      _wake();
    }, _end);
  }

  final _chunks = ListQueue<Uint8List>();
  var _buffered = 0;
  var _done = false;
  Completer<void>? _arrived;

  void _wake() {
    final arrived = _arrived;
    _arrived = null;
    if (arrived != null && !arrived.isCompleted) arrived.complete();
  }

  void _end() {
    _done = true;
    _wake();
  }

  Future<Uint8List> read(int length, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffered < length) {
      if (_done) throw _Closed();
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('pairing read');
      final arrived = _arrived = Completer<void>();
      await arrived.future.timeout(left);
    }
    final out = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      final head = _chunks.removeFirst();
      final take = min(head.length, length - filled);
      out.setRange(filled, filled + take, head);
      filled += take;
      if (take < head.length) {
        _chunks.addFirst(Uint8List.sublistView(head, take));
      }
    }
    _buffered -= length;
    return out;
  }
}
