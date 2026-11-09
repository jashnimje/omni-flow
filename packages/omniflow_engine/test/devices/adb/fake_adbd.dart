import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:omniflow_engine/src/devices/adb/adb_protocol.dart';

/// What the fake does when a host offers a public key.
enum KeyPrompt { accept, ignore, reject }

/// An RSA public key read back from Android's mincrypt layout, by code that
/// shares nothing with the host side.
class MincryptKey {
  MincryptKey(this.n, this.e, this.n0inv, this.rr, this.words);

  static MincryptKey parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final words = data.getUint32(0, Endian.little);
    BigInt read(int offset) {
      var value = BigInt.zero;
      for (var i = words - 1; i >= 0; i--) {
        value =
            (value << 32) |
            BigInt.from(data.getUint32(offset + 4 * i, Endian.little));
      }
      return value;
    }

    return MincryptKey(
      read(8),
      data.getUint32(8 + 8 * words, Endian.little),
      data.getUint32(4, Endian.little),
      read(8 + 4 * words),
      words,
    );
  }

  final BigInt n;
  final int e;
  final int n0inv;
  final BigInt rr;
  final int words;

  /// adbd's check: s^e mod n must be the PKCS#1 v1.5 type 1 block over the
  /// SHA-1 DigestInfo of [token].
  bool verifies(List<int> token, List<int> signature) {
    final k = words * 4;
    if (signature.length != k) return false;
    var s = BigInt.zero;
    for (final b in signature) {
      s = (s << 8) | BigInt.from(b);
    }
    final m = s.modPow(BigInt.from(e), n);
    final expected = <int>[
      0x00,
      0x01,
      ...List.filled(k - 3 - 35, 0xff),
      0x00,
      ...hex('3021300906052b0e03021a05000414'),
      ...token,
    ];
    var want = BigInt.zero;
    for (final b in expected) {
      want = (want << 8) | BigInt.from(b);
    }
    return m == want;
  }
}

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

/// A loopback adbd: legacy CNXN, AUTH, OPEN, WRTE and CLSE. It verifies the
/// host's signature against the keys it trusts, takes a public key the way
/// a TV does after "Allow USB debugging?", and records every shell command.
class FakeAdbd {
  FakeAdbd._(this._server) {
    _server.listen(_serve);
  }

  static Future<FakeAdbd> start() async =>
      FakeAdbd._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final _random = Random(7);
  final _sockets = <Socket>[];

  final trusted = <MincryptKey>[];
  final offeredKeys = <MincryptKey>[];
  final offeredNames = <String>[];
  final commands = <String>[];
  final hostBanners = <String>[];
  final hostVersions = <int>[];
  final hostMaxData = <int>[];
  var signaturesSent = 0;
  var signaturesAccepted = 0;

  /// Whether the first signature on a connection verified against the key
  /// that connection then offered.
  final offeredKeyMatchesSignature = <bool>[];
  var connections = 0;
  var prompt = KeyPrompt.accept;
  var dropOnOpen = false;

  /// How many next OPENs close the connection before OKAY.
  var dropNextOpens = 0;

  /// Closes the connection after OKAY, so the shell may have run.
  var dropAfterOkay = false;

  /// Sets the device's output for a shell command.
  String Function(String command) respond = (_) => '';

  int get port => _server.port;

  /// Connections the host side has not closed yet.
  int get openConnections => _sockets.length;

  /// Closes every open connection, as a TV going to sleep does.
  void dropAll() {
    final open = [..._sockets];
    _sockets.clear();
    for (final s in open) {
      s.destroy();
    }
  }

  void _serve(Socket socket) {
    connections++;
    _sockets.add(socket);
    final reader = AdbMessageReader();
    Uint8List? token;
    Uint8List? signedToken;
    Uint8List? firstSignature;
    var nextRemoteId = 100;
    void send(int command, int arg0, int arg1, [List<int> data = const []]) =>
        socket.add(
          AdbMessage(command, arg0, arg1, Uint8List.fromList(data)).encode(),
        );
    void sendToken() {
      token = Uint8List.fromList(
        List.generate(20, (_) => _random.nextInt(256)),
      );
      send(AdbCommand.auth, 1, 0, token!);
    }

    void accept() => send(
      AdbCommand.cnxn,
      adbVersion,
      256 * 1024,
      utf8.encode('device::ro.product.name=fake;ro.product.model=FakeTV;\x00'),
    );

    socket.listen(
      (chunk) {
        for (final m in reader.add(chunk)) {
          switch (m.command) {
            case AdbCommand.cnxn:
              hostVersions.add(m.arg0);
              hostMaxData.add(m.arg1);
              hostBanners.add(utf8.decode(m.data));
              sendToken();
            case AdbCommand.auth when m.arg0 == 2:
              signaturesSent++;
              if (firstSignature == null) {
                firstSignature = m.data;
                signedToken = token;
              }
              if (trusted.any((k) => k.verifies(token!, m.data))) {
                signaturesAccepted++;
                accept();
              } else {
                sendToken();
              }
            case AdbCommand.auth when m.arg0 == 3:
              final text = ascii.decode(m.data);
              expect0(text.endsWith('\x00'), 'public key ends with NUL');
              final body = text.substring(0, text.length - 1);
              final space = body.indexOf(' ');
              final key = MincryptKey.parse(
                base64.decode(body.substring(0, space)),
              );
              offeredKeys.add(key);
              offeredNames.add(body.substring(space + 1));
              offeredKeyMatchesSignature.add(
                firstSignature != null &&
                    key.verifies(signedToken!, firstSignature!),
              );
              switch (prompt) {
                case KeyPrompt.accept:
                  trusted.add(key);
                  accept();
                case KeyPrompt.ignore:
                  break;
                case KeyPrompt.reject:
                  sendToken();
              }
            case AdbCommand.open:
              final service = utf8.decode(m.data);
              expect0(service.endsWith('\x00'), 'OPEN payload ends with NUL');
              final command = service
                  .substring(0, service.length - 1)
                  .replaceFirst('shell:', '');
              commands.add(command);
              if (dropOnOpen || dropNextOpens > 0) {
                if (dropNextOpens > 0) dropNextOpens--;
                socket.destroy();
                return;
              }
              final remoteId = nextRemoteId++;
              send(AdbCommand.okay, remoteId, m.arg0);
              if (dropAfterOkay) {
                socket.flush().whenComplete(socket.destroy);
                return;
              }
              final output = respond(command);
              if (output.isNotEmpty) {
                send(AdbCommand.wrte, remoteId, m.arg0, utf8.encode(output));
              }
              send(AdbCommand.clse, remoteId, m.arg0);
          }
        }
      },
      onError: (_) {},
      onDone: () => _sockets.remove(socket),
    );
  }

  Future<void> close() async {
    dropAll();
    await _server.close();
  }
}

void expect0(bool ok, String what) {
  if (!ok) throw StateError('fake adbd: $what');
}
