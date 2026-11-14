import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/tv_pointer_commands.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:omniflow_engine/src/devices/adb/adb_protocol.dart';
import 'package:test/test.dart';

import '../devices/adb/fake_adbd.dart';
import '../devices/adb/fake_tv.dart';

void main() {
  late AdbHostKey key;
  late Directory home;
  late InMemorySecretStore secrets;
  late OmniEngine engine;

  setUpAll(() => key = AdbHostKey.generateSync());

  Future<void> openEngine(int port) async {
    home = await Directory.systemTemp.createTemp('omni_tv_pointer');
    secrets = InMemorySecretStore();
    await secrets.write(adbHostKeySecret, key.toPem());
    engine = await OmniEngine.open(
      home: home,
      secrets: secrets,
      discoveryTargets: () async => const [],
    );
    final added = await engine.handle('device.add', {
      'id': 'tv',
      'driver': 'android_tv_adb',
      'host': InternetAddress.loopbackIPv4.address,
      'port': port,
    });
    expect(added['ok'], isTrue, reason: '$added');
  }

  Future<void> closeEngine() async {
    await engine.close();
    await home.delete(recursive: true);
  }

  Future<Map<String, Object?>> ok(String c, Map<String, Object?> a) async {
    final r = await engine.handle(c, {'id': 'tv', ...a});
    expect(r['ok'], isTrue, reason: '$c: $r');
    return r;
  }

  Future<Map<String, Object?>> err(String c, Map<String, Object?> a) async {
    final r = await engine.handle(c, {'id': 'tv', ...a});
    expect(r['ok'], isFalse, reason: '$c: $r');
    return Map<String, Object?>.from(r['error'] as Map);
  }

  group('helper status and install', () {
    late FakeAdbd adbd;
    late FakeTv tv;
    late Directory local;
    var helperInstalled = false;
    var overlay = 'default';
    var listening = false;
    var startOutput = 'Starting service: Intent { cmp=$tvHelperService }\n';
    final scripts = <String>[];

    setUp(() async {
      helperInstalled = false;
      overlay = 'default';
      listening = false;
      scripts.clear();
      startOutput = 'Starting service: Intent { cmp=$tvHelperService }\n';
      adbd = await FakeAdbd.start();
      tv = FakeTv(adbd);
      final base = adbd.respond;
      adbd.respond = (script) {
        scripts.add(script);
        if (script.contains('@@omniflow-section:path')) {
          return [
            '',
            '@@omniflow-section:path',
            if (helperInstalled) 'package:/data/app/~~x==/helper/base.apk',
            '',
            '@@omniflow-section:ops',
            if (helperInstalled) 'SYSTEM_ALERT_WINDOW: $overlay; time=+1s',
            '',
            '@@omniflow-section:socket',
            listening ? '1' : '0',
            '',
          ].join('\n');
        }
        if (script.startsWith('appops set ')) {
          overlay = 'allow';
          return '';
        }
        if (script.startsWith('am start-foreground-service ')) {
          listening = startOutput.startsWith('Starting');
          return startOutput;
        }
        if (script.startsWith('pm install ')) helperInstalled = true;
        return base(script);
      };
      local = await Directory.systemTemp.createTemp('omni_tv_pointer_local');
      await openEngine(adbd.port);
    });

    tearDown(() async {
      await closeEngine();
      await adbd.close();
      await local.delete(recursive: true);
    });

    test('tv.helper.status reads installed, overlay and running in one '
        'shell run', () async {
      expect(await ok('tv.helper.status', {}), {
        'ok': true,
        'id': 'tv',
        'package': tvHelperPackage,
        'installed': false,
        'overlayAllowed': false,
        'running': false,
      });
      expect(scripts, hasLength(1));
      expect(scripts.single, contains("pm path '$tvHelperPackage'"));
      expect(
        scripts.single,
        contains("appops get '$tvHelperPackage' SYSTEM_ALERT_WINDOW"),
      );
      expect(scripts.single, contains("grep -c '@omniflow_pointer'"));

      helperInstalled = true;
      overlay = 'allow';
      listening = true;
      final now = await ok('tv.helper.status', {});
      expect(
        (now['installed'], now['overlayAllowed'], now['running']),
        (true, true, true),
      );
    });

    test('tv.helper.install installs through tv.install, grants the overlay '
        'and starts the service', () async {
      final apk = File('${local.path}/omniflow-tv-helper.apk')
        ..writeAsBytesSync(List.filled(4096, 3));
      final result = await ok('tv.helper.install', {'path': apk.path});
      expect(result['installed'], isTrue);
      expect(result['overlayAllowed'], isTrue);
      expect(result['running'], isTrue);
      expect(result['bytes'], 4096);
      expect(tv.installs.single.$1, ['-r']);
      expect(
        scripts,
        containsAllInOrder([
          startsWith('pm install -r '),
          "appops set '$tvHelperPackage' SYSTEM_ALERT_WINDOW allow",
          "am start-foreground-service -n '$tvHelperService'",
        ]),
      );
    });

    test('tv.helper.install says when the APK is not the helper, or the '
        'service will not start', () async {
      final apk = File('${local.path}/other.apk')
        ..writeAsBytesSync(List.filled(64, 1));
      adbd.respond = (script) {
        scripts.add(script);
        if (script.contains('@@omniflow-section:path')) {
          return '\n@@omniflow-section:path\n\n@@omniflow-section:ops\n\n'
              '@@omniflow-section:socket\n0\n';
        }
        return tv.respond(script);
      };
      final e = await err('tv.helper.install', {'path': apk.path});
      expect(e['type'], 'invalid');
      expect(e['message'], contains('not the OmniFlow pointer helper'));
      expect(scripts.where((s) => s.startsWith('appops set')), isEmpty);
    });

    test('a refused service start is a device error', () async {
      final apk = File('${local.path}/omniflow-tv-helper.apk')
        ..writeAsBytesSync(List.filled(64, 1));
      startOutput = 'Error: Not allowed to start service\n';
      final e = await err('tv.helper.install', {'path': apk.path});
      expect(e['type'], 'device_error');
      expect(e['message'], contains('did not start the helper'));
    });

    test('tv.helper.install needs an APK on this computer', () async {
      expect(
        (await err('tv.helper.install', {
          'path': '${local.path}/none.apk',
        }))['type'],
        'not_found',
      );
      expect((await err('tv.helper.install', {}))['type'], 'invalid');
    });
  });

  group('pointer stream', () {
    late _PointerAdbd adbd;

    setUp(() async {
      adbd = await _PointerAdbd.start();
      await openEngine(adbd.port);
    });

    tearDown(() async {
      await closeEngine();
      await adbd.close();
    });

    test('moves go to localabstract:omniflow_pointer as JSON lines, in '
        'order, on one stream', () async {
      expect(await ok('tv.pointer', {'show': true}), {
        'ok': true,
        'id': 'tv',
        'x': 0.5,
        'y': 0.5,
        'shown': true,
      });
      final to = await ok('tv.pointer', {
        'to': [0.25, 0.75],
      });
      expect((to['x'], to['y']), (0.25, 0.75));
      final by = await ok('tv.pointer', {
        'by': [0.9, -0.1],
      });
      expect((by['x'], by['y']), (1.0, 0.65));
      await ok('tv.pointer', {'hide': true});
      await adbd.settled();
      expect(adbd.lines, [
        {
          'to': [0.5, 0.5],
        },
        {
          'to': [0.25, 0.75],
        },
        {
          'to': [1.0, 0.65],
        },
        {'hide': true},
      ]);
      expect(adbd.pointerOpens, 1);
    });

    test('quick moves sent together all arrive, in order', () async {
      await Future.wait([
        for (var i = 1; i <= 20; i++)
          ok('tv.pointer', {
            'to': [i / 20, 0],
          }),
      ]);
      await adbd.settled();
      expect(adbd.lines.map((l) => (l['to'] as List).first), [
        for (var i = 1; i <= 20; i++) i / 20,
      ]);
    });

    test('tv.pointer.click taps where the pointer is', () async {
      await ok('tv.pointer', {
        'to': [0.5, 0.25],
      });
      final clicked = await ok('tv.pointer.click', {});
      expect(clicked, {
        'ok': true,
        'id': 'tv',
        'x': 0.5,
        'y': 0.25,
        'px': 960,
        'py': 270,
      });
      expect(adbd.taps, ['960 270']);
    });

    test('a helper that is not running is not_ready, and the next move '
        'after it starts goes through', () async {
      adbd.listening = false;
      final e = await err('tv.pointer', {'show': true});
      expect(e['type'], 'not_ready');
      expect(e['message'], contains('tv.helper.install'));
      adbd.listening = true;
      await ok('tv.pointer', {'show': true});
    });

    test('a stream the helper closed is opened again', () async {
      await ok('tv.pointer', {
        'to': [0.1, 0.1],
      });
      await adbd.settled();
      adbd.closePointerStreams();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ok('tv.pointer', {
        'to': [0.2, 0.2],
      });
      await adbd.settled();
      expect(adbd.pointerOpens, 2);
      expect(adbd.lines.last, {
        'to': [0.2, 0.2],
      });
    });

    test('bad arguments are refused before anything is sent', () async {
      for (final args in <Map<String, Object?>>[
        {},
        {'show': true, 'hide': true},
        {
          'to': [1.5, 0],
        },
        {
          'to': [0.5],
        },
        {'to': '0.5,0.5'},
        {
          'by': [-2, 0],
        },
        {'show': 'yes'},
      ]) {
        expect(
          (await err('tv.pointer', args))['type'],
          'invalid',
          reason: '$args',
        );
      }
      expect(adbd.pointerOpens, 0);
    });
  });

  test('agents: status is a read, moves need setup, install is the '
      'user\'s', () {
    expect(agentRefusal('tv.helper.status', const {}, AgentAccess.read), null);
    for (final c in ['tv.pointer', 'tv.pointer.click']) {
      expect(agentRefusal(c, const {}, AgentAccess.read), contains('sets'));
      expect(agentRefusal(c, const {}, AgentAccess.setup), null);
    }
    expect(
      agentRefusal('tv.helper.install', const {}, AgentAccess.setup),
      contains('for the user only'),
    );
  });
}

