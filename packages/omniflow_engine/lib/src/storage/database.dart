import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../devices/device.dart';

part 'database.g.dart';

/// User driver manifests. Built-ins are embedded and never stored.
@DataClassName('ManifestRow')
class DriverManifests extends Table {
  TextColumn get id => text()();
  TextColumn get manifestJson => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DeviceRow')
class Devices extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get driverId => text()();
  TextColumn get host => text()();
  IntColumn get port => integer().nullable()();
  TextColumn get room => text().nullable()();
  TextColumn get stableId => text().nullable()();

  /// Non-secret settings as JSON.
  TextColumn get settingsJson => text().withDefault(const Constant('{}'))();
  TextColumn get stateJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get lastSeen => dateTime().nullable()();
  BoolColumn get favourite => boolean().withDefault(const Constant(false))();

  /// The device's place among its room's devices, lowest first.
  IntColumn get position => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The rooms devices are in, in the order the user put them.
@DataClassName('RoomRow')
class Rooms extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Each device's state changes, newest last, capped per device by
/// [DriftHistoryStore.cap].
@DataClassName('HistoryRow')
@TableIndex(name: 'device_history_device', columns: {#deviceId, #id})
class DeviceHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get deviceId => text()();
  TextColumn get key => text()();
  TextColumn get valueJson => text()();
  DateTimeColumn get at => dateTime()();

  /// The automation that made the change, or `user`. Null when the device
  /// reported it.
  TextColumn get changedBy => text().nullable()();
}

@DataClassName('FlowRow')
class Flows extends Table {
  TextColumn get id => text()();
  TextColumn get flowJson => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// False while a flow from MCP, the AI architect or an import waits for
  /// the user to approve its high-risk parts.
  BoolColumn get approved => boolean().withDefault(const Constant(true))();

  /// True when the user saved or approved this version of the flow, so a
  /// later rise in its risk does not revoke the approval.
  BoolColumn get trusted => boolean().withDefault(const Constant(false))();

  /// The form the automation was written in: `link`, `rule`, `graph` or `scene`,
  /// so each surface reopens it as it was written.
  TextColumn get source =>
      text().withDefault(const Constant(FlowRecord.graph))();

  /// The link or rule the flow was compiled from. Null for a graph, which
  /// is its own spec.
  TextColumn get specJson => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ZoneRow')
class Zones extends Table {
  TextColumn get id => text()();
  TextColumn get zoneJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('GlobalRow')
class GlobalVariables extends Table {
  TextColumn get name => text()();
  TextColumn get valueJson => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {name};
}

/// The last describe reply each board gave, so a board that is offline can
/// still show what its pins can do. Kept out of the device state, which
/// users see and flows read.
@DataClassName('BoardDescribeRow')
class BoardDescribes extends Table {
  TextColumn get deviceId => text()();
  TextColumn get describeJson => text()();
  DateTimeColumn get seenAt => dateTime()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// Run traces, kept as a ring buffer of the newest [ExecutionLogStore.cap] rows.
@DataClassName('LogRow')
class ExecutionLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get runId => text()();
  TextColumn get flowId => text()();
  TextColumn get outcome => text()();
  DateTimeColumn get startedAt => dateTime()();
  TextColumn get traceJson => text()();
}

/// The engine's SQLite database. Schema changes bump [schemaVersion] and add
/// a step to [migration].
@DriftDatabase(
  tables: [
    DriverManifests,
    Devices,
    Flows,
    Zones,
    GlobalVariables,
    ExecutionLog,
    BoardDescribes,
    Rooms,
    DeviceHistory,
  ],
)
class OmniDatabase extends _$OmniDatabase {
  OmniDatabase(super.executor);

  /// Opens (or creates) the database file at [file] on a background isolate.
  factory OmniDatabase.file(File file) =>
      OmniDatabase(NativeDatabase.createInBackground(file));

  factory OmniDatabase.memory() => OmniDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 5;

  /// The key version 2 kept the trust mark under, inside the flow JSON.
  static const legacyTrustedKey = '_trusted';

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // Created with today's columns, so the version 3 steps are done too.
        await m.createTable(flows);
        await m.createTable(zones);
        await m.createTable(globalVariables);
        await m.createTable(executionLog);
      } else if (from < 3) {
        await m.addColumn(flows, flows.trusted);
        await _moveTrustMarksToColumn();
      }
      if (from < 3) await m.createTable(boardDescribes);
      if (from >= 2 && from < 4) {
        await m.addColumn(flows, flows.source);
        await m.addColumn(flows, flows.specJson);
        // A link's spec is rebuilt from its flow when the engine opens.
        await customStatement(
          "UPDATE flows SET source = 'link' WHERE id LIKE 'link\\_%' ESCAPE '\\'",
        );
      }
      if (from < 5) {
        await m.addColumn(devices, devices.favourite);
        await m.addColumn(devices, devices.position);
        await m.createTable(rooms);
        await m.createTable(deviceHistory);
        await m.createIndex(deviceHistoryDevice);
        await _moveRoomNamesToRecords();
      }
    },
  );

  /// Before version 5 a device kept its room as a name. Each name becomes a
  /// room record, in name order, and the device keeps the record's id.
  Future<void> _moveRoomNamesToRecords() async {
    await customStatement("UPDATE devices SET room = NULL WHERE room = ''");
    final names = [
      for (final row in await customSelect(
        'SELECT DISTINCT room FROM devices WHERE room IS NOT NULL ORDER BY room',
      ).get())
        row.read<String>('room'),
    ];
    final ids = <String, String>{};
    for (var i = 0; i < names.length; i++) {
      final id = uniqueRoomId(names[i], ids.values.toSet());
      ids[names[i]] = id;
      await customStatement(
        'INSERT INTO rooms (id, name, position) VALUES (?, ?, ?)',
        [id, names[i].trim(), i],
      );
    }
    // By device, since a new room id can equal another room's old name.
    for (final row in await customSelect(
      'SELECT id, room FROM devices WHERE room IS NOT NULL',
    ).get()) {
      await customStatement('UPDATE devices SET room = ? WHERE id = ?', [
        ids[row.read<String>('room')],
        row.read<String>('id'),
      ]);
    }
  }

  Future<void> _moveTrustMarksToColumn() async {
    for (final row in await customSelect(
      'SELECT id, flow_json FROM flows',
    ).get()) {
      final Object? decoded;
      try {
        decoded = jsonDecode(row.read<String>('flow_json'));
      } on FormatException {
        continue;
      }
      if (decoded is! Map || !decoded.containsKey(legacyTrustedKey)) continue;
      final trusted = decoded.remove(legacyTrustedKey) == true;
      await customStatement(
        'UPDATE flows SET flow_json = ?, trusted = ? WHERE id = ?',
        [jsonEncode(decoded), trusted ? 1 : 0, row.read<String>('id')],
      );
    }
  }
}

class FlowRecord {
  const FlowRecord(
    this.json, {
    required this.enabled,
    required this.approved,
    this.trusted = false,
    this.source = graph,
    this.spec,
  });

