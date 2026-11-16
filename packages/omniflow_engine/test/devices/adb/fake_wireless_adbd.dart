import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:omniflow_engine/src/devices/adb/adb_protocol.dart';
import 'package:omniflow_engine/src/devices/adb/adb_tls.dart';
import 'package:omniflow_engine/src/devices/adb/spake2.dart';
import 'package:pointycastle/export.dart';

/// Exact-length reads from a socket, for the fakes.
class Reader {
  Reader(Stream<Uint8List> stream) {
    _sub = stream.listen(
      (c) {
        _chunks.add(c);
        _buffered += c.length;
        _wake();
      },
      onDone: () {
        done = true;
        _wake();
      },
      onError: (Object _) {
        done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _chunks = ListQueue<Uint8List>();
  var _buffered = 0;
  var done = false;
  Completer<void>? _arrived;

  void _wake() {
    final a = _arrived;
    _arrived = null;
    a?.complete();
  }

  /// Null when the stream ends first.
  Future<Uint8List?> read(int n) async {
    while (_buffered < n) {
      if (done) return null;
      await (_arrived = Completer<void>()).future;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final head = _chunks.removeFirst();
      final take = min(head.length, n - filled);
      out.setRange(filled, filled + take, head);
      filled += take;
      if (take < head.length) {
        _chunks.addFirst(Uint8List.sublistView(head, take));
      }
    }
    _buffered -= n;
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}

/// A server context for [key] that trusts the certificates of [trust]: a
/// Dart TLS server checks a client certificate against its roots, where
/// adbd checks the key against the ones it paired with.
SecurityContext serverContext(
  AdbHostKey key, {
  List<AdbHostKey> trust = const [],
}) {
  final context = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(adbCertificatePem(key)))
    ..usePrivateKeyBytes(utf8.encode(key.toPem()));
  for (final k in trust) {
    context.setTrustedCertificatesBytes(utf8.encode(adbCertificatePem(k)));
  }
  return context;
}

/// A loopback phone showing "Pair device with pairing code": TLS 1.3 with
/// a client certificate, SPAKE2 as Bob, then the encrypted peer infos.
///
/// `dart:io` gives a TLS server no keyLog, so the test hands the phone the
/// exporter the client derived through [exported]. A phone that never gets
/// it uses random bytes, which is what a wrong code looks like.
class FakePairingPhone {
  FakePairingPhone._(this._server, this.code, this.guid) {
    _server.listen(_serve);
  }

  static Future<FakePairingPhone> start({
    required AdbHostKey phoneKey,
    required AdbHostKey hostKey,
    required String code,
    String guid = 'adb-FAKEPHONE01-AbC123',
  }) async => FakePairingPhone._(
    await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverContext(phoneKey, trust: [hostKey]),
      requestClientCertificate: true,
    ),
    code,
    guid,
  );

  final SecureServerSocket _server;
  final String code;
  final String guid;
  final exported = Completer<Uint8List>();

  /// The client's certificate and the public key line it sent, once paired.
  X509Certificate? clientCertificate;
  String? receivedKey;

  /// Completes when the phone has finished with a pairing connection.
  final done = Completer<void>();
  var closedOnBadKey = false;

  int get port => _server.port;

  Future<void> _serve(SecureSocket socket) async {
    clientCertificate = socket.peerCertificate;
    final reader = Reader(socket);
    try {
      final header = await reader.read(6);
      if (header == null || header[0] != 1 || header[1] != 0) return;
      final theirs = await reader.read(
        ByteData.sublistView(header).getUint32(2),
      );
      if (theirs == null) return;
      final exporter = exported.isCompleted
          ? await exported.future
          : Uint8List.fromList(List.generate(64, (i) => i * 7));
      final bob = Spake2(
        Spake2Role.bob,
        myName: adbPairServerName,
        theirName: adbPairClientName,
      );
      final ours = bob.generateMessage([...utf8.encode(code), ...exporter]);
      socket.add(_packet(0, ours));
      final key = hkdf(
        SHA256Digest.new,
        bob.processMessage(theirs),
        ascii.encode('adb pairing_auth aes-128-gcm key'),
        16,
      );
      final info = Uint8List(8192)..[0] = 1;
      info.setRange(1, 1 + guid.length, ascii.encode(guid));
      socket.add(_packet(1, _gcm(key, true).process(info)));
      await socket.flush();
      final h2 = await reader.read(6);
      if (h2 == null) return;
      final sealed = await reader.read(ByteData.sublistView(h2).getUint32(2));
      if (sealed == null) return;
      try {
        final plain = _gcm(key, false).process(sealed);
        final end = plain.indexOf(0, 1);
        receivedKey = ascii.decode(plain.sublist(1, end));
      } on InvalidCipherTextException {
        closedOnBadKey = true;
      }
    } finally {
      await reader.cancel();
      socket.destroy();
      if (!done.isCompleted) done.complete();
    }
  }

  static GCMBlockCipher _gcm(Uint8List key, bool encrypt) =>
      GCMBlockCipher(AESEngine())..init(
        encrypt,
        AEADParameters(KeyParameter(key), 128, Uint8List(12), Uint8List(0)),
      );

  static Uint8List _packet(int type, List<int> payload) {
    final out = Uint8List(6 + payload.length)
      ..[0] = 1
      ..[1] = type;
    ByteData.sublistView(out).setUint32(2, payload.length);
    out.setRange(6, out.length, payload);
    return out;
  }

  Future<void> close() => _server.close();
}

/// A loopback Wireless Debugging connect port: CNXN, then STLS, TLS 1.3
/// asking for the client's certificate, the device's CNXN inside it, and
/// `shell:` streams that echo a fixed reply. Only [allowed] keys get past
/// the handshake.
class FakeTlsAdbd {
  FakeTlsAdbd._(this._server, this._phoneKey, this.allowed) {
    _server.listen(_serve);
  }

  static Future<FakeTlsAdbd> start({
    required AdbHostKey phoneKey,
    required List<AdbHostKey> allowed,
  }) async => FakeTlsAdbd._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    phoneKey,
    allowed,
  );

  final ServerSocket _server;
  final AdbHostKey _phoneKey;
  final List<AdbHostKey> allowed;
  final shells = <String>[];
  var refused = 0;
  var connections = 0;

  int get port => _server.port;

  Future<void> _serve(Socket plain) async {
    connections++;
    final first = await _readMessages(plain, 1);
    if (first.isEmpty || first.first.command != AdbCommand.cnxn) {
      plain.destroy();
      return;
    }
    plain.add(AdbMessage(AdbCommand.stls, adbStlsVersion, 0).encode());
    await plain.flush();
    final answer = await _readMessages(plain, 1);
    if (answer.isEmpty || answer.first.command != AdbCommand.stls) {
      plain.destroy();
      return;
    }
    final SecureSocket socket;
    try {
      socket = await SecureSocket.secureServer(
        plain,
        serverContext(_phoneKey, trust: allowed),
        requestClientCertificate: true,
      );
    } on Object {
      refused++;
      return;
    }
    final der = socket.peerCertificate?.der;
    if (der == null ||
        !allowed.any((k) => _contains(der, _bigEndian(k.modulus)))) {
      refused++;
      socket.destroy();
      return;
    }
    socket.add(
      AdbMessage(
        AdbCommand.cnxn,
        0x01000001,
        256 * 1024,
        Uint8List.fromList(
          ascii.encode('device::ro.product.model=FakePhone;\x00'),
        ),
      ).encode(),
    );
    final reader = AdbMessageReader();
    socket.listen((chunk) {
      for (final m in reader.add(chunk)) {
        if (m.command == AdbCommand.open) {
          final service = utf8.decode(m.data).replaceAll('\x00', '');
          shells.add(service);
          socket
            ..add(AdbMessage(AdbCommand.okay, 77, m.arg0).encode())
            ..add(
              AdbMessage(
                AdbCommand.wrte,
                77,
                m.arg0,
                Uint8List.fromList(utf8.encode('tls says hi\n')),
              ).encode(),
            )
            ..add(AdbMessage(AdbCommand.clse, 77, m.arg0).encode());
        }
      }
    }, onError: (Object _) {});
  }

  /// Reads [count] plain messages and stops listening, so the socket can
  /// be upgraded to TLS.
  static Future<List<AdbMessage>> _readMessages(Socket socket, int count) {
    // The socket is listened to once and kept for every read, since a
    // single-subscription socket cannot be listened to twice.
    final state = _plainReads[socket] ??= _PlainReads(socket);
    return state.take(count);
  }

  static final _plainReads = Expando<_PlainReads>();

  Future<void> close() => _server.close();
}

class _PlainReads {
  _PlainReads(Socket socket) {
    socket.listen(
      (chunk) {
        _queue.addAll(_reader.add(chunk));
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (Object _) {
        _done = true;
        _wake();
      },
    );
  }

  final _reader = AdbMessageReader();
  final _queue = ListQueue<AdbMessage>();
  var _done = false;
  Completer<void>? _arrived;

  void _wake() {
    final a = _arrived;
    _arrived = null;
    a?.complete();
  }

  Future<List<AdbMessage>> take(int count) async {
    while (_queue.length < count && !_done) {
      await (_arrived = Completer<void>()).future;
    }
    return [
      for (var i = 0; i < count && _queue.isNotEmpty; i++) _queue.removeFirst(),
    ];
  }
}

Uint8List _bigEndian(BigInt v) {
  final out = <int>[];
  for (var rest = v; rest > BigInt.zero; rest >>= 8) {
    out.insert(0, (rest & BigInt.from(0xff)).toInt());
  }
  return Uint8List.fromList(out);
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
