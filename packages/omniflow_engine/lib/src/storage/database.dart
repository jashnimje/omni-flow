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

  @override
  Set<Column> get primaryKey => {id};
}

/// The engine's SQLite database. Schema changes bump [schemaVersion] and add
/// a step to [migration].
@DriftDatabase(tables: [DriverManifests, Devices])
class OmniDatabase extends _$OmniDatabase {
  OmniDatabase(super.executor);

  /// Opens (or creates) the database file at [file] on a background isolate.
  factory OmniDatabase.file(File file) =>
      OmniDatabase(NativeDatabase.createInBackground(file));

  factory OmniDatabase.memory() => OmniDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
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
  );
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

/// An exclusive lock next to the database, so two processes never open it.
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