  static const link = 'link';
  static const rule = 'rule';
  static const graph = 'graph';
  static const scene = 'scene';
  static const sources = [link, rule, graph, scene];

  final Map<String, Object?> json;
  final bool enabled;
  final bool approved;

  /// Whether the user saved or approved this version of the flow.
  final bool trusted;

  /// How the automation was written: [link], [rule], [graph] or [scene].
  final String source;

  /// The link or rule [json] was compiled from, or null for a graph.
  final Map<String, Object?>? spec;
}

class DriftFlowStore {
  DriftFlowStore(this._db);

  final OmniDatabase _db;

  Future<List<FlowRecord>> all() async => [
    for (final r in await (_db.select(
      _db.flows,
    )..orderBy([(f) => OrderingTerm(expression: f.id)])).get())
      _toRecord(r),
  ];

  Future<FlowRecord?> get(String id) async {
    final r = await (_db.select(
      _db.flows,
    )..where((f) => f.id.equals(id))).getSingleOrNull();
    return r == null ? null : _toRecord(r);
  }

  static FlowRecord _toRecord(FlowRow r) => FlowRecord(
    Map<String, Object?>.from(jsonDecode(r.flowJson) as Map),
    enabled: r.enabled,
    approved: r.approved,
    trusted: r.trusted,
    source: r.source,
    spec: _specOf(r.specJson),
  );