/// A loopback adbd with no auth that serves the shell lines the pointer
/// commands send and the helper's abstract socket, recording each line.
class _PointerAdbd {
  _PointerAdbd._(this._server) {
    _server.listen(_serve);
  }

  static Future<_PointerAdbd> start() async =>
      _PointerAdbd._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final _sockets = <Socket>[];
  final _pointerStreams = <(Socket, int, int)>[];
  final lines = <Map<String, Object?>>[];
  final taps = <String>[];
  var listening = true;
  var pointerOpens = 0;
  var _pending = 0;
  Completer<void>? _idle;

  int get port => _server.port;

  /// Waits until every line written so far has been read.
  Future<void> settled() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (_pending == 0) return;
    await (_idle ??= Completer<void>()).future;
  }

  void closePointerStreams() {
    for (final (socket, local, remote) in _pointerStreams) {
      socket.add(AdbMessage(AdbCommand.clse, local, remote).encode());
    }
    _pointerStreams.clear();
  }

  void _serve(Socket socket) {
    _sockets.add(socket);
    socket.done.then<void>((_) {}, onError: (Object _) {});
    final reader = AdbMessageReader();
    final pointerIds = <int>{};
    final partial = <int, List<int>>{};
    var nextId = 100;
    void send(int command, int a0, int a1, [List<int> data = const []]) =>
        socket.add(
          AdbMessage(command, a0, a1, Uint8List.fromList(data)).encode(),
        );
    socket.listen(
      (chunk) {
        for (final m in reader.add(chunk)) {
          switch (m.command) {
            case AdbCommand.cnxn:
              send(
                AdbCommand.cnxn,
                adbVersion,
                256 * 1024,
                utf8.encode('device::ro.product.model=PointerTV;\x00'),
              );
            case AdbCommand.open:
              final raw = utf8.decode(m.data);
              final service = raw.substring(0, raw.length - 1);
              if (service == 'localabstract:$tvPointerSocket') {
                if (!listening) {
                  send(AdbCommand.clse, 0, m.arg0);
                  continue;
                }
                pointerOpens++;
                final id = nextId++;
                pointerIds.add(id);
                _pointerStreams.add((socket, id, m.arg0));
                send(AdbCommand.okay, id, m.arg0);
                continue;
              }
              final id = nextId++;
              send(AdbCommand.okay, id, m.arg0);
              final out = _shell(service.replaceFirst('shell:', ''));
              if (out.isNotEmpty) {
                send(AdbCommand.wrte, id, m.arg0, utf8.encode(out));
              }
              send(AdbCommand.clse, id, m.arg0);
            case AdbCommand.wrte when pointerIds.contains(m.arg1):
              _pending++;
              final buffer = partial.putIfAbsent(m.arg1, () => [])
                ..addAll(m.data);
              var at = buffer.indexOf(10);
              while (at >= 0) {
                lines.add(
                  Map<String, Object?>.from(
                    jsonDecode(utf8.decode(buffer.sublist(0, at))) as Map,
                  ),
                );
                buffer.removeRange(0, at + 1);
                at = buffer.indexOf(10);
              }
              send(AdbCommand.okay, m.arg1, m.arg0);
              _pending--;
              if (_pending == 0) {
                _idle?.complete();
                _idle = null;
              }
            case AdbCommand.clse:
              pointerIds.remove(m.arg1);
          }
        }
      },
      onError: (_) {},
      onDone: () => _sockets.remove(socket),
    );
  }

  String _shell(String script) {
    final out = StringBuffer();
    for (final line in script.split('\n')) {
      final marker = RegExp(r'^echo "(@@omniflow-exit-[0-9a-f]+:)\$\?"$')
          .firstMatch(line);
      if (marker != null) {
        out.writeln('${marker.group(1)}0');
      } else if (line == 'wm size') {
        out.writeln('Physical size: 1920x1080');
      } else if (line.startsWith('input tap ')) {
        taps.add(line.substring('input tap '.length));
      }
    }
    return out.toString();
  }

  Future<void> close() async {
    for (final s in [..._sockets]) {
      s.destroy();
    }
    await _server.close();
  }
}
