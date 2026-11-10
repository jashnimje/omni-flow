import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:omniflow_engine/src/devices/adb/adb_protocol.dart';

import 'fake_fs.dart';

export 'fake_fs.dart';

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

  static Future<FakeAdbd> start({int port = 0}) async =>
      FakeAdbd._(await ServerSocket.bind(InternetAddress.loopbackIPv4, port));

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

  /// The files the sync service serves.
  final fs = FakeFs();

  /// Every sync request, as `STAT /path`.
  final syncRequests = <String>[];

  /// Open sync streams, by the fake's stream id.
  final syncs = <int, FakeSyncSession>{};

  /// Refuses `sync:` as a device without file access does.
  var refuseSync = false;

  /// Takes sync data and never answers, as a TV that hung does.
  var stallSync = false;

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
    socket.done.then<void>((_) {}, onError: (Object _) {});
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
            case AdbCommand.wrte:
              final session = syncs[m.arg1];
              expect0(session != null, 'WRTE only goes to a sync stream');
              send(AdbCommand.okay, m.arg1, m.arg0);
              if (stallSync) return;
              session!.add(m.data);
            case AdbCommand.clse:
              syncs.remove(m.arg1);
            case AdbCommand.open:
              final service = utf8.decode(m.data);
              expect0(service.endsWith('\x00'), 'OPEN payload ends with NUL');
              final name = service.substring(0, service.length - 1);
              if (name == 'sync:') {
                if (refuseSync) {
                  send(AdbCommand.clse, 0, m.arg0);
                  return;
                }
                final remoteId = nextRemoteId++;
                syncs[remoteId] = FakeSyncSession(
                  this,
                  (data) {
                    for (var i = 0; i < data.length; i += 64 * 1024 + 8) {
                      send(
                        AdbCommand.wrte,
                        remoteId,
                        m.arg0,
                        data.sublist(i, min(i + 64 * 1024 + 8, data.length)),
                      );
                    }
                  },
                  () {
                    syncs.remove(remoteId);
                    send(AdbCommand.clse, remoteId, m.arg0);
                  },
                );
                send(AdbCommand.okay, remoteId, m.arg0);
                return;
              }
              final command = name.replaceFirst('shell:', '');
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

/// adbd's sync service over [FakeAdbd.fs]: STAT (no link following),
/// LIST (with `.` and `..`, as readdir gives them), RECV, SEND (making
/// parent folders, as `fixed_push_mkdir` does) and QUIT.
class FakeSyncSession {
  FakeSyncSession(this._adbd, this._reply, this._close);

  final FakeAdbd _adbd;
  final void Function(List<int> data) _reply;
  final void Function() _close;
  final _buffer = BytesBuilder();
  Uint8List _pending = Uint8List(0);

  String? _sendPath;
  int _sendMode = 0;
  BytesBuilder? _sendData;

  FakeFs get _fs => _adbd.fs;

  void add(List<int> data) {
    _buffer
      ..add(_pending)
      ..add(data);
    var bytes = _buffer.takeBytes();
    while (bytes.length >= 8) {
      final id = ascii.decode(bytes.sublist(0, 4));
      final n = ByteData.sublistView(bytes).getUint32(4, Endian.little);
      final payloadLength = id == 'DONE' ? 0 : n;
      if (bytes.length < 8 + payloadLength) break;
      final payload = bytes.sublist(8, 8 + payloadLength);
      bytes = Uint8List.sublistView(bytes, 8 + payloadLength);
      _handle(id, n, payload);
    }
    _pending = Uint8List.fromList(bytes);
  }

  static List<int> le32(int v) => [
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];

  void _fail(String message) => _reply([
    ...ascii.encode('FAIL'),
    ...le32(utf8.encode(message).length),
    ...utf8.encode(message),
  ]);

  void _handle(String id, int n, Uint8List payload) {
    if (_sendPath != null) {
      if (id == 'DATA') {
        expect0(payload.length <= 64 * 1024, 'DATA chunk within 64 KiB');
        _sendData!.add(payload);
      } else if (id == 'DONE') {
        final path = _sendPath!;
        _sendPath = null;
        if (_fs.nodes[path]?.isDir == true) {
          _fail('is a directory: $path');
          return;
        }
        _fs.writeFile(path, _sendData!.takeBytes(), mode: _sendMode, mtime: n);
        _reply([...ascii.encode('OKAY'), ...le32(0)]);
      } else {
        throw StateError('fake adbd: $id inside SEND');
      }
      return;
    }
    final arg = utf8.decode(payload);
    _adbd.syncRequests.add('$id $arg');
    switch (id) {
      case 'STAT':
        final node = _fs.nodes[arg];
        _reply([
          ...ascii.encode('STAT'),
          ...le32(node?.mode ?? 0),
          ...le32(node?.size ?? 0),
          ...le32(node?.mtime ?? 0),
        ]);
      case 'LIST':
        final dir = _fs.nodes[_fs.resolve(arg)];
        if (dir != null && dir.isDir) {
          for (final name in ['.', '..', ..._fs.children(arg)]) {
            final node = name == '.' || name == '..'
                ? FakeNode.dir()
                : _fs.nodes[FakeFs.join(_fs.resolve(arg), name)]!;
            final bytes = utf8.encode(name);
            _reply([
              ...ascii.encode('DENT'),
              ...le32(node.mode),
              ...le32(node.size),
              ...le32(node.mtime),
              ...le32(bytes.length),
              ...bytes,
            ]);
          }
        }
        _reply([...ascii.encode('DONE'), ...List.filled(16, 0)]);
      case 'RECV':
        final node = _fs.nodes[_fs.resolve(arg)];
        if (node == null || node.isDir) {
          _fail(node == null ? 'No such file or directory' : 'Is a directory');
          return;
        }
        final bytes = node.bytes!;
        for (var i = 0; i < bytes.length; i += 64 * 1024) {
          final chunk = bytes.sublist(i, min(i + 64 * 1024, bytes.length));
          _reply([...ascii.encode('DATA'), ...le32(chunk.length), ...chunk]);
        }
        _reply([...ascii.encode('DONE'), ...le32(0)]);
      case 'SEND':
        final comma = arg.lastIndexOf(',');
        _sendPath = arg.substring(0, comma);
        _sendMode = int.parse(arg.substring(comma + 1));
        _sendData = BytesBuilder();
      case 'QUIT':
        _close();
      default:
        throw StateError('fake adbd: unknown sync request $id');
    }
  }
}
