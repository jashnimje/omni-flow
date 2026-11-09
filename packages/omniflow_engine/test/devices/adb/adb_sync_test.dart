import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/adb/adb_connection.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:omniflow_engine/src/devices/adb/adb_sync.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  late AdbHostKey key;
  late FakeAdbd adbd;
  late AdbConnection connection;
  late Directory temp;

  setUpAll(() => key = AdbHostKey.generateSync());

  setUp(() async {
    adbd = await FakeAdbd.start();
    temp = await Directory.systemTemp.createTemp('omni_adb_sync');
    connection = await AdbConnection.connect(
      InternetAddress.loopbackIPv4.address,
      adbd.port,
      key: key,
      keyName: 'omniflow@test',
    );
  });

  tearDown(() async {
    connection.close();
    await adbd.close();
    await temp.delete(recursive: true);
  });

  Uint8List pattern(int length) => Uint8List.fromList(
    List.generate(length, (i) => (i * 7 + i ~/ 251) & 0xff),
  );

  test('STAT reports a file, a folder, a link, and null for nothing', () async {
    adbd.fs
      ..writeFile('/sdcard/a.txt', [1, 2, 3], mtime: 1700000123)
      ..mkdirs('/sdcard/Movies')
      ..link('/sdcard/latest', '/sdcard/a.txt');
    final sync = await AdbSync.open(connection);

    final file = (await sync.stat('/sdcard/a.txt'))!;
    expect(
      (file.name, file.type, file.size, file.mtime),
      ('a.txt', 'file', 3, 1700000123),
    );
    expect(file.permissions, 'rw-r--r--');
    expect((await sync.stat('/sdcard/Movies'))!.type, 'dir');
    expect((await sync.stat('/sdcard/latest'))!.type, 'link');
    expect(await sync.stat('/sdcard/missing'), isNull);
    expect(file.toJson()['modified'], '2023-11-14T22:15:23.000Z');
    await sync.quit();
    expect(adbd.syncRequests, [
      'STAT /sdcard/a.txt',
      'STAT /sdcard/Movies',
      'STAT /sdcard/latest',
      'STAT /sdcard/missing',
      'QUIT ',
    ]);
  });

  test('LIST leaves out . and .., and lists nothing for a file', () async {
    adbd.fs
      ..writeFile('/sdcard/Download/b.bin', [0])
      ..writeFile('/sdcard/Download/a b.txt', [0])
      ..mkdirs('/sdcard/Download/sub');
    final sync = await AdbSync.open(connection);
    final names = [for (final e in await sync.list('/sdcard/Download')) e.name];
    expect(names, unorderedEquals(['a b.txt', 'b.bin', 'sub']));
    expect(await sync.list('/sdcard/Download/b.bin'), isEmpty);
    await sync.quit();
  });

  test('RECV brings back a file of several chunks byte for byte', () async {
    final bytes = pattern(300 * 1024 + 17);
    adbd.fs.writeFile('/sdcard/big.bin', bytes);
    final sync = await AdbSync.open(connection);
    final got = BytesBuilder();
    final progress = <int>[];
    final n = await sync.pull(
      '/sdcard/big.bin',
      (c) async => got.add(c),
      onProgress: (done, _) => progress.add(done),
    );
    expect(n, bytes.length);
    expect(got.takeBytes(), bytes);
    expect(progress.last, bytes.length);
    expect(progress.length, greaterThan(4), reason: '64 KiB chunks');
    await sync.quit();
  });

  test('SEND writes a file in 64 KiB chunks and keeps its time', () async {
    final bytes = pattern(200 * 1024 + 5);
    final local = File('${temp.path}/up.bin')..writeAsBytesSync(bytes);
    await local.setLastModified(DateTime.utc(2026, 1, 2, 3, 4, 5));
    final sync = await AdbSync.open(connection);
    final progress = <int>[];
    await sync.push(
      local,
      '/sdcard/new/dir/up.bin',
      onProgress: (done, total) {
        expect(total, bytes.length);
        progress.add(done);
      },
    );
    final node = adbd.fs.nodes['/sdcard/new/dir/up.bin']!;
    expect(node.bytes, bytes);
    expect(
      node.mtime,
      DateTime.utc(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000,
    );
    expect(node.mode, adbDefaultFileMode);
    expect(progress, [65536, 131072, 196608, bytes.length]);
    expect(adbd.syncRequests.single, 'SEND /sdcard/new/dir/up.bin,33188');
    await sync.quit();
  });

  test('a FAIL reply becomes AdbSyncException with the reason, and the '
      'session stays usable', () async {
    adbd.fs.mkdirs('/sdcard/Movies');
    final sync = await AdbSync.open(connection);
    await expectLater(
      sync.pull('/sdcard/none', (_) async {}),
      throwsA(
        isA<AdbSyncException>().having(
          (e) => e.message,
          'message',
          'No such file or directory',
        ),
      ),
    );
    final local = File('${temp.path}/x')..writeAsBytesSync([1]);
    await expectLater(
      sync.push(local, '/sdcard/Movies'),
      throwsA(isA<AdbSyncException>()),
    );
    expect((await sync.stat('/sdcard/Movies'))!.type, 'dir');
    await sync.quit();
  });

  test('a path longer than adbd takes is refused before it is sent', () async {
    final sync = await AdbSync.open(connection);
    expect(() => sync.stat('/${'a' * 1100}'), throwsArgumentError);
    expect(adbd.syncRequests, isEmpty);
    await sync.quit();
  });

  test('a device that refuses sync: is reported as refused', () async {
    adbd.refuseSync = true;
    await expectLater(
      AdbSync.open(connection),
      throwsA(isA<AdbStreamRefusedException>()),
    );
  });

  test('a device that stops answering times out instead of hanging', () async {
    adbd.stallSync = true;
    final sync = await AdbSync.open(
      connection,
      timeout: const Duration(milliseconds: 200),
    );
    await expectLater(sync.stat('/sdcard'), throwsA(isA<TimeoutException>()));
    sync.abort();
  });

  test('sync and shell streams share one connection', () async {
    adbd
      ..respond = ((c) => 'out:$c')
      ..fs.writeFile('/f', [9]);
    final sync = await AdbSync.open(connection);
    final both = await Future.wait([
      connection.shell('echo hi', timeout: const Duration(seconds: 2)),
      sync.stat('/f').then((e) => '${e!.size}'),
    ]);
    expect(both, ['out:echo hi', '1']);
    expect(adbd.connections, 1);
    await sync.quit();
  });

  group('through AdbChannel', () {
    late InMemorySecretStore secrets;
    late AdbChannel channel;
    late Device tv;
    final manifest = DriverRegistry.withBuiltIns()['android_tv_adb']!;

    setUp(() async {
      secrets = InMemorySecretStore();
      await secrets.write(adbHostKeySecret, key.toPem());
      channel = AdbChannel(secrets, keyName: 'omniflow@test');
      tv = Device(
        id: 'tv',
        name: 'TV',
        driverId: 'android_tv_adb',
        host: InternetAddress.loopbackIPv4.address,
        port: adbd.port,
      );
    });

    tearDown(() => channel.close());

    test('a stalled transfer fails as a device error and drops the '
        'connection', () async {
      adbd.fs.writeFile('/f', [1]);
      await channel.run(tv, manifest, 'true', offerKey: true);
      adbd.stallSync = true;
      await expectLater(
        channel.sync(
          tv,
          manifest,
          (s) => s.stat('/f'),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('no reply from tv during the transfer'),
          ),
        ),
      );
      adbd.stallSync = false;
      expect((await channel.sync(tv, manifest, (s) => s.stat('/f')))!.size, 1);
    });

    test(
      'a sync session on a dropped connection is opened again once',
      () async {
        await channel.run(tv, manifest, 'true', offerKey: true);
        final before = adbd.connections;
        adbd.dropAll();
        adbd.fs.writeFile('/f', [1, 2]);
        final entry = await channel.sync(tv, manifest, (s) => s.stat('/f'));
        expect(entry!.size, 2);
        expect(adbd.connections, before + 1);
      },
    );

    test(
      'an unpaired TV with no prompt allowed fails with needs pairing',
      () async {
        adbd.trusted.clear();
        final offered = adbd.offeredKeys.length;
        await expectLater(
          channel.sync(tv, manifest, (s) => s.stat('/f')),
          throwsA(isA<PairingRequiredException>()),
        );
        expect(adbd.offeredKeys, hasLength(offered));
      },
    );
  });
}
