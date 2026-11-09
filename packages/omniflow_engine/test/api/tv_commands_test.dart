import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/hub_runtime.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:test/test.dart';

import '../devices/adb/fake_adbd.dart';
import '../devices/adb/fake_tv.dart';
import '../devices/fake_mdns.dart';

void main() {
  late AdbHostKey key;
  late Directory home;
  late Directory local;
  late InMemorySecretStore secrets;
  late FakeAdbd adbd;
  late FakeTv tv;
  late OmniEngine engine;
  var mdnsRecords = <ResourceRecord>[];
  final loopback = InternetAddress.loopbackIPv4.address;

  setUpAll(() => key = AdbHostKey.generateSync());

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_tv');
    local = await Directory.systemTemp.createTemp('omni_tv_local');
    secrets = InMemorySecretStore();
    await secrets.write(adbHostKeySecret, key.toPem());
    adbd = await FakeAdbd.start();
    tv = FakeTv(adbd);
    tv.apps
      ..['com.netflix.ninja'] = FakeApp(
        'com.netflix.ninja',
        versionName: '13.2.2 build 27249',
        versionCode: 27249,
        system: true,
        updatedSystemApp: true,
        apkSizes: [6196081, 70554426],
      )
      ..['in.startv.hotstar'] = FakeApp('in.startv.hotstar', versionCode: 4715)
      ..['com.example.phoneonly'] = FakeApp(
        'com.example.phoneonly',
        leanback: false,
        launcher: true,
      )
      ..['com.tcl.guard'] = FakeApp(
        'com.tcl.guard',
        system: true,
        enabled: 3,
        leanback: false,
      )
      ..['com.example.gone'] = (FakeApp('com.example.gone')..installed = false);
    mdnsRecords = [];
    engine = await OmniEngine.open(
      home: home,
      secrets: secrets,
      discoveryTargets: () async => const [],
      mdns: MdnsDiscovery(client: () => FakeMdns(mdnsRecords)),
    );
    final added = await engine.handle('device.add', {
      'id': 'tv',
      'driver': 'android_tv_adb',
      'host': loopback,
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

  group('state', () {
    test('tv.state reads power, app, playback and volume, and records '
        'them as device state', () async {
      final state = await ok('tv.state', {});
      expect(state, {
        'ok': true,
        'id': 'tv',
        'power': 'on',
        'app': 'com.google.android.youtube.tv',
        'activity':
            'com.google.android.youtube.tv/'
            'com.google.android.apps.youtube.tv.activity.MainActivity',
        'playing': 'playing',
        'volume': 30,
        'volumeMax': 100,
        'muted': false,
      });
      final device =
          (await engine.handle('device.get', {'id': 'tv'}))['device'] as Map;
      expect(device['state'], {
        'power': 'on',
        'app': 'com.google.android.youtube.tv',
        'playing': 'playing',
        'volume': 30,
      });
      expect(
        adbd.commands.where((c) => c.contains('dumpsys')),
        hasLength(1),
        reason: 'one round trip',
      );
    });

    test('an asleep TV with nothing focused and a paused session', () async {
      tv
        ..wakefulness = 'Asleep'
        ..focus = null
        ..muted = true
        ..sessions = [
          ('com.netflix.ninja', false, 'PLAYING(3)'),
          ('com.google.android.youtube.tv', true, 'PAUSED(2)'),
        ];
      final state = await ok('tv.state', {});
      expect(
        (state['power'], state['app'], state['playing'], state['muted']),
        ('asleep', null, 'paused', true),
      );
    });

    test('a TV that does not answer is off', () async {
      await adbd.close();
      final state = await ok('tv.state', {});
      expect(
        (state['power'], state['app'], state['volume']),
        ('off', null, null),
      );
    });

    test('a device that is not a TV over ADB is refused', () async {
      await engine.handle('device.add', {
        'id': 'lamp',
        'driver': 'philips_wiz_udp',
        'host': loopback,
      });
      for (final command in [
        'tv.state',
        'tv.key',
        'tv.files.list',
        'tv.shell',
      ]) {
        final e = Map<String, Object?>.from(
          (await engine.handle(command, {
                'id': 'lamp',
                'key': 'home',
                'path': '/',
                'command': 'id',
              }))['error']
              as Map,
        );
        expect(e['type'], 'invalid', reason: command);
      }
    });

    test('allowPairing false gives needs_user and shows no prompt', () async {
      final e = await err('tv.state', {'allowPairing': false});
      expect(e['type'], 'needs_user');
      expect(adbd.offeredKeys, isEmpty);
    });

    test('a TV added by address learns its mDNS id from its serial', () async {
      await ok('tv.state', {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final device =
          (await engine.handle('device.get', {'id': 'tv'}))['device'] as Map;
      expect(device['stableId'], 'adb-FAKE0123456789');
    });

    test('a TV that moved is found again by its mDNS instance', () async {
      await engine.handle('device.add', {
        'id': 'tv',
        'replace': true,
        'driver': 'android_tv_adb',
        'host': '127.0.0.2',
        'port': adbd.port,
        'stableId': 'adb-FAKE0123456789',
      });
      const instance = 'adb-FAKE0123456789._adb._tcp.local';
      mdnsRecords.addAll([
        ptr('_adb._tcp', instance),
        srv(instance, 'Android.local', adbd.port),
        a('Android.local', '127.0.0.1'),
      ]);
      final moved = <Map<String, Object?>>[];
      final sub = engine.events
          .where((e) => e['event'] == 'device.moved')
          .listen(moved.add);
      addTearDown(sub.cancel);
      final result = await ok('tv.key', {'key': 'home'});
      expect(result['keycode'], 3);
      final device =
          (await engine.handle('device.get', {'id': 'tv'}))['device'] as Map;
      expect(device['host'], '127.0.0.1');
      expect(moved.single, containsPair('to', '127.0.0.1'));
    }, skip: Platform.isMacOS ? null : '127.0.0.2 is not refused everywhere');
  });

  group('remote, text and volume', () {
    test('tv.keys lists every group, with HDMI 1 to 4 at 243 to 246', () async {
      final groups = (await ok('tv.keys', {}))['groups'] as List;
      expect(
        [for (final g in groups) (g as Map)['group']],
        [
          'power',
          'navigation',
          'volume',
          'channel',
          'media',
          'numbers',
          'colors',
          'inputs',
          'system',
        ],
      );
      final inputs = (groups[7] as Map)['keys'] as List;
      expect(
        [
          for (final k in inputs.skip(1).take(4))
            ((k as Map)['key'], k['keycode']),
        ],
        [('hdmi1', 243), ('hdmi2', 244), ('hdmi3', 245), ('hdmi4', 246)],
      );
      final all = [
        for (final g in groups)
          for (final k in (g as Map)['keys'] as List) (k as Map)['key'],
      ];
      expect(all.toSet(), hasLength(all.length), reason: 'names are unique');
      expect(
        all,
        containsAll([
          'settings',
          'guide',
          'info',
          'captions',
          'search',
          'assistant',
          'menu',
          'sleep',
          'wakeup',
          'tv_input',
        ]),
      );
    });

    test('tv.key sends a name, a code, a long press and repeats', () async {
      await ok('tv.key', {'key': 'hdmi2'});
      await ok('tv.key', {'key': 66});
      await ok('tv.key', {'key': '176'});
      await ok('tv.key', {'key': 'ok', 'longPress': true});
      await ok('tv.key', {'key': 'volume_down', 'repeat': 3});
      expect(tv.keys, [
        ['244'],
        ['66'],
        ['176'],
        ['--longpress', '23'],
        ['25', '25', '25'],
      ]);
    });

    test('a key outside the catalog, a bad repeat or a code out of range '
        'sends nothing', () async {
      for (final args in [
        {'key': 'reboot'},
        {'key': 'home; reboot'},
        {'key': 1000},
        {'key': 'home', 'repeat': 21},
        {'key': 'home', 'repeat': 0},
        {'key': 'home', 'longPress': 'yes'},
      ]) {
        expect((await err('tv.key', args))['type'], 'invalid', reason: '$args');
      }
      expect(adbd.commands, isEmpty);
    });

    test('tv.text types spaces as %s inside one quoted word', () async {
      await ok('tv.text', {'text': "it's a test; reboot"});
      expect(tv.typed, ["it's%sa%stest;%sreboot"]);
      expect(adbd.commands.single, r"input text 'it'\''s%sa%stest;%sreboot'");
      for (final text in ['', 'café', 'line\nbreak', 'x' * 501]) {
        expect((await err('tv.text', {'text': text}))['type'], 'invalid');
      }
    });

    test('tv.volume sets the exact level and records it', () async {
      final result = await ok('tv.volume', {'level': 42});
      expect(result, containsPair('volume', 42));
      expect(result, containsPair('method', 'set'));
      expect(tv.volume, 42);
      final device =
          (await engine.handle('device.get', {'id': 'tv'}))['device'] as Map;
      expect((device['state'] as Map)['volume'], 42);
      expect((await err('tv.volume', {'level': 101}))['type'], 'invalid');
      expect(
        (await err('tv.volume', {'level': '5; reboot'}))['type'],
        'invalid',
      );
    });

    test('a TV that ignores --set is moved there with volume keys', () async {
      tv.volumeSetIgnored = true;
      final result = await ok('tv.volume', {'level': 33});
      expect(result['method'], 'keys');
      expect(tv.keys, [
        ['24', '24', '24'],
      ]);
    });
  });

  group('apps', () {
    test(
      'tv.apps lists installed apps with versions, flags and launchers',
      () async {
        final apps = (await ok('tv.apps', {}))['apps'] as List;
        expect(
          [for (final a in apps) (a as Map)['package']],
          [
            'com.example.phoneonly',
            'com.tcl.guard',
            'in.startv.hotstar',
            'com.netflix.ninja',
          ],
          reason: 'by label or package, and com.example.gone is not installed',
        );
        final netflix = apps.cast<Map>().firstWhere(
          (a) => a['package'] == 'com.netflix.ninja',
        );
        expect(netflix, {
          'package': 'com.netflix.ninja',
          'label': 'Netflix',
          'versionName': '13.2.2 build 27249',
          'versionCode': 27249,
          'system': true,
          'enabled': true,
          'launchable': true,
        }, reason: 'the update, not the factory copy');
        final guard = apps.cast<Map>().firstWhere(
          (a) => a['package'] == 'com.tcl.guard',
        );
        expect((guard['enabled'], guard['launchable']), (false, false));
      },
    );

    test('filter and launchableOnly narrow the list', () async {
      List<Object?> names(Map<String, Object?> r) => [
        for (final a in r['apps'] as List) (a as Map)['package'],
      ];
      expect(names(await ok('tv.apps', {'filter': 'user'})), [
        'com.example.phoneonly',
        'in.startv.hotstar',
      ]);
      expect(names(await ok('tv.apps', {'filter': 'system'})), [
        'com.tcl.guard',
        'com.netflix.ninja',
      ]);
      expect(names(await ok('tv.apps', {'launchableOnly': true})), [
        'com.example.phoneonly',
        'in.startv.hotstar',
        'com.netflix.ninja',
      ]);
      expect((await err('tv.apps', {'filter': 'mine'}))['type'], 'invalid');
    });

    test('info gives the version, size, times and SDK levels', () async {
      final app =
          (await ok('tv.app', {
                'package': 'com.netflix.ninja',
                'action': 'info',
              }))['app']
              as Map;
      expect(app['sizeBytes'], 6196081 + 70554426);
      expect(app['versionName'], '13.2.2 build 27249');
      expect(app['targetSdk'], 34);
      expect(app['lastUpdateTime'], '2026-10-31 22:40:09');
      expect(app['launchable'], isTrue);
      expect(
        (await err('tv.app', {
          'package': 'com.not.here',
          'action': 'info',
        }))['type'],
        'not_found',
      );
    });

    test('open, stop, clear, disable, enable and uninstall', () async {
      await ok('tv.app', {'package': 'in.startv.hotstar', 'action': 'open'});
      expect(tv.launched, ['in.startv.hotstar']);
      await ok('tv.app', {'package': 'in.startv.hotstar', 'action': 'stop'});
      expect(tv.stopped, ['in.startv.hotstar']);
      final hotstar = tv.apps['in.startv.hotstar']!;
      await ok('tv.app', {
        'package': 'in.startv.hotstar',
        'action': 'clear_cache',
      });
      await ok('tv.app', {
        'package': 'in.startv.hotstar',
        'action': 'clear_data',
      });
      expect((hotstar.cacheCleared, hotstar.dataCleared), (1, 1));
      await ok('tv.app', {'package': 'in.startv.hotstar', 'action': 'disable'});
      expect(hotstar.enabled, 3);
      await ok('tv.app', {'package': 'in.startv.hotstar', 'action': 'enable'});
      expect(hotstar.enabled, 1);
      await ok('tv.app', {
        'package': 'in.startv.hotstar',
        'action': 'uninstall',
      });
      expect(hotstar.installed, isFalse);
      expect(tv.shellLines, contains("pm uninstall 'in.startv.hotstar'"));
    });

    test('a system app is uninstalled for the user only', () async {
      await ok('tv.app', {
        'package': 'com.netflix.ninja',
        'action': 'uninstall',
      });
      expect(
        tv.shellLines,
        contains("pm uninstall --user 0 'com.netflix.ninja'"),
      );
    });

    test('an app with no launcher fails to open', () async {
      final e = await err('tv.app', {
        'package': 'com.tcl.guard',
        'action': 'open',
      });
      expect(e['type'], 'device_error');
    });

    test('an injected package or unknown action sends nothing', () async {
      for (final args in [
        {'package': "com.x'; reboot; '", 'action': 'open'},
        {'package': 'com.x && reboot', 'action': 'uninstall'},
        {'package': 'in.startv.hotstar', 'action': 'wipe'},
      ]) {
        expect((await err('tv.app', args))['type'], 'invalid', reason: '$args');
      }
      expect(adbd.commands, isEmpty);
    });

    test('tv.install pushes the APK, installs it, removes the copy and '
        'reports progress', () async {
      final apk = File('${local.path}/My App.apk')
        ..writeAsBytesSync(List.filled(150 * 1024, 7));
      final progress = <Map<String, Object?>>[];
      final sub = engine.events
          .where((e) => e['event'] == 'tv.progress')
          .listen(progress.add);
      addTearDown(sub.cancel);
      final result = await ok('tv.install', {
        'path': apk.path,
        'replace': true,
      });
      expect(result, containsPair('installed', 'My App.apk'));
      expect(tv.installs.single.$1, ['-r']);
      expect(tv.installs.single.$2, 150 * 1024);
      expect(
        adbd.fs.nodes.keys.where((p) => p.startsWith('/data/local/tmp/')),
        isEmpty,
      );
      expect(progress.last, {
        'event': 'tv.progress',
        'id': 'tv',
        'op': 'install',
        'done': 150 * 1024,
        'total': 150 * 1024,
      });
      expect(
        (await err('tv.install', {'path': '${local.path}/none.apk'}))['type'],
        'not_found',
      );
      File('${local.path}/notes.txt').writeAsStringSync('x');
      expect(
        (await err('tv.install', {'path': '${local.path}/notes.txt'}))['type'],
        'invalid',
      );
      expect(
        (await err('tv.install', {'path': 'relative.apk'}))['type'],
        'invalid',
      );
    });
  });

  group('settings', () {
    test('the catalog groups typed settings with their live values', () async {
      final categories =
          (await ok('tv.settings.catalog', {}))['categories'] as List;
      expect(
        [for (final c in categories) (c as Map)['category']],
        [
          'Display and sound',
          'Network',
          'Power and sleep',
          'Screensaver',
          'HDMI-CEC',
          'Bluetooth',
          'Accessibility and captions',
          'Developer',
          'Date and time',
          'Location',
          'Other',
        ],
      );
      Map find(String key) =>
          [
            for (final c in categories)
              for (final s in (c as Map)['settings'] as List) s as Map,
          ].where((s) => s['key'] == key).firstOrNull ??
          {};
      expect(find('animator_duration_scale'), {
        'namespace': 'global',
        'key': 'animator_duration_scale',
        'label': 'Animator duration scale',
        'type': 'float',
        'min': 0,
        'max': 10,
        'step': 0.5,
        'unit': 'x',
        'description': contains('Off'),
        'value': 0.5,
      });
      expect(find('screen_off_timeout')['value'], 600000);
      expect(find('screensaver_enabled')['value'], true);
      expect(find('private_dns_mode')['options'], hasLength(3));
      expect(find('font_scale')['value'], isNull, reason: 'never stored');
      expect(find('adb_enabled'), isEmpty, reason: 'not offered');
    });

    test('tv.settings.list gives every setting, or one namespace', () async {
      final all = (await ok('tv.settings.list', {}))['settings'] as List;
      expect(
        all,
        contains(
          equals({
            'namespace': 'global',
            'key': 'multi_line',
            'value': 'first\ncontinued line',
          }),
        ),
      );
      final system =
          (await ok('tv.settings.list', {'namespace': 'system'}))['settings']
              as List;
      expect({for (final s in system) (s as Map)['namespace']}, {'system'});
      expect(
        (await err('tv.settings.list', {'namespace': 'vendor'}))['type'],
        'invalid',
      );
    });

    test(
      'a catalog put checks type and range and writes the stored form',
      () async {
        final result = await ok('tv.settings.put', {
          'namespace': 'global',
          'key': 'animator_duration_scale',
          'value': 1,
        });
        expect(tv.settings['global']!['animator_duration_scale'], '1.0');
        expect(result['previous'], '0.5');
        expect(result['value'], '1.0');
        expect((result['setting'] as Map)['value'], 1.0);
        expect(result['raw'], isFalse);
        for (final (key, value) in [
          ('animator_duration_scale', 11),
          ('animator_duration_scale', 'fast'),
          ('private_dns_mode', 'sometimes'),
        ]) {
          expect(
            (await err('tv.settings.put', {
              'namespace': 'global',
              'key': key,
              'value': value,
            }))['type'],
            'invalid',
            reason: '$key $value',
          );
        }
        expect(
          (await err('tv.settings.put', {
            'namespace': 'secure',
            'key': 'screensaver_enabled',
            'value': 'maybe',
          }))['type'],
          'invalid',
        );
        await ok('tv.settings.put', {
          'namespace': 'secure',
          'key': 'screensaver_enabled',
          'value': false,
        });
        expect(tv.settings['secure']!['screensaver_enabled'], '0');
      },
    );

    test('Bluetooth goes through the Bluetooth service', () async {
      await ok('tv.settings.put', {
        'namespace': 'global',
        'key': 'bluetooth_on',
        'value': false,
      });
      expect(tv.shellLines, contains('cmd bluetooth_manager disable'));
      expect(tv.settings['global']!['bluetooth_on'], '0');
    });

    test('a raw put, a get and a delete', () async {
      final put = await ok('tv.settings.put', {
        'namespace': 'system',
        'key': 'tcl.custom.key',
        'value': "a 'quoted' value",
      });
      expect(put['raw'], isTrue);
      expect(tv.settings['system']!['tcl.custom.key'], "a 'quoted' value");
      final got = await ok('tv.settings.get', {
        'namespace': 'system',
        'key': 'tcl.custom.key',
      });
      expect(got['value'], "a 'quoted' value");
      expect(got.containsKey('setting'), isFalse);
      final known = await ok('tv.settings.get', {
        'namespace': 'system',
        'key': 'screen_off_timeout',
      });
      expect((known['setting'] as Map)['value'], 600000);
      final deleted = await ok('tv.settings.delete', {
        'namespace': 'system',
        'key': 'tcl.custom.key',
      });
      expect(deleted['previous'], "a 'quoted' value");
      expect(tv.settings['system']!.containsKey('tcl.custom.key'), isFalse);
      final missing = await ok('tv.settings.get', {
        'namespace': 'system',
        'key': 'nothing',
      });
      expect(missing['value'], isNull);
    });

    test('settings that cut the engine off and bad keys are refused', () async {
      for (final args in [
        {'namespace': 'global', 'key': 'adb_enabled', 'value': '0'},
        {'namespace': 'global', 'key': 'wifi_on', 'value': '0'},
        {
          'namespace': 'global',
          'key': 'development_settings_enabled',
          'value': '0',
        },
        {'namespace': 'global', 'key': 'x; reboot', 'value': '1'},
        {'namespace': 'global', 'key': 'x', 'value': 'two\nlines'},
        {'namespace': 'vendor', 'key': 'x', 'value': '1'},
      ]) {
        expect(
          (await err('tv.settings.put', args))['type'],
          'invalid',
          reason: '$args',
        );
      }
      expect(
        (await err('tv.settings.delete', {
          'namespace': 'global',
          'key': 'adb_enabled',
        }))['type'],
        'invalid',
      );
      expect(tv.settings['global']!['adb_enabled'], '1');
      expect(adbd.commands, isEmpty);
    });
  });

  group('files', () {
    setUp(() {
      adbd.fs
        ..writeFile(
          '/sdcard/Download/b.txt',
          'bee'.codeUnits,
          mtime: 1700000000,
        )
        ..writeFile("/sdcard/Download/it's here.txt", 'quote'.codeUnits)
        ..mkdirs('/sdcard/Download/Album')
        ..writeFile('/sdcard/Download/Album/1.jpg', List.filled(70000, 1))
        ..writeFile('/sdcard/Download/Album/deep/2.jpg', [2, 2])
        ..link('/sdcard', '/storage/emulated/0')
        ..mkdirs('/storage/emulated/0');
    });

    test('ls lists folders first, then files, without . and ..', () async {
      final result = await ok('tv.files.list', {'path': '/sdcard/Download/'});
      expect(result['path'], '/sdcard/Download');
      final entries = (result['entries'] as List).cast<Map>();
      expect(
        [for (final e in entries) (e['name'], e['type'])],
        [('Album', 'dir'), ('b.txt', 'file'), ("it's here.txt", 'file')],
      );
      expect(entries[1], {
        'name': 'b.txt',
        'type': 'file',
        'size': 3,
        'mode': 'rw-r--r--',
        'modified': '2023-11-14T22:13:20.000Z',
      });
      expect(
        (await err('tv.files.list', {'path': '/sdcard/none'}))['type'],
        'not_found',
      );
      expect(
        (await err('tv.files.list', {
          'path': '/sdcard/Download/b.txt',
        }))['type'],
        'invalid',
      );
      expect((await ok('tv.files.list', {'path': '/'}))['entries'], isNotEmpty);
    });

    test('stat names the type, a link included', () async {
      final stat = await ok('tv.files.stat', {'path': '/sdcard'});
      expect(stat['type'], 'link');
      expect(
        (await ok('tv.files.stat', {'path': '/sdcard/Download/b.txt'}))['size'],
        3,
      );
    });

    test('paths must be absolute and on one line', () async {
      for (final path in ['sdcard', '/sdcard/a\nb', '/a\x00b', '']) {
        expect(
          (await err('tv.files.list', {'path': path}))['type'],
          'invalid',
          reason: path,
        );
      }
    });

    test('get downloads a file, and a folder with everything in it', () async {
      final file = await ok('tv.files.download', {
        'path': "/sdcard/Download/it's here.txt",
        'to': local.path,
      });
      expect(File("${local.path}/it's here.txt").readAsStringSync(), 'quote');
      expect(file['bytes'], 5);
      final progress = <Map<String, Object?>>[];
      final sub = engine.events
          .where((e) => e['event'] == 'tv.progress')
          .listen(progress.add);
      addTearDown(sub.cancel);
      final dir = await ok('tv.files.download', {
        'path': '/sdcard/Download/Album',
        'to': '${local.path}/copy',
      });
      expect((dir['files'], dir['bytes']), (2, 70002));
      expect(File('${local.path}/copy/1.jpg').lengthSync(), 70000);
      expect(File('${local.path}/copy/deep/2.jpg').readAsBytesSync(), [2, 2]);
      expect(progress.last, containsPair('done', 70002));
      expect(progress.last, containsPair('total', 70002));
    });

    test('get will not overwrite a local file unless asked', () async {
      File('${local.path}/b.txt').writeAsStringSync('mine');
      final e = await err('tv.files.download', {
        'path': '/sdcard/Download/b.txt',
        'to': local.path,
      });
      expect(e['type'], 'conflict');
      expect(File('${local.path}/b.txt').readAsStringSync(), 'mine');
      await ok('tv.files.download', {
        'path': '/sdcard/Download/b.txt',
        'to': local.path,
        'overwrite': true,
      });
      expect(File('${local.path}/b.txt').readAsStringSync(), 'bee');
    });

    test('put uploads a file into a folder, and a whole folder', () async {
      File('${local.path}/note one.txt').writeAsStringSync('hello');
      await ok('tv.files.upload', {
        'from': '${local.path}/note one.txt',
        'path': '/sdcard/Download',
      });
      expect(
        String.fromCharCodes(
          adbd.fs.nodes['/sdcard/Download/note one.txt']!.bytes!,
        ),
        'hello',
      );
      final tree = Directory('${local.path}/tree')..createSync();
      File('${tree.path}/a.txt').writeAsStringSync('a');
      Directory('${tree.path}/empty').createSync();
      File('${tree.path}/sub/b.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('bb');
      final result = await ok('tv.files.upload', {
        'from': tree.path,
        'path': '/sdcard/Download',
      });
      expect(
        (result['path'], result['files'], result['bytes']),
        ('/sdcard/Download/tree', 2, 3),
      );
      expect(
        adbd.fs.nodes['/sdcard/Download/tree/sub/b.txt']!.bytes,
        'bb'.codeUnits,
      );
      expect(adbd.fs.nodes['/sdcard/Download/tree/empty']!.isDir, isTrue);
      final again = await err('tv.files.upload', {
        'from': tree.path,
        'path': '/sdcard/Download',
      });
      expect(again['type'], 'conflict');
    });

    test('cp, mv, mkdir, rename and rm', () async {
      await ok('tv.files.mkdir', {'path': '/sdcard/Download/New Folder'});
      expect(adbd.fs.nodes['/sdcard/Download/New Folder']!.isDir, isTrue);
      final copied = await ok('tv.files.copy', {
        'from': "/sdcard/Download/it's here.txt",
        'to': '/sdcard/Download/New Folder',
      });
      expect(copied['to'], "/sdcard/Download/New Folder/it's here.txt");
      expect(
        adbd.fs.nodes.containsKey("/sdcard/Download/New Folder/it's here.txt"),
        isTrue,
      );
      await ok('tv.files.copy', {
        'from': '/sdcard/Download/Album',
        'to': '/sdcard/Download/Album2',
      });
      expect(adbd.fs.nodes['/sdcard/Download/Album2/deep/2.jpg']!.bytes, [
        2,
        2,
      ]);
      expect(
        (await err('tv.files.copy', {
          'from': '/sdcard/Download/b.txt',
          'to': "/sdcard/Download/it's here.txt",
        }))['type'],
        'conflict',
      );
      await ok('tv.files.move', {
        'from': '/sdcard/Download/b.txt',
        'to': '/sdcard/Download/c.txt',
      });
      expect(adbd.fs.nodes.containsKey('/sdcard/Download/b.txt'), isFalse);
      expect(adbd.fs.nodes.containsKey('/sdcard/Download/c.txt'), isTrue);
      final renamed = await ok('tv.files.rename', {
        'path': '/sdcard/Download/c.txt',
        'name': 'd.txt',
      });
      expect(renamed['to'], '/sdcard/Download/d.txt');
      for (final name in ['a/b', '..', '']) {
        expect(
          (await err('tv.files.rename', {
            'path': '/sdcard/Download/d.txt',
            'name': name,
          }))['type'],
          'invalid',
        );
      }
      expect(
        (await err('tv.files.rename', {
          'path': '/sdcard/Download/d.txt',
          'name': 'Album',
        }))['type'],
        'conflict',
      );
      expect(
        (await err('tv.files.delete', {
          'paths': ['/sdcard/Download/Album2'],
        }))['type'],
        'device_error',
        reason: 'a folder needs recursive',
      );
      await ok('tv.files.delete', {
        'paths': ['/sdcard/Download/Album2', '/sdcard/Download/d.txt'],
        'recursive': true,
      });
      expect(
        adbd.fs.nodes.keys.where(
          (p) => p.startsWith('/sdcard/Download/Album2'),
        ),
        isEmpty,
      );
      expect(
        (await err('tv.files.copy', {
          'from': '/sdcard/Download/Album',
          'to': '/sdcard/Download/Album/inside',
        }))['type'],
        'invalid',
      );
    });

    test('rm refuses / and top folders', () async {
      for (final path in ['/', '/sdcard', '/system', '//data/']) {
        expect(
          (await err('tv.files.delete', {
            'paths': [path],
            'recursive': true,
          }))['type'],
          'invalid',
          reason: path,
        );
      }
      expect(
        (await err('tv.files.delete', {'paths': <String>[]}))['type'],
        'invalid',
      );
      expect(adbd.commands, isEmpty);
    });
  });

  group('shell', () {
    test(
      'tv.shell returns output and exit code and keeps the folder',
      () async {
        adbd.fs.mkdirs('/sdcard/Download');
        final first = await ok('tv.shell', {'command': 'echo hi'});
        expect(
          (first['output'], first['exitCode'], first['cwd']),
          ('hi\n', 0, '/'),
        );
        final failed = await ok('tv.shell', {'command': 'false'});
        expect(failed['exitCode'], 1);
        final moved = await ok('tv.shell', {
          'command': 'pwd',
          'cwd': '/sdcard/Download',
        });
        expect(
          (moved['output'], moved['cwd']),
          ('/sdcard/Download\n', '/sdcard/Download'),
        );
        final exited = await ok('tv.shell', {'command': 'exit 3'});
        expect(
          exited['exitCode'],
          isNull,
          reason: 'the shell ended before the marker',
        );
        expect(
          (await err('tv.shell', {'command': 'id', 'timeoutMs': 5}))['type'],
          'invalid',
        );
      },
    );
  });

  group('rules and agents', () {
    test('a rule that changes a setting or an app is high risk, a volume '
        'step is not', () async {
      Future<Map<String, Object?>> save(
        String name,
        Map<String, Object?> step,
      ) async => (await engine.handle('automation.save', {
        'form': 'rule',
        'trusted': false,
        'spec': {
          'name': name,
          'when': [
            {'manual': true},
          ],
          'then': [step],
        },
      }));
      final quiet = await save('Quiet', {
        'do': 'tv.volume',
        'params': {'value': 10},
      });
      expect(quiet['ok'], isTrue, reason: '$quiet');
      expect((quiet['highRisk'], quiet['approved']), (false, true));
      final dns = await save('Dns off', {
        'do': 'tv.set_setting',
        'params': {
          'namespace': 'global',
          'key': 'private_dns_mode',
          'value': 'off',
        },
      });
      expect(dns['ok'], isTrue, reason: '$dns');
      expect((dns['highRisk'], dns['approved']), (true, false));
      final wipe = await save('Wipe', {
        'do': 'tv.manage_app',
        'params': {'package': 'in.startv.hotstar', 'action': 'clear_data'},
      });
      expect((wipe['highRisk'], wipe['approved']), (true, false));
    });

    test('tv.capabilityRisk names the TV changes that need approval', () async {
      Future<Object?> risk(String c) async =>
          (await ok('tv.capabilityRisk', {'capability': c}))['highRisk'];
      expect(await risk('set_setting'), isTrue);
      expect(await risk('manage_app'), isTrue);
      expect(await risk('volume'), isFalse);
      expect(await risk('launch_app'), isFalse);
      expect(
        (await err('tv.capabilityRisk', {'capability': 'nope'}))['type'],
        'not_found',
      );
    });

    test('device.list marks the same TV capabilities high risk', () async {
      final listed = await engine.handle('device.list', {
        'withCapabilities': true,
      });
      final device = (listed['devices'] as List).cast<Map>().singleWhere(
        (d) => d['id'] == 'tv',
      );
      final risk = {
        for (final c in (device['capabilities'] as List).cast<Map>())
          c['id']: c['highRisk'],
      };
      expect(risk['set_setting'], isTrue);
      expect(risk['manage_app'], isTrue);
      expect(risk['volume'], isFalse);
      expect(risk['launch_app'], isFalse);
    });

    test('the volume, key and text capabilities reach the TV', () async {
      await engine.handle('device.invoke', {
        'id': 'tv',
        'capability': 'volume',
        'params': {'value': 12},
      });
      await engine.handle('device.invoke', {
        'id': 'tv',
        'capability': 'press_key',
        'params': {'key': 'hdmi1'},
      });
      await engine.handle('device.invoke', {
        'id': 'tv',
        'capability': 'press_key',
        'params': {'key': 'home', 'longPress': true},
      });
      await engine.handle('device.invoke', {
        'id': 'tv',
        'capability': 'type_text',
        'params': {'text': 'hi there'},
      });
      expect(tv.volume, 12);
      expect(tv.keys, [
        ['243'],
        ['--longpress', '3'],
      ]);
      expect(tv.typed, ['hi%sthere']);
      final bad = await engine.handle('device.invoke', {
        'id': 'tv',
        'capability': 'set_setting',
        'params': {'namespace': 'global', 'key': 'adb_enabled', 'value': '0'},
      });
      expect(bad['ok'], isFalse);
      expect(tv.settings['global']!['adb_enabled'], '1');
    });
  });

  group('hub poll', () {
    test(
      'the hub reads TV state on its interval, and saves only changes',
      () async {
        await ok('tv.state', {});
        await engine.handle('thing.configure', {
          'id': 'tv',
          'settings': {'statePollSeconds': '1'},
        });
        final changes = <Map>[];
        final sub = engine.events
            .where((e) => e['event'] == 'device.stateChanged')
            .map((e) => (e['device'] as Map)['state'] as Map)
            .listen(changes.add);
        addTearDown(sub.cancel);
        final started = await engine.handle('hub.start', {
          'wizPort': 0,
          'helloPort': 0,
        });
        expect(started['ok'], isTrue, reason: '$started');
        tv
          ..focus = 'com.netflix.ninja/.MainActivity'
          ..sessions = [('com.netflix.ninja', true, 'PAUSED(2)')];
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        await engine.handle('hub.stop', {});
        expect(changes, isNotEmpty);
        expect(changes.last, {
          'power': 'on',
          'app': 'com.netflix.ninja',
          'playing': 'paused',
          'volume': 30,
        });
        final distinct = {for (final c in changes) '$c'};
        expect(distinct.length, changes.length, reason: 'no unchanged saves');
      },
    );

    test('statePollSeconds reads 5 by default and 0 turns polls off', () {
      Device withSetting(Object? v) => Device(
        id: 'tv',
        name: 'TV',
        driverId: 'android_tv_adb',
        host: loopback,
        settings: {'statePollSeconds': ?v},
      );
      expect(HubRuntime.tvPollSeconds(withSetting(null)), 5);
      expect(HubRuntime.tvPollSeconds(withSetting('0')), 0);
      expect(HubRuntime.tvPollSeconds(withSetting(12)), 12);
      expect(HubRuntime.tvPollSeconds(withSetting('soon')), 5);
    });
  });
}
