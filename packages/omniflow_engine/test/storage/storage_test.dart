import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:sqlite3/sqlite3.dart';
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

/// The schema at version 2, as drift created it.
const v2Schema = [
  'CREATE TABLE "driver_manifests" ("id" TEXT NOT NULL, "manifest_json" TEXT NOT NULL, "updated_at" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "devices" ("id" TEXT NOT NULL, "name" TEXT NOT NULL, "driver_id" TEXT NOT NULL, "host" TEXT NOT NULL, "port" INTEGER NULL, "room" TEXT NULL, "stable_id" TEXT NULL, "settings_json" TEXT NOT NULL DEFAULT \'{}\', "state_json" TEXT NOT NULL DEFAULT \'{}\', "last_seen" INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "flows" ("id" TEXT NOT NULL, "flow_json" TEXT NOT NULL, "enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("enabled" IN (0, 1)), "approved" INTEGER NOT NULL DEFAULT 1 CHECK ("approved" IN (0, 1)), "updated_at" INTEGER NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "zones" ("id" TEXT NOT NULL, "zone_json" TEXT NOT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "global_variables" ("name" TEXT NOT NULL, "value_json" TEXT NOT NULL, "updated_at" INTEGER NOT NULL, PRIMARY KEY ("name"))',
  'CREATE TABLE "execution_log" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "run_id" TEXT NOT NULL, "flow_id" TEXT NOT NULL, "outcome" TEXT NOT NULL, "started_at" INTEGER NOT NULL, "trace_json" TEXT NOT NULL)',
];

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
    'a v1 database migrates to the current schema and keeps its devices',
    () async {
      final dir = await Directory.systemTemp.createTemp('omni_migrate');
      addTearDown(() => dir.delete(recursive: true));
      // The v1 tables, exactly as drift creates them (unchanged since).
      final reference = OmniDatabase.memory();
      await DriftDeviceStore(reference).all();
      final ddl = [
        for (final row
            in await reference
                .customSelect(
                  "SELECT sql FROM sqlite_master WHERE name IN ('devices', 'driver_manifests')",
                )
                .get())
          row.read<String>('sql'),
      ];
      await reference.close();
      expect(ddl, hasLength(2));
      final file = File('${dir.path}/omniflow.sqlite');
      final v1 = sqlite3.open(file.path);
      for (final statement in ddl) {
        v1.execute(statement);
      }
      v1.execute(
        "INSERT INTO devices (id, name, driver_id, host) VALUES ('desk_lamp', 'Desk lamp', 'philips_wiz_udp', '10.0.0.5')",
      );
      v1.execute('PRAGMA user_version = 1');
      v1.close();

      final db = OmniDatabase.file(file);
      addTearDown(db.close);
      expect((await DriftDeviceStore(db).get('desk_lamp'))!.host, '10.0.0.5');
      await DriftFlowStore(db).put(
        'f',
        {'id': 'f'},
        enabled: true,
        approved: true,
        at: DateTime.utc(2026),
      );
      await DriftZoneStore(db).put('desk', {'id': 'desk'});
      await DriftGlobalStore(db).put('HomeMode', 'home', DateTime.utc(2026));
      expect((await DriftFlowStore(db).get('f'))!.approved, isTrue);
      expect(await DriftZoneStore(db).all(), [
        {'id': 'desk'},
      ]);
      expect(await DriftGlobalStore(db).all(), {'HomeMode': 'home'});
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 3);
    },
  );

  test(
    'a v2 database moves each flow trust mark into the trusted column',
    () async {
      final dir = await Directory.systemTemp.createTemp('omni_migrate_v2');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/omniflow.sqlite');
      final v2 = sqlite3.open(file.path);
      // The version 2 schema, frozen as drift created it.
      for (final statement in v2Schema) {
        v2.execute(statement);
      }
      void flow(String id, String json) => v2.execute(
        'INSERT INTO flows (id, flow_json, enabled, approved, updated_at) '
        'VALUES (?, ?, 1, 1, 0)',
        [id, json],
      );
      flow('mine', '{"id":"mine","nodes":[],"_trusted":true}');
      flow('theirs', '{"id":"theirs","nodes":[]}');
      flow('marked_false', '{"id":"marked_false","_trusted":false}');
      v2.execute(
        "INSERT INTO devices (id, name, driver_id, host) VALUES ('desk_lamp', 'Desk lamp', 'philips_wiz_udp', '10.0.0.5')",
      );
      v2.execute('PRAGMA user_version = 2');
      v2.close();

      final db = OmniDatabase.file(file);
      addTearDown(db.close);
      final flows = {
        for (final r in await DriftFlowStore(db).all()) r.json['id']: r,
      };
      expect(flows['mine']!.trusted, isTrue);
      expect(flows['mine']!.json, {'id': 'mine', 'nodes': <Object?>[]});
      expect(flows['theirs']!.trusted, isFalse);
      expect(flows['marked_false']!.trusted, isFalse);
      expect(flows['marked_false']!.json, {'id': 'marked_false'});
      for (final r in flows.values) {
        expect(r.approved, isTrue);
        expect(r.enabled, isTrue);
      }
      expect((await DriftDeviceStore(db).get('desk_lamp'))!.host, '10.0.0.5');
      await DriftBoardDescribeStore(db)
          .put('desk', const {'board': 'esp32'}, DateTime.utc(2026));
      expect((await DriftBoardDescribeStore(db).get('desk'))!.describe, {
        'board': 'esp32',
      });
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 3);
    },
  );

  test('a flow keeps its trusted flag, false unless put says so', () async {
    final db = OmniDatabase.memory();
    addTearDown(db.close);
    final store = DriftFlowStore(db);
    await store.put(
      'a',
      {'id': 'a'},
      enabled: true,
      approved: true,
      trusted: true,
      at: DateTime.utc(2026),
    );
    await store.put(
      'b',
      {'id': 'b'},
      enabled: true,
      approved: false,
      at: DateTime.utc(2026),
    );
    expect((await store.get('a'))!.trusted, isTrue);
    expect((await store.get('b'))!.trusted, isFalse);
    await store.put(
      'a',
      {'id': 'a'},
      enabled: true,
      approved: true,
      at: DateTime.utc(2026),
    );
    expect((await store.get('a'))!.trusted, isFalse);
  });

  test('the last describe of each board is kept and replaced', () async {
    final db = OmniDatabase.memory();
    addTearDown(db.close);
    final store = DriftBoardDescribeStore(db);
    expect(await store.get('desk'), isNull);
    await store.put('desk', const {
      'board': 'esp32',
      'watches': 8,
    }, DateTime.utc(2026, 11, 7));
    await store.put('desk', const {
      'board': 'esp8266',
    }, DateTime.utc(2026, 11, 8));
    final kept = (await store.get('desk'))!;
    expect(kept.describe, {'board': 'esp8266'});
    expect(kept.seenAt, DateTime.utc(2026, 11, 8));
    expect(kept.seenAt.isUtc, isTrue);
    expect(await store.remove('desk'), isTrue);
    expect(await store.get('desk'), isNull);
  });

  test('the execution log keeps only the newest rows', () async {
    final db = OmniDatabase.memory();
    addTearDown(db.close);
    final log = ExecutionLogStore(db, cap: 3);
    for (var i = 1; i <= 5; i++) {
      await log.add({
        'run': 'r$i',
        'flow': i.isEven ? 'even' : 'odd',
        'outcome': 'completed',
        'startedAt': '2026-11-06T19:00:0${i}Z',
      });
    }
    expect((await log.recent()).map((t) => t['run']), ['r5', 'r4', 'r3']);
    expect((await log.recent(flowId: 'even')).map((t) => t['run']), ['r4']);
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
