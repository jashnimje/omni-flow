import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:test/test.dart';

import '../devices/adb/fake_adbd.dart';
import '../devices/adb/fake_tv.dart';

void main() {
  late AdbHostKey key;
  late Directory home;
  late Directory local;
  late InMemorySecretStore secrets;
  late FakeAdbd adbd;
  late FakeTv tv;
  late OmniEngine engine;

  setUpAll(() => key = AdbHostKey.generateSync());

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_tv_control');
    local = await Directory.systemTemp.createTemp('omni_tv_control_local');
    secrets = InMemorySecretStore();
    await secrets.write(adbHostKeySecret, key.toPem());
    adbd = await FakeAdbd.start();
    tv = FakeTv(adbd);
    tv.apps
      ..['com.netflix.ninja'] = (FakeApp('com.netflix.ninja')
        ..apkPaths = [
          '/data/app/~~a==/com.netflix.ninja-b==/base.apk',
          '/data/app/~~a==/com.netflix.ninja-b==/split_config.arm64_v8a.apk',
        ]
        ..installPermissions = ['android.permission.INTERNET']
        ..runtimePermissions.addAll({
          'android.permission.RECORD_AUDIO': false,
          'android.permission.POST_NOTIFICATIONS': true,
        }))
      ..['in.startv.hotstar'] = FakeApp('in.startv.hotstar');
    adbd.fs
      ..writeFile('/data/app/~~a==/com.netflix.ninja-b==/base.apk', [1, 2, 3])
      ..writeFile(
        '/data/app/~~a==/com.netflix.ninja-b==/split_config.arm64_v8a.apk',
        [4, 5],
      );
    engine = await OmniEngine.open(
      home: home,
      secrets: secrets,
      discoveryTargets: () async => const [],
    );
    final added = await engine.handle('device.add', {
      'id': 'tv',
      'driver': 'android_tv_adb',
      'host': InternetAddress.loopbackIPv4.address,
      'port': adbd.port,
    });
    expect(added['ok'], isTrue, reason: '$added');
  });

  tearDown(() async {
    await engine.close();
    await adbd.close();
    await home.delete(recursive: true);
    await local.delete(recursive: true);
  });

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

  group('screen', () {
    test('tv.screenshot sends the PNG byte for byte over exec', () async {
      final shot = await ok('tv.screenshot', {});
      expect((shot['width'], shot['height']), (32, 18));
      expect(base64Decode(shot['png'] as String), tv.screencap);
      expect(adbd.commands, contains('exec:screencap -p'));

      tv.screencap = [
        ...fakePng(1920, 1080),
        for (var i = 0; i < 300000; i++) i % 256,
      ];
      final big = await ok('tv.screenshot', {});
      expect((big['width'], big['height']), (1920, 1080));
      expect(base64Decode(big['png'] as String), tv.screencap);
    });

    test('a screencap that is not a PNG is a plain error', () async {
      tv.screencap = utf8.encode('screencap: permission denied\n');
      final e = await err('tv.screenshot', {});
      expect(e['message'], contains('did not send a screenshot'));
      expect(e['message'], contains('permission denied'));
    });

    test('tap and swipe turn fractions into pixels of the screen, reading '
        'its size once', () async {
      expect(await ok('tv.input.tap', {'x': 0.5, 'y': 0.25}), {
        'ok': true,
        'id': 'tv',
        'x': 960,
        'y': 270,
      });
      await ok('tv.input.tap', {'x': 1, 'y': 0});
      final swipe = await ok('tv.input.swipe', {
        'x1': 0.1,
        'y1': 0.5,
        'x2': 0.9,
        'y2': 0.5,
      });
      expect(swipe['ms'], 300);
      expect(tv.touches, [
        ['tap', '960', '270'],
        ['tap', '1919', '0'],
        ['swipe', '192', '540', '1728', '540', '300'],
      ]);
      expect(tv.wmSizeReads, 1);
    });

    test('an override size is the one input works in', () async {
      tv.overrideSize = '1280x720';
      await ok('tv.input.swipe', {
        'x1': 0,
        'y1': 0,
        'x2': 0.5,
        'y2': 0.5,
        'ms': 1000,
      });
      expect(tv.touches.single, ['swipe', '0', '0', '640', '360', '1000']);
    });

    test('the size is read again on a new connection', () async {
      await ok('tv.input.tap', {'x': 0.5, 'y': 0.5});
      adbd.dropAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      tv.overrideSize = '1280x720';
      await ok('tv.input.tap', {'x': 0.5, 'y': 0.5});
      expect(tv.touches.last, ['tap', '640', '360']);
      expect(tv.wmSizeReads, 2);
    });

    test('coordinates outside 0 to 1 and a bad ms send nothing', () async {
      for (final (command, args) in [
        ('tv.input.tap', {'x': 1.5, 'y': 0}),
        ('tv.input.tap', {'x': -0.1, 'y': 0}),
        ('tv.input.tap', {'x': '0.5', 'y': 0}),
        ('tv.input.tap', <String, Object?>{'x': 0.5}),
        ('tv.input.swipe', {'x1': 0, 'y1': 0, 'x2': 1, 'y2': 1, 'ms': 10}),
        ('tv.input.swipe', {'x1': 0, 'y1': 0, 'x2': 1, 'y2': 1, 'ms': 6000}),
        ('tv.input.swipe', {'x1': 0, 'y1': 0, 'x2': 2, 'y2': 1}),
      ]) {
        expect((await err(command, args))['type'], 'invalid', reason: '$args');
      }
      expect(tv.touches, isEmpty);
    });

    test('the gamepad keys are in tv.keys with their group, and tv.key '
        'sends them', () async {
      final groups = (await ok('tv.keys', {}))['groups'] as List;
      final gamepad = groups.cast<Map>().singleWhere(
        (g) => g['group'] == 'gamepad',
      );
      final keys = {
        for (final k in (gamepad['keys'] as List).cast<Map>())
          k['key']: k['keycode'],
      };
      expect(keys, {
        'dpad_up': 19,
        'dpad_down': 20,
        'dpad_left': 21,
        'dpad_right': 22,
        'dpad_center': 23,
        'button_a': 96,
        'button_b': 97,
        'button_x': 99,
        'button_y': 100,
        'button_l1': 102,
        'button_r1': 103,
        'button_l2': 104,
        'button_r2': 105,
        'button_thumbl': 106,
        'button_thumbr': 107,
        'button_start': 108,
        'button_select': 109,
        'button_mode': 110,
      });
      for (final k in (gamepad['keys'] as List).cast<Map>()) {
        expect(k['group'], 'gamepad');
        expect(k['label'], isA<String>());
      }
      await ok('tv.key', {'key': 'button_a'});
      await ok('tv.key', {'key': 'button_mode'});
      expect(tv.keys, [
        ['96'],
        ['110'],
      ]);
    });
  });

  group('recording', () {
    test('start, status and stop, leaving a file to download', () async {
      expect(await ok('tv.record.status', {}), {
        'ok': true,
        'id': 'tv',
        'recording': false,
      });
      final started = await ok('tv.record.start', {
        'seconds': 30,
        'bitRate': 4,
      });
      final file = started['file'] as String;
      expect(
        file,
        matches(RegExp(r'^/sdcard/Movies/OmniFlow/rec-\d{8}-\d{6}\.mp4$')),
      );
      expect(started['seconds'], 30);
      expect(DateTime.parse(started['startedAt'] as String).isUtc, isTrue);
      expect(tv.recordCommands.single, [
        'screenrecord',
        '--time-limit',
        '30',
        '--bit-rate',
        '4000000',
        file,
      ]);
      expect(adbd.fs.nodes['/sdcard/Movies/OmniFlow']?.isDir, isTrue);
      final status = await ok('tv.record.status', {});
      expect((status['recording'], status['file']), (true, file));

      final again = await err('tv.record.start', {});
      expect(again['type'], 'conflict');
      expect(tv.recordCommands, hasLength(1));

      final stopped = await ok('tv.record.stop', {});
      expect(stopped, {'ok': true, 'id': 'tv', 'file': file, 'bytes': 4096});
      expect(tv.recording, isFalse);
      expect((await ok('tv.record.status', {}))['recording'], isFalse);

      final out = '${local.path}/rec.mp4';
      await ok('tv.files.download', {'path': file, 'to': out});
      expect(await File(out).length(), 4096);
    });

    test('defaults are 180 s at 6 Mbps', () async {
      final started = await ok('tv.record.start', {});
      expect(started['seconds'], 180);
      expect(tv.recordCommands.single.sublist(1, 5), [
        '--time-limit',
        '180',
        '--bit-rate',
        '6000000',
      ]);
    });

    test('out-of-range seconds or bit rate start nothing', () async {
      for (final args in [
        {'seconds': 0},
        {'seconds': 181},
        {'seconds': 'ten'},
        {'bitRate': 0},
        {'bitRate': 21},
      ]) {
        expect((await err('tv.record.start', args))['type'], 'invalid');
      }
      expect(tv.recordCommands, isEmpty);
    });

    test('a TV without screenrecord or without an encoder says so', () async {
      tv.hasScreenrecord = false;
      expect(
        (await err('tv.record.start', {}))['message'],
        contains('has no screenrecord'),
      );
      tv
        ..hasScreenrecord = true
        ..encoderWorks = false;
      expect(
        (await err('tv.record.start', {}))['message'],
        contains('no video encoder'),
      );
      expect((await ok('tv.record.status', {}))['recording'], isFalse);
    });

    test('stop with nothing recording is refused', () async {
      expect((await err('tv.record.stop', {}))['type'], 'conflict');
    });
  });

  group('system and processes', () {
    test('tv.system reads CPU, memory, storage, network, uptime and '
        'temperature', () async {
      final system = await ok('tv.system', {});
      expect(system, {
        'ok': true,
        'id': 'tv',
        'cpu': {'percent': 50.0},
        'memory': {'totalKb': 2000000, 'availableKb': 800000},
        'storage': [
          {'mount': '/data', 'sizeKb': 12000000, 'usedKb': 8000000},
          {'mount': '/sdcard', 'sizeKb': 12000000, 'usedKb': 8000000},
        ],
        'network': {'rxBytes': 1030000, 'txBytes': 204000},
        'uptimeSeconds': 12345,
        'temperatureC': 52.5,
      });
      expect(
        adbd.commands.where((c) => c.contains('/proc/')),
        hasLength(1),
        reason: 'one round trip',
      );
    });

    test('a TV without readable thermal zones gives no temperature', () async {
      tv.thermal = null;
      expect((await ok('tv.system', {})).containsKey('temperatureC'), isFalse);
    });

    test('tv.processes lists app processes by memory and marks the one on '
        'screen', () async {
      expect((await ok('tv.processes', {}))['apps'], [
        {
          'package': 'com.google.android.youtube.tv',
          'pid': 1200,
          'memoryKb': 150000,
          'foreground': true,
        },
        {
          'package': 'com.netflix.ninja',
          'pid': 1300,
          'memoryKb': 90000,
          'foreground': false,
        },
        {
          'package': 'com.netflix.ninja',
          'pid': 1301,
          'memoryKb': 30000,
          'foreground': false,
        },
      ]);
    });
  });

  group('permissions', () {
    test('tv.app.permissions lists install and runtime permissions', () async {
      final got = await ok('tv.app.permissions', {
        'package': 'com.netflix.ninja',
      });
      expect(got['permissions'], [
        {
          'name': 'android.permission.INTERNET',
          'granted': true,
          'runtime': false,
        },
        {
          'name': 'android.permission.POST_NOTIFICATIONS',
          'granted': true,
          'runtime': true,
        },
        {
          'name': 'android.permission.RECORD_AUDIO',
          'granted': false,
          'runtime': true,
        },
      ]);
      expect(
        (await err('tv.app.permissions', {
          'package': 'com.example.none',
        }))['type'],
        'not_found',
      );
    });

    test('tv.app.permission grants and revokes', () async {
      final app = tv.apps['com.netflix.ninja']!;
      await ok('tv.app.permission', {
        'package': 'com.netflix.ninja',
        'permission': 'android.permission.RECORD_AUDIO',
        'grant': true,
      });
      expect(app.runtimePermissions['android.permission.RECORD_AUDIO'], isTrue);
      final revoked = await ok('tv.app.permission', {
        'package': 'com.netflix.ninja',
        'permission': 'android.permission.RECORD_AUDIO',
        'grant': false,
      });
      expect(revoked['granted'], isFalse);
      expect(
        app.runtimePermissions['android.permission.RECORD_AUDIO'],
        isFalse,
      );
      final refused = await err('tv.app.permission', {
        'package': 'com.netflix.ninja',
        'permission': 'android.permission.CAMERA',
        'grant': true,
      });
      expect(refused['type'], 'device_error');
      expect(refused['message'], contains('has not requested permission'));
    });

    test(
      'an injected package or permission, or no grant, sends nothing',
      () async {
        final before = adbd.commands.length;
        for (final args in [
          {
            'package': "com.netflix.ninja'; reboot; '",
            'permission': 'android.permission.CAMERA',
            'grant': true,
          },
          {
            'package': 'com.netflix.ninja',
            'permission': 'android.permission.CAMERA; reboot',
            'grant': true,
          },
          {
            'package': 'com.netflix.ninja',
            'permission': r'$(reboot)',
            'grant': true,
          },
          {
            'package': 'com.netflix.ninja',
            'permission': 'android.permission.CAMERA',
            'grant': 'yes',
          },
        ]) {
          expect((await err('tv.app.permission', args))['type'], 'invalid');
        }
        expect(
          (await err('tv.app.permissions', {'package': 'a;b'}))['type'],
          'invalid',
        );
        expect(adbd.commands.skip(before), isEmpty);
      },
    );
  });

  group('backup, caches and power', () {
    test(
      'tv.app.backup pulls every APK into the folder, with progress',
      () async {
        final progress = <Map<String, Object?>>[];
        final sub = engine.events.listen((e) {
          if (e['event'] == 'tv.progress') progress.add(e);
        });
        final to = '${local.path}/backup/netflix';
        final got = await ok('tv.app.backup', {
          'package': 'com.netflix.ninja',
          'to': to,
        });
        await sub.cancel();
        expect(got['files'], [
          '$to/com.netflix.ninja.apk',
          '$to/com.netflix.ninja-config.arm64_v8a.apk',
        ]);
        expect(got['bytes'], 5);
        expect(await File('$to/com.netflix.ninja.apk').readAsBytes(), [
          1,
          2,
          3,
        ]);
        expect(
          await File('$to/com.netflix.ninja-config.arm64_v8a.apk')
              .readAsBytes(),
          [4, 5],
        );
        expect(progress.last, containsPair('op', 'backup'));
        expect((progress.last['done'], progress.last['total']), (5, 5));

        final again = await err('tv.app.backup', {
          'package': 'com.netflix.ninja',
          'to': to,
        });
        expect(again['type'], 'conflict');
        await ok('tv.app.backup', {
          'package': 'com.netflix.ninja',
          'to': to,
          'overwrite': true,
        });
      },
    );

    test('a backup of a bad package, an unknown app or to a relative folder '
        'is refused', () async {
      expect(
        (await err('tv.app.backup', {
          'package': r'a.b$(reboot)',
          'to': local.path,
        }))['type'],
        'invalid',
      );
      expect(
        (await err('tv.app.backup', {
          'package': 'com.example.none',
          'to': local.path,
        }))['type'],
        'not_found',
      );
      expect(
        (await err('tv.app.backup', {
          'package': 'com.netflix.ninja',
          'to': 'relative/dir',
        }))['type'],
        'invalid',
      );
    });

    test(
      'a TV that lists something other than an APK path is stopped',
      () async {
        tv.apps['com.netflix.ninja']!.apkPaths = ['relative/base.apk'];
        final e = await err('tv.app.backup', {
          'package': 'com.netflix.ninja',
          'to': local.path,
        });
        expect(e['type'], 'device_error');
        expect(await local.list().isEmpty, isTrue);
      },
    );

    test('tv.cache.trim trims and says what it freed', () async {
      expect(await ok('tv.cache.trim', {}), {
        'ok': true,
        'id': 'tv',
        'freedKb': 5000,
      });
      expect(tv.trims, 1);
    });

    test('tv.power reboots or shuts down, and a dropped connection is '
        'success', () async {
      expect(await ok('tv.power', {'action': 'reboot'}), {
        'ok': true,
        'id': 'tv',
        'action': 'reboot',
      });
      expect(await ok('tv.power', {'action': 'shutdown'}), {
        'ok': true,
        'id': 'tv',
        'action': 'shutdown',
      });
      tv.rebootDrops = false;
      await ok('tv.power', {'action': 'reboot'});
      expect(tv.powerCommands, ['reboot', 'reboot -p', 'reboot']);
      expect((await err('tv.power', {'action': 'halt'}))['type'], 'invalid');
      expect(tv.powerCommands, hasLength(3));
    });

    test('a TV that cannot be reached is an error, not a reboot', () async {
      await adbd.close();
      final e = await err('tv.power', {'action': 'reboot'});
      expect(e['message'], isNotEmpty);
    });
  });

  group('agents', () {
    test('every new command is classified', () {
      const read = ['tv.system', 'tv.processes', 'tv.app.permissions'];
      const setup = [
        'tv.screenshot',
        'tv.input.tap',
        'tv.input.swipe',
        'tv.record.start',
        'tv.record.stop',
        'tv.record.status',
      ];
      const userOnly = [
        'tv.app.permission',
        'tv.app.backup',
        'tv.cache.trim',
        'tv.power',
      ];
      for (final c in read) {
        expect(agentRefusal(c, const {}, AgentAccess.read), isNull, reason: c);
      }
      for (final c in setup) {
        expect(agentRefusal(c, const {}, AgentAccess.read), isNotNull);
        expect(agentRefusal(c, const {}, AgentAccess.setup), isNull, reason: c);
      }
      for (final c in userOnly) {
        expect(
          agentRefusal(c, const {}, AgentAccess.setup),
          contains('for the user only'),
          reason: c,
        );
      }
      for (final c in [...read, ...setup, ...userOnly]) {
        expect(engine.commandNames, contains(c));
      }
    });
  });
}
