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

/// The schema at version 4: version 3 with each flow's source and spec.
List<String> get v4Schema => [
  for (final statement in v3Schema)
    statement.startsWith('CREATE TABLE "flows"')
        ? 'CREATE TABLE "flows" ("id" TEXT NOT NULL, "flow_json" TEXT NOT NULL, '
              '"enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("enabled" IN (0, 1)), '
              '"approved" INTEGER NOT NULL DEFAULT 1 CHECK ("approved" IN (0, 1)), '
              '"trusted" INTEGER NOT NULL DEFAULT 0 CHECK ("trusted" IN (0, 1)), '
              '"source" TEXT NOT NULL DEFAULT \'graph\', "spec_json" TEXT NULL, '
              '"updated_at" INTEGER NOT NULL, PRIMARY KEY ("id"))'
        : statement,
];

/// The schema at version 3: version 2, a trusted column and board describes.
final v3Schema = [
  for (final statement in v2Schema)
    statement.startsWith('CREATE TABLE "flows"')
        ? 'CREATE TABLE "flows" ("id" TEXT NOT NULL, "flow_json" TEXT NOT NULL, "enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("enabled" IN (0, 1)), "approved" INTEGER NOT NULL DEFAULT 1 CHECK ("approved" IN (0, 1)), "trusted" INTEGER NOT NULL DEFAULT 0 CHECK ("trusted" IN (0, 1)), "updated_at" INTEGER NOT NULL, PRIMARY KEY ("id"))'
        : statement,
  'CREATE TABLE "board_describes" ("device_id" TEXT NOT NULL, "describe_json" TEXT NOT NULL, "seen_at" INTEGER NOT NULL, PRIMARY KEY ("device_id"))',
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
      // The v1 tables, as drift created them: unchanged until version 5.
      final ddl = [
        for (final statement in v2Schema)
          if (statement.contains('"devices"') ||
              statement.contains('"driver_manifests"'))
            statement,
      ];
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
      expect(version.read<int>('user_version'), 6);
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
      expect(version.read<int>('user_version'), 6);
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

  test('a v3 database marks links as links and the rest as graphs', () async {
    final dir = await Directory.systemTemp.createTemp('omni_migrate_v3');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/omniflow.sqlite');
    final v3 = sqlite3.open(file.path);
    for (final statement in v3Schema) {
      v3.execute(statement);
    }
    for (final id in ['link_0123456789ab', 'linked_lamps', 'evening']) {
      v3.execute(
        'INSERT INTO flows (id, flow_json, enabled, approved, trusted, updated_at) '
        'VALUES (?, ?, 1, 0, 1, 0)',
        [id, '{"id":"$id"}'],
      );
    }
    v3.execute('PRAGMA user_version = 3');
    v3.close();

    final db = OmniDatabase.file(file);
    addTearDown(db.close);
    final flows = {
      for (final r in await DriftFlowStore(db).all()) r.json['id']: r,
    };
    expect(flows['link_0123456789ab']!.source, FlowRecord.link);
    expect(flows['linked_lamps']!.source, FlowRecord.graph);
    expect(flows['evening']!.source, FlowRecord.graph);
    for (final r in flows.values) {
      expect(r.spec, isNull);
      expect((r.enabled, r.approved, r.trusted), (true, false, true));
    }
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 6);
  });

  test('a v4 database turns each room name into a room record the devices '
      'keep by id, and adds favourites, order and history', () async {
    final dir = await Directory.systemTemp.createTemp('omni_migrate_v4');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/omniflow.sqlite');
    final v4 = sqlite3.open(file.path);
    for (final statement in v4Schema) {
      v4.execute(statement);
    }
    for (final (id, room) in [
      ('lamp', 'Study'),
      ('desk', 'Study'),
      ('tv', 'Living room'),
      ('plug', ''),
      ('fan', null),
      ('bulb', 'study'),
    ]) {
      v4.execute(
        'INSERT INTO devices (id, name, driver_id, host, room) '
        "VALUES (?, ?, 'philips_wiz_udp', '10.0.0.5', ?)",
        [id, id, room],
      );
    }
    v4.execute('PRAGMA user_version = 4');
    v4.close();

    final db = OmniDatabase.file(file);
    addTearDown(db.close);
    expect(
      [for (final r in await DriftRoomStore(db).all()) (r.id, r.name, r.order)],
      [
        ('living_room', 'Living room', 0),
        ('study', 'Study', 1),
        ('study_2', 'study', 2),
      ],
    );
    final devices = {for (final d in await DriftDeviceStore(db).all()) d.id: d};
    expect(
      {for (final d in devices.values) d.id: d.room},
      {
        'bulb': 'study_2',
        'desk': 'study',
        'fan': null,
        'lamp': 'study',
        'plug': null,
        'tv': 'living_room',
      },
    );
    expect(
      devices.values.every((d) => !d.favourite && d.order == null),
      isTrue,
    );
    await DriftDeviceStore(db).put(
      devices['lamp']!
          .copyWith(favourite: true)
          .placed(room: 'study', order: 2),
    );
    final lamp = (await DriftDeviceStore(db).get('lamp'))!;
    expect((lamp.favourite, lamp.order), (true, 2));

    final history = DriftHistoryStore(db, cap: 3);
    final at = DateTime.utc(2026, 11, 8);
    for (var i = 0; i < 5; i++) {
      await history.add('lamp', [
        HistoryEntry(at.add(Duration(minutes: i)), 'dimming', i * 10),
      ]);
    }
    await history.add('tv', [HistoryEntry(at, 'volume', 3, by: 'user')]);
    expect(
      [for (final e in await history.recent('lamp')) e.value],
      [40, 30, 20],
    );
    expect(
      [
        for (final e in await history.recent(
          'lamp',
          since: at.add(const Duration(minutes: 3)),
        ))
          e.value,
      ],
      [40],
    );
    expect((await history.recent('tv')).single.toJson(), {
      'at': '2026-11-08T00:00:00.000Z',
      'key': 'volume',
      'value': 3,
      'by': 'user',
    });
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 6);
  });

  test('a v5 database gains the agent mark on its drivers, once', () async {
    final dir = await Directory.systemTemp.createTemp('omni_migrate_v5');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/omniflow.sqlite');
    final at = DateTime.utc(2026);
    final created = OmniDatabase.file(file);
    await DriftManifestStore(created).put('fan', '{"id":"fan"}', at);
    await created.close();
    for (final dropColumn in [true, false]) {
      final raw = sqlite3.open(file.path);
      if (dropColumn) {
        raw.execute('ALTER TABLE driver_manifests DROP COLUMN by_agent');
      }
      raw.execute('PRAGMA user_version = 5');
      raw.close();

      final db = OmniDatabase.file(file);
      final store = DriftManifestStore(db);
      expect(await store.all(), ['{"id":"fan"}'], reason: '$dropColumn');
      expect(await store.byAgent(), isEmpty);
      await store.put('fan', '{"id":"fan"}', at, byAgent: true);
      expect(await store.byAgent(), {'fan'});
      expect(await store.approve('fan'), isTrue);
      expect(await store.byAgent(), isEmpty);
      expect(await store.approve('ghost'), isFalse);
      await db.close();
    }
  });

  test('a room id comes from its name, unique, with a hash for letters the '
      'slug drops', () {
    expect(uniqueRoomId('Living room', {}), 'living_room');
    expect(uniqueRoomId('Study', {'study'}), 'study_2');
    expect(uniqueRoomId('Study', {'study', 'study_2'}), 'study_3');
    expect(uniqueRoomId('2nd floor', {}), 'room_2nd_floor');
    final hindi = uniqueRoomId('रसोई', {});
    expect(hindi, matches(RegExp(r'^room_[a-z0-9]+$')));
    expect(uniqueRoomId('बैठक', {}), isNot(hindi));
  });

  test('a flow keeps its source and spec unless put names a source', () async {
    final db = OmniDatabase.memory();
    addTearDown(db.close);
    final store = DriftFlowStore(db);
    final at = DateTime.utc(2026);
    await store.put('g', {'id': 'g'}, enabled: true, approved: true, at: at);
    expect((await store.get('g'))!.source, FlowRecord.graph);
    await store.put(
      'r',
      {'id': 'r'},
      enabled: true,
      approved: true,
      at: at,
      source: FlowRecord.rule,
      spec: {'name': 'R'},
    );
    await store.put('r', {'id': 'r'}, enabled: false, approved: true, at: at);
    final kept = (await store.get('r'))!;
    expect((kept.source, kept.enabled), (FlowRecord.rule, false));
    expect(kept.spec, {'name': 'R'});
    await store.put(
      'r',
      {'id': 'r'},
      enabled: true,
      approved: true,
      at: at,
      source: FlowRecord.graph,
    );
    final promoted = (await store.get('r'))!;
    expect((promoted.source, promoted.spec), (FlowRecord.graph, null));
    expect(
      () => store.put(
        'x',
        {'id': 'x'},
        enabled: true,
        approved: true,
        at: at,
        source: 'script',
      ),
      throwsArgumentError,
    );
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
