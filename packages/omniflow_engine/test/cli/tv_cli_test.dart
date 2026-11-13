import 'dart:async';
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

  setUpAll(() => key = AdbHostKey.generateSync());

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_tv_cli');
    local = await Directory.systemTemp.createTemp('omni_tv_cli_local');
    secrets = InMemorySecretStore();
    await secrets.write(adbHostKeySecret, key.toPem());
    adbd = await FakeAdbd.start();
    tv = FakeTv(adbd);
    tv.apps['in.startv.hotstar'] = FakeApp('in.startv.hotstar');
  });

  tearDown(() async {
    await adbd.close();
    await home.delete(recursive: true);
    await local.delete(recursive: true);
  });

  Future<(int, String, String)> omni(
    List<String> args, {
    Stream<List<int>>? input,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runOmni(
      ['--home', home.path, ...args],
      runner: OmniCommandRunner(
        out: out,
        input: input,
        engineFactory: (h, {tap}) =>
            OmniEngine.open(home: h, secrets: secrets, tap: tap),
        socketPath: '${home.path}/none.sock',
      ),
      err: err,
    );
    return (code, out.toString(), err.toString());
  }

  Future<Map<String, Object?>> json(List<String> args) async {
    final (code, out, err) = await omni(args);
    expect(code, 0, reason: '$out$err');
    return jsonDecode(out) as Map<String, Object?>;
  }

  Future<void> addTv() async {
    final (code, out, _) = await omni([
      'device',
      'add',
      'tv',
      '--driver',
      'android_tv_adb',
      '--host',
      InternetAddress.loopbackIPv4.address,
      '--port',
      '${adbd.port}',
    ]);
    expect(code, 0, reason: out);
  }

  test('remote, text, volume and state', () async {
    await addTv();
    expect(
      (await json(['tv', 'tv', 'remote', 'home', '--long']))['keycode'],
      3,
    );
    await json(['tv', 'tv', 'remote', 'volume_up', '--repeat', '2']);
    await json(['tv', 'tv', 'text', 'hello', 'world']);
    expect((await json(['tv', 'tv', 'volume', '15']))['volume'], 15);
    expect((await json(['tv', 'tv', 'state']))['power'], 'on');
    expect(tv.keys, [
      ['--longpress', '3'],
      ['24', '24'],
    ]);
    expect(tv.typed, ['hello%sworld']);
    final keys = await json(['tv', 'tv', 'keys']);
    expect(keys['groups'], isNotEmpty);
  });

  test('apps and settings', () async {
    await addTv();
    final apps =
        (await json(['tv', 'tv', 'apps', '--filter', 'user']))['apps'] as List;
    expect((apps.single as Map)['package'], 'in.startv.hotstar');
    await json(['tv', 'tv', 'apps', 'clear-cache', 'in.startv.hotstar']);
    expect(tv.apps['in.startv.hotstar']!.cacheCleared, 1);
    final put = await json([
      'tv',
      'tv',
      'settings',
      'set',
      'global',
      'animator_duration_scale',
      '1',
    ]);
    expect((put['previous'], put['value']), ('0.5', '1.0'));
    final got = await json([
      'tv',
      'tv',
      'settings',
      'get',
      'global',
      'animator_duration_scale',
    ]);
    expect(got['value'], '1.0');
    expect((await json(['tv', 'tv', 'settings']))['categories'], isNotEmpty);
    final (code, out, _) = await omni([
      'tv',
      'tv',
      'settings',
      'set',
      'global',
      'adb_enabled',
      '0',
    ]);
    expect(code, 1);
    expect(out, contains('cut this engine off'));
  });

  test('files put, ls, get, mv and rm', () async {
    await addTv();
    adbd.fs.mkdirs('/sdcard/Download');
    final note = File('${local.path}/note.txt')..writeAsStringSync('hi tv');
    final (code, _, err) = await omni([
      'tv',
      'tv',
      'files',
      'put',
      note.path,
      '/sdcard/Download',
    ]);
    expect(code, 0);
    final ls = await json(['tv', 'tv', 'files', 'ls', '/sdcard/Download']);
    expect(
      [for (final e in ls['entries'] as List) (e as Map)['name']],
      ['note.txt'],
    );
    await json([
      'tv',
      'tv',
      'files',
      'mv',
      '/sdcard/Download/note.txt',
      '/sdcard/Download/n2.txt',
    ]);
    final back = '${local.path}/back.txt';
    await json(['tv', 'tv', 'files', 'get', '/sdcard/Download/n2.txt', back]);
    expect(File(back).readAsStringSync(), 'hi tv');
    await json(['tv', 'tv', 'files', 'rm', '/sdcard/Download/n2.txt']);
    expect(adbd.fs.nodes.containsKey('/sdcard/Download/n2.txt'), isFalse);
  });

  test('shell runs one command and exits with its code', () async {
    await addTv();
    final (code, out, _) = await omni([
      'tv',
      'tv',
      'shell',
      'echo',
      'hi',
      'there',
    ]);
    expect((code, out), (0, 'hi there\n'));
    final (failed, _, _) = await omni(['device', 'shell', 'tv', 'false']);
    expect(failed, 1);
  });

  test(
    'device shell with no command is interactive and keeps the folder',
    () async {
      await addTv();
      adbd.fs.mkdirs('/sdcard/Movies');
      final input = Stream.value(utf8.encode('cd /sdcard/Movies\npwd\nexit\n'));
      final (code, out, _) = await omni([
        'device',
        'shell',
        'tv',
      ], input: input);
      expect(code, 0);
      expect(out, contains('tv:/ \$ '));
      expect(out, contains('/sdcard/Movies\ntv:/sdcard/Movies \$ '));
    },
  );

  test('screenshot, tap, swipe, record, system and processes', () async {
    await addTv();
    final png = '${local.path}/shot.png';
    final shot = await json(['tv', 'tv', 'screenshot', '--out', png]);
    expect((shot['width'], shot['out']), (32, png));
    expect(shot.containsKey('png'), isFalse);
    expect(File(png).readAsBytesSync(), tv.screencap);
    await json(['tv', 'tv', 'tap', '0.5', '0.5']);
    await json(['tv', 'tv', 'swipe', '0', '0', '1', '1', '--ms', '500']);
    expect(tv.touches, [
      ['tap', '960', '540'],
      ['swipe', '0', '0', '1919', '1079', '500'],
    ]);
    final started = await json([
      'tv',
      'tv',
      'record',
      'start',
      '--seconds',
      '10',
      '--bit-rate',
      '2',
    ]);
    expect(started['seconds'], 10);
    expect((await json(['tv', 'tv', 'record', 'status']))['recording'], true);
    await json(['tv', 'tv', 'record', 'stop']);
    expect(tv.recording, isFalse);
    expect((await json(['tv', 'tv', 'system']))['uptimeSeconds'], 12345);
    expect((await json(['tv', 'tv', 'processes']))['apps'], isNotEmpty);
  });

  test('permissions, backup, trim-caches and power', () async {
    await addTv();
    tv.apps['in.startv.hotstar']!
      ..apkPaths = ['/data/app/h/base.apk']
      ..runtimePermissions['android.permission.RECORD_AUDIO'] = false;
    adbd.fs.writeFile('/data/app/h/base.apk', [9, 9]);
    final perms = await json(['tv', 'tv', 'permissions', 'in.startv.hotstar']);
    expect(
      (perms['permissions'] as List).single,
      containsPair('runtime', true),
    );
    await json([
      'tv',
      'tv',
      'permission',
      'in.startv.hotstar',
      'android.permission.RECORD_AUDIO',
      '--grant',
    ]);
    expect(
      tv.apps['in.startv.hotstar']!.runtimePermissions.values.single,
      isTrue,
    );
    final backup = await json([
      'tv',
      'tv',
      'backup',
      'in.startv.hotstar',
      '--to',
      '${local.path}/apks',
    ]);
    expect(backup['files'], ['${local.path}/apks/in.startv.hotstar.apk']);

    final (no, said, _) = await omni([
      'tv',
      'tv',
      'power',
      'reboot',
    ], input: Stream.value(utf8.encode('n\n')));
    expect(no, 1);
    expect(said, contains('Restart tv? [y/N]'));
    expect(tv.powerCommands, isEmpty);
    final (yes, _, _) = await omni([
      'tv',
      'tv',
      'power',
      'shutdown',
    ], input: Stream.value(utf8.encode('y\n')));
    expect(yes, 0);
    await json(['tv', 'tv', 'power', 'reboot', '--yes']);
    expect(tv.powerCommands, ['reboot -p', 'reboot']);
    final (none, _, _) = await omni([
      'tv',
      'tv',
      'trim-caches',
    ], input: const Stream.empty());
    expect(none, 1);
    expect(tv.trims, 0);
    expect((await json(['tv', 'tv', 'trim-caches', '--yes']))['freedKb'], 5000);
  });

  test('the new verbs check their words before sending', () async {
    await addTv();
    for (final args in [
      ['tap', '0.5'],
      ['swipe', '0', '0', '1'],
      ['record', 'pause'],
      ['permission', 'a.b', 'c.d'],
      ['permission', 'a.b', 'c.d', '--grant', '--revoke'],
      ['backup', 'a.b'],
      ['power', 'halt', '--yes'],
      ['screenshot', 'extra'],
    ]) {
      expect((await omni(['tv', 'tv', ...args])).$1, 64, reason: '$args');
    }
    expect(adbd.commands, isEmpty);
  });

  test('a missing verb or bad option is a usage error', () async {
    await addTv();
    expect((await omni(['tv', 'tv'])).$1, 64);
    expect((await omni(['tv', 'tv', 'dance'])).$1, 64);
    expect((await omni(['tv', 'tv', 'remote', 'home', '--repeat'])).$1, 64);
    expect((await omni(['tv', 'tv', 'settings', 'get', 'global'])).$1, 64);
    expect(adbd.commands, isEmpty);
  });
}