  static Map<String, Object?>? _specOf(String? json) {
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// Saves a flow. With no [source], a stored row keeps its source and spec
  /// (enabling, approving), and a new row is a graph.
  Future<void> put(
    String id,
    Map<String, Object?> json, {
    required bool enabled,
    required bool approved,
    bool trusted = false,
    required DateTime at,
    String? source,
    Map<String, Object?>? spec,
  }) {
    if (source != null && !FlowRecord.sources.contains(source)) {
      throw ArgumentError('source must be one of ${FlowRecord.sources}');
    }
    return _db
        .into(_db.flows)
        .insertOnConflictUpdate(
          FlowsCompanion.insert(
            id: id,
            flowJson: jsonEncode(json),
            enabled: Value(enabled),
            approved: Value(approved),
            trusted: Value(trusted),
            source: source == null ? const Value.absent() : Value(source),
            specJson: source == null
                ? const Value.absent()
                : Value(spec == null ? null : jsonEncode(spec)),
            updatedAt: at,
          ),
        );
  }

  Future<bool> remove(String id) async =>
      await (_db.delete(_db.flows)..where((f) => f.id.equals(id))).go() > 0;
}

class DriftZoneStore {
  DriftZoneStore(this._db);

  final OmniDatabase _db;

  Future<List<Map<String, Object?>>> all() async => [
    for (final r in await _db.select(_db.zones).get())
      Map<String, Object?>.from(jsonDecode(r.zoneJson) as Map),
  ];

  Future<void> put(String id, Map<String, Object?> json) => _db
      .into(_db.zones)
      .insertOnConflictUpdate(
        ZonesCompanion.insert(id: id, zoneJson: jsonEncode(json)),
      );

  Future<bool> remove(String id) async =>
      await (_db.delete(_db.zones)..where((z) => z.id.equals(id))).go() > 0;
}

class DriftGlobalStore {
  DriftGlobalStore(this._db);

  final OmniDatabase _db;

  Future<Map<String, Object?>> all() async => {
    for (final r in await _db.select(_db.globalVariables).get())
      r.name: jsonDecode(r.valueJson),
  };

  Future<void> put(String name, Object? value, DateTime at) => _db
      .into(_db.globalVariables)
      .insertOnConflictUpdate(
        GlobalVariablesCompanion.insert(
          name: name,
          valueJson: jsonEncode(value),
          updatedAt: at,
        ),
      );

  Future<bool> remove(String name) async =>
      await (_db.delete(
        _db.globalVariables,
      )..where((g) => g.name.equals(name))).go() >
      0;
}

class ExecutionLogStore {
  ExecutionLogStore(this._db, {this.cap = 1000});

  final OmniDatabase _db;
  final int cap;

  Future<void> add(Map<String, Object?> trace) async {
    await _db
        .into(_db.executionLog)
        .insert(
          ExecutionLogCompanion.insert(
            runId: trace['run'] as String,
            flowId: trace['flow'] as String,
            outcome: trace['outcome'] as String,
            startedAt: DateTime.parse(trace['startedAt'] as String),
            traceJson: jsonEncode(trace),
          ),
        );
    await _db.customStatement(
      'DELETE FROM execution_log WHERE id NOT IN (SELECT id FROM execution_log ORDER BY id DESC LIMIT ?)',
      [cap],
    );
  }

  /// The newest run of each flow, by flow id.
  Future<Map<String, Map<String, Object?>>> lastByFlow() async => {
    for (final row
        in await _db
            .customSelect(
              'SELECT flow_id, trace_json FROM execution_log WHERE id IN '
              '(SELECT MAX(id) FROM execution_log GROUP BY flow_id)',
            )
            .get())
      row.read<String>('flow_id'): Map<String, Object?>.from(
        jsonDecode(row.read<String>('trace_json')) as Map,
      ),
  };

