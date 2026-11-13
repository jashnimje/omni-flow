import 'dart:typed_data';

import 'package:omniflow_engine/src/devices/adb/tv_system.dart';
import 'package:test/test.dart';

import 'fake_tv.dart';

void main() {
  test('pngSize reads IHDR and refuses anything else', () {
    expect(pngSize(Uint8List.fromList(fakePng(7, 3))), (7, 3));
    expect(pngSize(Uint8List.fromList([1, 2, 3])), isNull);
    expect(pngSize(Uint8List.fromList(List.filled(40, 0))), isNull);
  });

  test('parseWmSize prefers the override size', () {
    expect(parseWmSize('Physical size: 3840x2160\n'), (3840, 2160));
    expect(
      parseWmSize('Physical size: 3840x2160\nOverride size: 1920x1080\n'),
      (1920, 1080),
    );
    expect(parseWmSize('error'), isNull);
  });

  test('cpuPercent counts iowait as idle', () {
    expect(
      cpuPercent(
        'cpu  100 0 100 800 0 0 0 0 0 0',
        'cpu  150 0 150 850 50 0 0 0 0 0',
      ),
      50.0,
    );
    expect(cpuPercent('cpu0 1 2 3 4', 'cpu0 1 2 3 4'), isNull);
    expect(cpuPercent('cpu  1 1 1 1', 'cpu  1 1 1 1'), 0);
  });

  test('parseMeminfo falls back without MemAvailable', () {
    expect(
      parseMeminfo(
        'MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 10 kB\nCached: 50 kB\n',
      ),
      (totalKb: 1000, availableKb: 160),
    );
    expect(parseMeminfo('nothing'), isNull);
  });

  test('parseDf joins wrapped names and keeps one row per mount', () {
    final rows = parseDf(
      'Filesystem 1K-blocks Used Available Use% Mounted on\n'
      '/dev/block/bootdevice/by-name/userdata\n'
      '                 1000   400   600  40% /data\n'
      '/dev/fuse 1000 400 600 40% /storage/emulated\n'
      '/dev/fuse 1000 400 600 40% /storage/emulated\n'
      'df: /nope: No such file or directory\n',
    );
    expect(rows, [
      (mount: '/data', sizeKb: 1000, usedKb: 400, availableKb: 600),
      (mount: '/storage/emulated', sizeKb: 1000, usedKb: 400, availableKb: 600),
    ]);
  });

  test('parseNetDev skips loopback', () {
    expect(
      parseNetDev(
        'Inter-| Receive | Transmit\n face |bytes ...|bytes ...\n'
        '  lo: 9 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\n'
        'eth0: 10 1 0 0 0 0 0 0 20 1 0 0 0 0 0 0\n',
      ),
      (rxBytes: 10, txBytes: 20),
    );
  });

  test('parseUptime and parseThermal', () {
    expect(parseUptime('99.9 10.0\n'), 99);
    expect(parseThermal('45000\n38\n200000\n'), 45.0);
    expect(parseThermal(''), isNull);
  });

  test('parsePs keeps app processes, largest first', () {
    final apps = parsePs(
      'PID RSS NAME\n1 10 init\n2 0 [kworker/0:1]\n3 900 /system/bin/vold\n'
      '4 50 com.a.b\n5 70 com.c.d:remote\n6 70 zygote64\n',
    );
    expect(
      [for (final a in apps) (a.package, a.pid)],
      [('com.c.d', 5), ('com.a.b', 4)],
    );
  });

  test('parsePermissions reads install and runtime sections only', () {
    final p = parsePermissions(
      '    requested permissions:\n'
      '      android.permission.CAMERA\n'
      '    install permissions:\n'
      '      android.permission.INTERNET: granted=true\n'
      '    User 0: installed=true\n'
      '      runtime permissions:\n'
      '        android.permission.CAMERA: granted=false, flags=[ ]\n'
      '      disabledComponents:\n'
      '        com.x.Y: granted=true\n',
    );
    expect(p, [
      (name: 'android.permission.CAMERA', granted: false, runtime: true),
      (name: 'android.permission.INTERNET', granted: true, runtime: false),
    ]);
  });

  test('APK backup names stay plain file names', () {
    expect(apkBackupName('com.a', '/data/app/x/base.apk'), 'com.a.apk');
    expect(
      apkBackupName('com.a', '/data/app/x/split_config.en.apk'),
      'com.a-config.en.apk',
    );
    expect(apkBackupName('com.a', '/data/app/x/we ird/..apk'), 'com.a-..apk');
    expect(parsePmPath('package:/a/base.apk\npackage:/a/split_x.apk\n'), [
      '/a/base.apk',
      '/a/split_x.apk',
    ]);
  });
}
