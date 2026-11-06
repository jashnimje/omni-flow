import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

final sample = Device(
  id: 'desk_lamp',
  name: 'Desk lamp',
  driverId: 'philips_wiz_udp',
  host: '10.0.0.5',
  port: 38899,
  room: 'Study',
  stableId: 'a8bb50aabbcc',
  settings: const {'note': 'by the window'},
  state: const {'state': true, 'dimming': 80},
  lastSeen: DateTime.utc(2026, 11, 6, 18),
);

/// Every DeviceStore must behave the same.
void deviceStoreContract(String name, Future<DeviceStore> Function() create) {
  group('$name meets the DeviceStore contract', () {
    late DeviceStore store;
    setUp(() async => store = await create());

    test('put then get round-trips every field', () async {
      await store.put(sample);
      final got = (await store.get('desk_lamp'))!;
      expect(
        (got.name, got.driverId, got.host, got.port, got.room, got.stableId),
        (
          sample.name,
          sample.driverId,
          sample.host,
          sample.port,
          sample.room,
          sample.stableId,
        ),
      );
      expect(got.settings, sample.settings);
      expect(got.state, sample.state);
      expect(got.lastSeen, sample.lastSeen);
      expect(got.lastSeen!.isUtc, isTrue);
    });

    test('put replaces, all lists, remove deletes', () async {
      await store.put(sample);
      await store.put(sample.copyWith(host: '10.0.0.9'));
      await store.put(
        const Device(id: 'aaa', name: 'A', driverId: 'tuya_plug', host: 'h'),
      );
      expect(
        (await store.all()).map((d) => d.id),
        containsAll(['aaa', 'desk_lamp']),
      );
      expect((await store.get('desk_lamp'))!.host, '10.0.0.9');
      expect(await store.remove('aaa'), isTrue);
      expect(await store.remove('aaa'), isFalse);
      expect(await store.get('aaa'), isNull);
    });
  });
}

void main() {
  deviceStoreContract('InMemoryDeviceStore', () async => InMemoryDeviceStore());
  deviceStoreContract('DriftDeviceStore', () async {
    final db = OmniDatabase.memory();
    addTearDown(db.close);
    return DriftDeviceStore(db);
  });

  test('the database file survives a reopen', () async {
    final dir = await Directory.systemTemp.createTemp('omni_db');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/omniflow.sqlite');
    var db = OmniDatabase.file(file);
    await DriftDeviceStore(db).put(sample);
    await DriftManifestStore(db)
        .put('my_gadget', '{"id":"my_gadget"}', DateTime.utc(2026));
    await db.close();
    db = OmniDatabase.file(file);
    expect((await DriftDeviceStore(db).get('desk_lamp'))!.state, {
      'state': true,
      'dimming': 80,
    });
    expect(await DriftManifestStore(db).all(), ['{"id":"my_gadget"}']);
    await db.close();
  });

  test(
    'a second lock on the same database is refused until released',
    () async {
      final dir = await Directory.systemTemp.createTemp('omni_lock');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/omniflow.sqlite');
      final first = await DatabaseLock.acquire(file);
      final probe = File('${dir.path}/probe.dart')
        ..writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  final f = File(args.single).openSync(mode: FileMode.write);
  try {
    f.lockSync(FileLock.exclusive);
    print('locked');
  } on FileSystemException {
    print('refused');
  }
}
''');
      final other = await Process.run(Platform.resolvedExecutable, [
        'run',
        probe.path,
        '${file.path}.lock',
      ]);
      expect(
        other.stdout.toString().trim(),
        'refused',
        reason: '${other.stderr}',
      );
      await first.release();
      final again = await DatabaseLock.acquire(file);
      await again.release();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'live: the macOS keychain store round-trips a multi-line secret',
    () async {
      final store = KeychainSecretStore(service: 'omniflow-test');
      const key = 'device/test/sshPrivateKey';
      const pem = '-----BEGIN KEY-----\nline "one"\n-----END KEY-----\n';
      try {
        await store.write(key, pem);
        expect(await store.read(key), pem);
        await store.write(key, 'replaced');
        expect(await store.read(key), 'replaced');
      } finally {
        await store.delete(key);
      }
      expect(await store.read(key), isNull);
    },
    tags: 'live',
    testOn: 'mac-os',
    skip: Platform.environment['OMNI_KEYCHAIN_TEST'] == '1'
        ? false
        : 'set OMNI_KEYCHAIN_TEST=1',
  );
}