  Future<List<Map<String, Object?>>> recent({
    String? flowId,
    int limit = 20,
  }) async {
    final q = _db.select(_db.executionLog)
      ..orderBy([
        (l) => OrderingTerm(expression: l.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    if (flowId != null) q.where((l) => l.flowId.equals(flowId));
    return [
      for (final r in await q.get())
        Map<String, Object?>.from(jsonDecode(r.traceJson) as Map),
    ];
  }
}

/// The last describe each board gave, by device id.
class DriftBoardDescribeStore {
  DriftBoardDescribeStore(this._db);

  final OmniDatabase _db;

  Future<({Map<String, Object?> describe, DateTime seenAt})?> get(
    String deviceId,
  ) async {
    final r = await (_db.select(
      _db.boardDescribes,
    )..where((b) => b.deviceId.equals(deviceId))).getSingleOrNull();
    return r == null
        ? null
        : (
            describe: Map<String, Object?>.from(
              jsonDecode(r.describeJson) as Map,
            ),
            seenAt: r.seenAt.toUtc(),
          );
  }

  Future<void> put(
    String deviceId,
    Map<String, Object?> describe,
    DateTime at,
  ) => _db
      .into(_db.boardDescribes)
      .insertOnConflictUpdate(
        BoardDescribesCompanion.insert(
          deviceId: deviceId,
          describeJson: jsonEncode(describe),
          seenAt: at,
        ),
      );

  Future<bool> remove(String deviceId) async =>
      await (_db.delete(
        _db.boardDescribes,
      )..where((b) => b.deviceId.equals(deviceId))).go() >
      0;
}

class DriftDeviceStore implements DeviceStore {
  DriftDeviceStore(this._db);

  final OmniDatabase _db;

  @override
  Future<Device?> get(String id) async {
    final row = await (_db.select(
      _db.devices,
    )..where((d) => d.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toDevice(row);
  }

  @override
  Future<List<Device>> all() async {
    final rows = await (_db.select(
      _db.devices,
    )..orderBy([(d) => OrderingTerm(expression: d.id)])).get();
    return rows.map(_toDevice).toList();
  }

  @override
  Future<void> put(Device device) => _db
      .into(_db.devices)
      .insertOnConflictUpdate(
        DevicesCompanion.insert(
          id: device.id,
          name: device.name,
          driverId: device.driverId,
          host: device.host,
          port: Value(device.port),
          room: Value(device.room),
          stableId: Value(device.stableId),
          settingsJson: Value(jsonEncode(device.settings)),
          stateJson: Value(jsonEncode(device.state)),
          lastSeen: Value(device.lastSeen),
          favourite: Value(device.favourite),
          position: Value(device.order),
        ),
      );

  @override
  Future<bool> remove(String id) async =>
      await (_db.delete(_db.devices)..where((d) => d.id.equals(id))).go() > 0;

  Device _toDevice(DeviceRow row) => Device(
    id: row.id,
    name: row.name,
    driverId: row.driverId,
    host: row.host,
    port: row.port,
    room: row.room,
    stableId: row.stableId,
    settings: Map<String, Object?>.from(jsonDecode(row.settingsJson) as Map),
    state: Map<String, Object?>.from(jsonDecode(row.stateJson) as Map),
    lastSeen: row.lastSeen?.toUtc(),
    favourite: row.favourite,
    order: row.position,
  );
}

/// The id a room named [name] is saved under: lower snake case, with a
/// short hash when the name has letters the slug drops, and `_2` and on
/// when [taken] has it.
String uniqueRoomId(String name, Set<String> taken) {
  var slug = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (name.runes.any((r) => r > 0x7f)) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(name.trim())) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    final hash = h.toRadixString(36);
    slug = slug.isEmpty ? hash : '${slug}_$hash';
  }
  if (!RegExp(r'^[a-z]').hasMatch(slug)) slug = 'room_$slug';
  slug = slug.replaceAll(RegExp(r'_+$'), '');
  var id = slug;
  for (var n = 2; taken.contains(id); n++) {
    id = '${slug}_$n';
  }
  return id;
}

class Room {
  const Room({required this.id, required this.name, this.order = 0});

  final String id;
  final String name;
  final int order;
}

class DriftRoomStore {
  DriftRoomStore(this._db);

  final OmniDatabase _db;

  /// Every room, in the user's order, then by name.
  Future<List<Room>> all() async => [
    for (final r
        in await (_db.select(_db.rooms)..orderBy([
              (r) => OrderingTerm(expression: r.position),
              (r) => OrderingTerm(expression: r.name),
            ]))
            .get())
      Room(id: r.id, name: r.name, order: r.position),
  ];

  Future<Room?> get(String id) async {
    final r = await (_db.select(
      _db.rooms,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    return r == null ? null : Room(id: r.id, name: r.name, order: r.position);
  }

  Future<void> put(Room room) => _db
      .into(_db.rooms)
      .insertOnConflictUpdate(
        RoomsCompanion.insert(
          id: room.id,
          name: room.name,
          position: Value(room.order),
        ),
      );

  Future<bool> remove(String id) async =>
      await (_db.delete(_db.rooms)..where((r) => r.id.equals(id))).go() > 0;
}

class HistoryEntry {
  const HistoryEntry(this.at, this.key, this.value, {this.by});

  final DateTime at;
  final String key;
  final Object? value;

  /// The automation that made the change, or `user`.
  final String? by;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'key': key,
    'value': value,
    'by': ?by,
  };
}

/// Each device's state changes, keeping the newest [cap] per device.
class DriftHistoryStore {
  DriftHistoryStore(this._db, {this.cap = 500});

  final OmniDatabase _db;
  final int cap;

  Future<void> add(String deviceId, List<HistoryEntry> entries) async {
    if (entries.isEmpty) return;
    await _db.batch((b) {
      b.insertAll(_db.deviceHistory, [
        for (final e in entries)
          DeviceHistoryCompanion.insert(
            deviceId: deviceId,
            key: e.key,
            valueJson: jsonEncode(e.value),
            at: e.at,
            changedBy: Value(e.by),
          ),
      ]);
    });
    await _db.customStatement(
      'DELETE FROM device_history WHERE device_id = ? AND id NOT IN '
      '(SELECT id FROM device_history WHERE device_id = ? ORDER BY id DESC LIMIT ?)',
      [deviceId, deviceId, cap],
    );
  }

  /// The newest changes of [deviceId] first, of [key] only when given, and
  /// only those after [since].
  Future<List<HistoryEntry>> recent(
    String deviceId, {
    String? key,
    int limit = 100,
    DateTime? since,
  }) async {
    final q = _db.select(_db.deviceHistory)
      ..where((h) {
        var where = h.deviceId.equals(deviceId);
        if (key != null) where &= h.key.equals(key);
        if (since != null) where &= h.at.isBiggerThanValue(since);
        return where;
      })
      ..orderBy([
        (h) => OrderingTerm(expression: h.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return [
      for (final r in await q.get())
        HistoryEntry(
          r.at.toUtc(),
          r.key,
          jsonDecode(r.valueJson),
          by: r.changedBy,
        ),
    ];
  }

  Future<void> removeDevice(String deviceId) => (_db.delete(
    _db.deviceHistory,
  )..where((h) => h.deviceId.equals(deviceId))).go();
}

/// Persists user manifests so the registry can be rebuilt on start.
class DriftManifestStore {
  DriftManifestStore(this._db);

  final OmniDatabase _db;

  Future<List<String>> all() async =>
      (await _db.select(_db.driverManifests).get())
          .map((r) => r.manifestJson)
          .toList();

  Future<void> put(String id, String json, DateTime at) => _db
      .into(_db.driverManifests)
      .insertOnConflictUpdate(
        DriverManifestsCompanion.insert(
          id: id,
          manifestJson: json,
          updatedAt: at,
        ),
      );

  Future<bool> remove(String id) async =>
      await (_db.delete(
        _db.driverManifests,
      )..where((m) => m.id.equals(id))).go() >
      0;
}

class DatabaseInUseException implements Exception {
  DatabaseInUseException(this.path);

  final String path;

  @override
  String toString() =>
      'DatabaseInUseException: $path is open in another omni process (omni hub?)';
}

/// An exclusive lock next to the database, so it is never opened twice.
///
/// The file lock keeps other processes out. File locks are per process, so a
/// set of held paths also refuses a second open inside the same process.
class DatabaseLock {
  DatabaseLock._(this._file, this._path);

  final RandomAccessFile _file;
  final String _path;
  static final _held = <String>{};

  static Future<DatabaseLock> acquire(File database) async {
    final path = database.absolute.path;
    if (!_held.add(path)) throw DatabaseInUseException(database.path);
    final RandomAccessFile file;
    try {
      file = await File('$path.lock').open(mode: FileMode.write);
    } catch (_) {
      _held.remove(path);
      rethrow;
    }
    try {
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      _held.remove(path);
      throw DatabaseInUseException(database.path);
    }
    return DatabaseLock._(file, path);
  }

  Future<void> release() async {
    await _file.unlock();
    await _file.close();
    _held.remove(_path);
  }
}
