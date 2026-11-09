@Tags(['live'])
library;

import 'dart:io';
import 'dart:math';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Drives the real Android TV through the engine. Run on purpose only:
///
///     dart test -t live test/devices/adb/tv_live_test.dart
///
/// `OMNI_LIVE_HOME` is the engine home holding the paired TV (default
/// `~/.cache/omniflow/tvhome`) and `OMNI_LIVE_TV` its device id (default
/// `tv`). Beyond reads, these tests only press volume up then down and
/// Home, set `animator_duration_scale` to 1 and back, and work inside
/// `/sdcard/Download/omniflow_test`, which they remove at the end.
void main() {
  final env = Platform.environment;
  final home = Directory(
    env['OMNI_LIVE_HOME'] ?? '${env['HOME']}/.cache/omniflow/tvhome',
  );
  final id = env['OMNI_LIVE_TV'] ?? 'tv';
  const folder = '/sdcard/Download/omniflow_test';
  late EngineConnection engine;
  late Directory local;

  setUpAll(() async {
    engine =
        await LocalClient.connect(localSocketPath(home)) ??
        InProcessConnection(
          await OmniEngine.open(home: home, secrets: KeychainSecretStore()),
        );
    local = await Directory.systemTemp.createTemp('omni_tv_live');
  });

  tearDownAll(() async {
    await engine.handle('tv.files.delete', {
      'id': id,
      'paths': [folder],
      'recursive': true,
    });
    await engine.close();
    await local.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(String c, Map<String, Object?> a) async {
    final r = await engine.handle(c, {'id': id, ...a});
    expect(r['ok'], isTrue, reason: '$c: ${r['error']}');
    return r;
  }

  test('state reads power, app, playback and volume', () async {
    final s = await ok('tv.state', {});
    printOnFailure('$s');
    expect(s['power'], anyOf('on', 'asleep'));
    expect(s['volumeMax'], 100);
    expect(s['volume'], inInclusiveRange(0, 100));
    expect(s['playing'], anyOf(isNull, 'playing', 'paused', 'stopped'));
    expect(s['muted'], isA<bool>());
    print(
      'state: power ${s['power']}, app ${s['app']}, playing ${s['playing']}, '
      'volume ${s['volume']}/${s['volumeMax']}',
    );
  });

  test('the TV learns its mDNS id, and mDNS finds it at its address', () async {
    await ok('tv.state', {});
    await Future<void>.delayed(const Duration(seconds: 1));
    final device = (await ok('device.get', {}))['device'] as Map;
    final stableId = device['stableId'];
    expect(stableId, startsWith('adb-'));
    final found =
        (await engine.handle('device.discover', {
              'driver': 'android_tv_adb',
              'windowMs': 3000,
            }))['found']
            as List? ??
        const [];
    final match = found.cast<Map>().where((f) => f['stableId'] == stableId);
    expect(match, isNotEmpty, reason: 'found $found');
    expect(match.first['host'], device['host']);
    print('stable id $stableId found by mDNS at ${match.first['host']}');
  });

  test('apps list versions and launchers, and info reads one app', () async {
    final apps = ((await ok('tv.apps', {}))['apps'] as List).cast<Map>();
    final launchable = apps.where((a) => a['launchable'] == true).toList();
    final user = apps.where((a) => a['system'] == false).toList();
    final netflix = apps.firstWhere((a) => a['package'] == 'com.netflix.ninja');
    expect(netflix['versionName'], isNotEmpty);
    expect(netflix['launchable'], isTrue);
    for (final p in [
      'com.google.android.youtube.tv',
      'com.graymatrix.did',
      'in.startv.hotstar',
      'com.sonyliv',
      'com.amazon.amazonvideo.livingroom',
    ]) {
      expect(apps.map((a) => a['package']), contains(p));
    }
    final info =
        (await ok('tv.app', {
              'package': 'com.netflix.ninja',
              'action': 'info',
            }))['app']
            as Map;
    expect(info['sizeBytes'], greaterThan(1000000));
    print(
      'apps: ${apps.length} installed, ${user.length} user, '
      '${launchable.length} launchable; Netflix ${netflix['versionName']}, '
      '${info['sizeBytes']} bytes',
    );
  });

  test('every catalog setting the TV stores reads as its type', () async {
    final catalog = (await ok('tv.settings.catalog', {}))['categories'] as List;
    final list = ((await ok('tv.settings.list', {}))['settings'] as List)
        .cast<Map>();
    final raw = {
      for (final s in list) '${s['namespace']}/${s['key']}': s['value'],
    };
    var present = 0;
    final absent = <String>[];
    for (final c in catalog.cast<Map>()) {
      for (final s in (c['settings'] as List).cast<Map>()) {
        final key = '${s['namespace']}/${s['key']}';
        final stored = raw[key];
        if (stored == null || stored == 'null') {
          absent.add(key);
          continue;
        }
        present++;
        expect(s['value'], isNotNull, reason: '$key stored as "$stored"');
        if (s['type'] == 'enum') {
          final options = [
            for (final o in s['options'] as List) (o as Map)['value'],
          ];
          expect(options, contains(s['value']), reason: key);
        }
        if (s['min'] != null) {
          expect(
            s['value'] as num,
            greaterThanOrEqualTo(s['min'] as num),
            reason: key,
          );
        }
      }
    }
    final counts = {
      for (final ns in ['system', 'secure', 'global'])
        ns: list.where((s) => s['namespace'] == ns).length,
    };
    expect(counts.values.every((n) => n > 50), isTrue, reason: '$counts');
    print(
      'settings: $counts; catalog $present stored and typed, '
      '${absent.length} never stored: ${absent.join(', ')}',
    );
  });

  test('animator_duration_scale goes to 1 and back', () async {
    final before = await ok('tv.settings.get', {
      'namespace': 'global',
      'key': 'animator_duration_scale',
    });
    final previous = before['value'] as String?;
    try {
      final put = await ok('tv.settings.put', {
        'namespace': 'global',
        'key': 'animator_duration_scale',
        'value': 1,
      });
      expect(put['value'], '1.0');
      expect(put['previous'], previous);
    } finally {
      if (previous == null) {
        await ok('tv.settings.delete', {
          'namespace': 'global',
          'key': 'animator_duration_scale',
        });
      } else {
        await ok('tv.settings.put', {
          'namespace': 'global',
          'key': 'animator_duration_scale',
          'value': previous,
        });
      }
    }
    final after = await ok('tv.settings.get', {
      'namespace': 'global',
      'key': 'animator_duration_scale',
    });
    expect(after['value'], previous);
    print('animator_duration_scale: $previous -> 1.0 -> ${after['value']}');
  });

  test('volume up then down comes back to where it was', () async {
    final before = (await ok('tv.state', {}))['volume'] as int;
    await ok('tv.key', {'key': 'volume_up'});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final up = (await ok('tv.state', {}))['volume'] as int;
    await ok('tv.key', {'key': 'volume_down'});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final after = (await ok('tv.state', {}))['volume'] as int;
    expect(up, greaterThan(before));
    expect(after, before);
    print('volume: $before -> $up -> $after');
  });

  test('Home, unless something is playing', () async {
    final s = await ok('tv.state', {});
    if (s['playing'] == 'playing') {
      markTestSkipped('${s['app']} is playing, so Home is not pressed');
      return;
    }
    final result = await ok('tv.key', {'key': 'home'});
    expect(result['keycode'], 3);
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = await ok('tv.state', {});
    print('home: ${s['app']} -> ${after['app']}');
  });

  test('files: make, upload, list, copy, rename, download, delete', () async {
    final random = Random();
    final bytes = List.generate(200 * 1024 + 3, (_) => random.nextInt(256));
    final file = File('${local.path}/sample.bin')..writeAsBytesSync(bytes);
    final tree = Directory('${local.path}/tree')..createSync();
    File('${tree.path}/a.txt').writeAsStringSync('alpha');
    File('${tree.path}/sub/b.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('beta');

    await ok('tv.files.mkdir', {'path': folder});
    await ok('tv.files.upload', {'from': file.path, 'path': folder});
    await ok('tv.files.upload', {'from': tree.path, 'path': folder});
    final listed =
        (await ok('tv.files.list', {'path': folder}))['entries'] as List;
    expect(
      [for (final e in listed) ((e as Map)['name'], e['type'])],
      [('tree', 'dir'), ('sample.bin', 'file')],
    );
    final stat = await ok('tv.files.stat', {'path': '$folder/sample.bin'});
    expect(stat['size'], bytes.length);
    await ok('tv.files.copy', {
      'from': '$folder/sample.bin',
      'to': '$folder/copy.bin',
    });
    await ok('tv.files.rename', {
      'path': '$folder/copy.bin',
      'name': 'renamed.bin',
    });
    final watch = Stopwatch()..start();
    await ok('tv.files.download', {
      'path': '$folder/renamed.bin',
      'to': '${local.path}/back.bin',
    });
    final seconds = watch.elapsedMilliseconds / 1000;
    expect(File('${local.path}/back.bin').readAsBytesSync(), bytes);
    await ok('tv.files.download', {
      'path': '$folder/tree',
      'to': '${local.path}/tree_back',
    });
    expect(
      File('${local.path}/tree_back/sub/b.txt').readAsStringSync(),
      'beta',
    );
    await ok('tv.files.delete', {
      'paths': [folder],
      'recursive': true,
    });
    final gone = await engine.handle('tv.files.stat', {
      'id': id,
      'path': folder,
    });
    expect((gone['error'] as Map?)?['type'], 'not_found');
    print(
      'files: ${bytes.length} bytes up, copied, renamed and back in '
      '${seconds.toStringAsFixed(2)} s, a folder of 2 files both ways, '
      'then removed',
    );
  });

  test('shell reads with exit codes and a working folder', () async {
    final sdk = await ok('tv.shell', {
      'command': 'getprop ro.build.version.sdk',
    });
    expect((sdk['output'] as String).trim(), '34');
    expect(sdk['exitCode'], 0);
    final failed = await ok('tv.shell', {'command': 'ls /no/such/place'});
    expect(failed['exitCode'], isNot(0));
    final cwd = await ok('tv.shell', {'command': 'pwd', 'cwd': '/sdcard'});
    expect(cwd['cwd'], '/sdcard');
    print(
      'shell: sdk ${sdk['output'].toString().trim()}, '
      'ls of a missing path exit ${failed['exitCode']}, cwd ${cwd['cwd']}',
    );
  });
}
