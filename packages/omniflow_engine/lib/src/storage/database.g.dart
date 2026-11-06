// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $DriverManifestsTable extends DriverManifests
    with TableInfo<$DriverManifestsTable, ManifestRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DriverManifestsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _manifestJsonMeta = const VerificationMeta(
    'manifestJson',
  );
  @override
  late final GeneratedColumn<String> manifestJson = GeneratedColumn<String>(
    'manifest_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, manifestJson, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'driver_manifests';
  @override
  VerificationContext validateIntegrity(
    Insertable<ManifestRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('manifest_json')) {
      context.handle(
        _manifestJsonMeta,
        manifestJson.isAcceptableOrUnknown(
          data['manifest_json']!,
          _manifestJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_manifestJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ManifestRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ManifestRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      manifestJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}manifest_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DriverManifestsTable createAlias(String alias) {
    return $DriverManifestsTable(attachedDatabase, alias);
  }
}

class ManifestRow extends DataClass implements Insertable<ManifestRow> {
  final String id;
  final String manifestJson;
  final DateTime updatedAt;
  const ManifestRow({
    required this.id,
    required this.manifestJson,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['manifest_json'] = Variable<String>(manifestJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  DriverManifestsCompanion toCompanion(bool nullToAbsent) {
    return DriverManifestsCompanion(
      id: Value(id),
      manifestJson: Value(manifestJson),
      updatedAt: Value(updatedAt),
    );
  }

  factory ManifestRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ManifestRow(
      id: serializer.fromJson<String>(json['id']),
      manifestJson: serializer.fromJson<String>(json['manifestJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'manifestJson': serializer.toJson<String>(manifestJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ManifestRow copyWith({
    String? id,
    String? manifestJson,
    DateTime? updatedAt,
  }) => ManifestRow(
    id: id ?? this.id,
    manifestJson: manifestJson ?? this.manifestJson,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ManifestRow copyWithCompanion(DriverManifestsCompanion data) {
    return ManifestRow(
      id: data.id.present ? data.id.value : this.id,
      manifestJson: data.manifestJson.present
          ? data.manifestJson.value
          : this.manifestJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ManifestRow(')
          ..write('id: $id, ')
          ..write('manifestJson: $manifestJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, manifestJson, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ManifestRow &&
          other.id == this.id &&
          other.manifestJson == this.manifestJson &&
          other.updatedAt == this.updatedAt);
}

class DriverManifestsCompanion extends UpdateCompanion<ManifestRow> {
  final Value<String> id;
  final Value<String> manifestJson;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const DriverManifestsCompanion({
    this.id = const Value.absent(),
    this.manifestJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DriverManifestsCompanion.insert({
    required String id,
    required String manifestJson,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       manifestJson = Value(manifestJson),
       updatedAt = Value(updatedAt);
  static Insertable<ManifestRow> custom({
    Expression<String>? id,
    Expression<String>? manifestJson,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (manifestJson != null) 'manifest_json': manifestJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DriverManifestsCompanion copyWith({
    Value<String>? id,
    Value<String>? manifestJson,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return DriverManifestsCompanion(
      id: id ?? this.id,
      manifestJson: manifestJson ?? this.manifestJson,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (manifestJson.present) {
      map['manifest_json'] = Variable<String>(manifestJson.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DriverManifestsCompanion(')
          ..write('id: $id, ')
          ..write('manifestJson: $manifestJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DevicesTable extends Devices with TableInfo<$DevicesTable, DeviceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DevicesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _driverIdMeta = const VerificationMeta(
    'driverId',
  );
  @override
  late final GeneratedColumn<String> driverId = GeneratedColumn<String>(
    'driver_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
    'host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _roomMeta = const VerificationMeta('room');
  @override
  late final GeneratedColumn<String> room = GeneratedColumn<String>(
    'room',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stableIdMeta = const VerificationMeta(
    'stableId',
  );
  @override
  late final GeneratedColumn<String> stableId = GeneratedColumn<String>(
    'stable_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _settingsJsonMeta = const VerificationMeta(
    'settingsJson',
  );
  @override
  late final GeneratedColumn<String> settingsJson = GeneratedColumn<String>(
    'settings_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _stateJsonMeta = const VerificationMeta(
    'stateJson',
  );
  @override
  late final GeneratedColumn<String> stateJson = GeneratedColumn<String>(
    'state_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _lastSeenMeta = const VerificationMeta(
    'lastSeen',
  );
  @override
  late final GeneratedColumn<DateTime> lastSeen = GeneratedColumn<DateTime>(
    'last_seen',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    driverId,
    host,
    port,
    room,
    stableId,
    settingsJson,
    stateJson,
    lastSeen,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'devices';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeviceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('driver_id')) {
      context.handle(
        _driverIdMeta,
        driverId.isAcceptableOrUnknown(data['driver_id']!, _driverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_driverIdMeta);
    }
    if (data.containsKey('host')) {
      context.handle(
        _hostMeta,
        host.isAcceptableOrUnknown(data['host']!, _hostMeta),
      );
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('room')) {
      context.handle(
        _roomMeta,
        room.isAcceptableOrUnknown(data['room']!, _roomMeta),
      );
    }
    if (data.containsKey('stable_id')) {
      context.handle(
        _stableIdMeta,
        stableId.isAcceptableOrUnknown(data['stable_id']!, _stableIdMeta),
      );
    }
    if (data.containsKey('settings_json')) {
      context.handle(
        _settingsJsonMeta,
        settingsJson.isAcceptableOrUnknown(
          data['settings_json']!,
          _settingsJsonMeta,
        ),
      );
    }
    if (data.containsKey('state_json')) {
      context.handle(
        _stateJsonMeta,
        stateJson.isAcceptableOrUnknown(data['state_json']!, _stateJsonMeta),
      );
    }
    if (data.containsKey('last_seen')) {
      context.handle(
        _lastSeenMeta,
        lastSeen.isAcceptableOrUnknown(data['last_seen']!, _lastSeenMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DeviceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      driverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}driver_id'],
      )!,
      host: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      ),
      room: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room'],
      ),
      stableId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stable_id'],
      ),
      settingsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}settings_json'],
      )!,
      stateJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_json'],
      )!,
      lastSeen: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_seen'],
      ),
    );
  }

  @override
  $DevicesTable createAlias(String alias) {
    return $DevicesTable(attachedDatabase, alias);
  }
}

class DeviceRow extends DataClass implements Insertable<DeviceRow> {
  final String id;
  final String name;
  final String driverId;
  final String host;
  final int? port;
  final String? room;
  final String? stableId;

  /// Non-secret settings as JSON.
  final String settingsJson;
  final String stateJson;
  final DateTime? lastSeen;
  const DeviceRow({
    required this.id,
    required this.name,
    required this.driverId,
    required this.host,
    this.port,
    this.room,
    this.stableId,
    required this.settingsJson,
    required this.stateJson,
    this.lastSeen,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['driver_id'] = Variable<String>(driverId);
    map['host'] = Variable<String>(host);
    if (!nullToAbsent || port != null) {
      map['port'] = Variable<int>(port);
    }
    if (!nullToAbsent || room != null) {
      map['room'] = Variable<String>(room);
    }
    if (!nullToAbsent || stableId != null) {
      map['stable_id'] = Variable<String>(stableId);
    }
    map['settings_json'] = Variable<String>(settingsJson);
    map['state_json'] = Variable<String>(stateJson);
    if (!nullToAbsent || lastSeen != null) {
      map['last_seen'] = Variable<DateTime>(lastSeen);
    }
    return map;
  }

  DevicesCompanion toCompanion(bool nullToAbsent) {
    return DevicesCompanion(
      id: Value(id),
      name: Value(name),
      driverId: Value(driverId),
      host: Value(host),
      port: port == null && nullToAbsent ? const Value.absent() : Value(port),
      room: room == null && nullToAbsent ? const Value.absent() : Value(room),
      stableId: stableId == null && nullToAbsent
          ? const Value.absent()
          : Value(stableId),
      settingsJson: Value(settingsJson),
      stateJson: Value(stateJson),
      lastSeen: lastSeen == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSeen),
    );
  }

  factory DeviceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      driverId: serializer.fromJson<String>(json['driverId']),
      host: serializer.fromJson<String>(json['host']),
      port: serializer.fromJson<int?>(json['port']),
      room: serializer.fromJson<String?>(json['room']),
      stableId: serializer.fromJson<String?>(json['stableId']),
      settingsJson: serializer.fromJson<String>(json['settingsJson']),
      stateJson: serializer.fromJson<String>(json['stateJson']),
      lastSeen: serializer.fromJson<DateTime?>(json['lastSeen']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'driverId': serializer.toJson<String>(driverId),
      'host': serializer.toJson<String>(host),
      'port': serializer.toJson<int?>(port),
      'room': serializer.toJson<String?>(room),
      'stableId': serializer.toJson<String?>(stableId),
      'settingsJson': serializer.toJson<String>(settingsJson),
      'stateJson': serializer.toJson<String>(stateJson),
      'lastSeen': serializer.toJson<DateTime?>(lastSeen),
    };
  }

  DeviceRow copyWith({
    String? id,
    String? name,
    String? driverId,
    String? host,
    Value<int?> port = const Value.absent(),
    Value<String?> room = const Value.absent(),
    Value<String?> stableId = const Value.absent(),
    String? settingsJson,
    String? stateJson,
    Value<DateTime?> lastSeen = const Value.absent(),
  }) => DeviceRow(
    id: id ?? this.id,
    name: name ?? this.name,
    driverId: driverId ?? this.driverId,
    host: host ?? this.host,
    port: port.present ? port.value : this.port,
    room: room.present ? room.value : this.room,
    stableId: stableId.present ? stableId.value : this.stableId,
    settingsJson: settingsJson ?? this.settingsJson,
    stateJson: stateJson ?? this.stateJson,
    lastSeen: lastSeen.present ? lastSeen.value : this.lastSeen,
  );
  DeviceRow copyWithCompanion(DevicesCompanion data) {
    return DeviceRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      driverId: data.driverId.present ? data.driverId.value : this.driverId,
      host: data.host.present ? data.host.value : this.host,
      port: data.port.present ? data.port.value : this.port,
      room: data.room.present ? data.room.value : this.room,
      stableId: data.stableId.present ? data.stableId.value : this.stableId,
      settingsJson: data.settingsJson.present
          ? data.settingsJson.value
          : this.settingsJson,
      stateJson: data.stateJson.present ? data.stateJson.value : this.stateJson,
      lastSeen: data.lastSeen.present ? data.lastSeen.value : this.lastSeen,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('driverId: $driverId, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('room: $room, ')
          ..write('stableId: $stableId, ')
          ..write('settingsJson: $settingsJson, ')
          ..write('stateJson: $stateJson, ')
          ..write('lastSeen: $lastSeen')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    driverId,
    host,
    port,
    room,
    stableId,
    settingsJson,
    stateJson,
    lastSeen,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.driverId == this.driverId &&
          other.host == this.host &&
          other.port == this.port &&
          other.room == this.room &&
          other.stableId == this.stableId &&
          other.settingsJson == this.settingsJson &&
          other.stateJson == this.stateJson &&
          other.lastSeen == this.lastSeen);
}

class DevicesCompanion extends UpdateCompanion<DeviceRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> driverId;
  final Value<String> host;
  final Value<int?> port;
  final Value<String?> room;
  final Value<String?> stableId;
  final Value<String> settingsJson;
  final Value<String> stateJson;
  final Value<DateTime?> lastSeen;
  final Value<int> rowid;
  const DevicesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.driverId = const Value.absent(),
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.room = const Value.absent(),
    this.stableId = const Value.absent(),
    this.settingsJson = const Value.absent(),
    this.stateJson = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DevicesCompanion.insert({
    required String id,
    required String name,
    required String driverId,
    required String host,
    this.port = const Value.absent(),
    this.room = const Value.absent(),
    this.stableId = const Value.absent(),
    this.settingsJson = const Value.absent(),
    this.stateJson = const Value.absent(),
    this.lastSeen = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       driverId = Value(driverId),
       host = Value(host);
  static Insertable<DeviceRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? driverId,
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? room,
    Expression<String>? stableId,
    Expression<String>? settingsJson,
    Expression<String>? stateJson,
    Expression<DateTime>? lastSeen,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (driverId != null) 'driver_id': driverId,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (room != null) 'room': room,
      if (stableId != null) 'stable_id': stableId,
      if (settingsJson != null) 'settings_json': settingsJson,
      if (stateJson != null) 'state_json': stateJson,
      if (lastSeen != null) 'last_seen': lastSeen,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DevicesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? driverId,
    Value<String>? host,
    Value<int?>? port,
    Value<String?>? room,
    Value<String?>? stableId,
    Value<String>? settingsJson,
    Value<String>? stateJson,
    Value<DateTime?>? lastSeen,
    Value<int>? rowid,
  }) {
    return DevicesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      driverId: driverId ?? this.driverId,
      host: host ?? this.host,
      port: port ?? this.port,
      room: room ?? this.room,
      stableId: stableId ?? this.stableId,
      settingsJson: settingsJson ?? this.settingsJson,
      stateJson: stateJson ?? this.stateJson,
      lastSeen: lastSeen ?? this.lastSeen,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (driverId.present) {
      map['driver_id'] = Variable<String>(driverId.value);
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (room.present) {
      map['room'] = Variable<String>(room.value);
    }
    if (stableId.present) {
      map['stable_id'] = Variable<String>(stableId.value);
    }
    if (settingsJson.present) {
      map['settings_json'] = Variable<String>(settingsJson.value);
    }
    if (stateJson.present) {
      map['state_json'] = Variable<String>(stateJson.value);
    }
    if (lastSeen.present) {
      map['last_seen'] = Variable<DateTime>(lastSeen.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DevicesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('driverId: $driverId, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('room: $room, ')
          ..write('stableId: $stableId, ')
          ..write('settingsJson: $settingsJson, ')
          ..write('stateJson: $stateJson, ')
          ..write('lastSeen: $lastSeen, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$OmniDatabase extends GeneratedDatabase {
  _$OmniDatabase(QueryExecutor e) : super(e);
  $OmniDatabaseManager get managers => $OmniDatabaseManager(this);
  late final $DriverManifestsTable driverManifests = $DriverManifestsTable(
    this,
  );
  late final $DevicesTable devices = $DevicesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    driverManifests,
    devices,
  ];
}

typedef $$DriverManifestsTableCreateCompanionBuilder =
    DriverManifestsCompanion Function({
      required String id,
      required String manifestJson,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$DriverManifestsTableUpdateCompanionBuilder =
    DriverManifestsCompanion Function({
      Value<String> id,
      Value<String> manifestJson,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$DriverManifestsTableFilterComposer
    extends Composer<_$OmniDatabase, $DriverManifestsTable> {
  $$DriverManifestsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DriverManifestsTableOrderingComposer
    extends Composer<_$OmniDatabase, $DriverManifestsTable> {
  $$DriverManifestsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DriverManifestsTableAnnotationComposer
    extends Composer<_$OmniDatabase, $DriverManifestsTable> {
  $$DriverManifestsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get manifestJson => $composableBuilder(
    column: $table.manifestJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DriverManifestsTableTableManager
    extends
        RootTableManager<
          _$OmniDatabase,
          $DriverManifestsTable,
          ManifestRow,
          $$DriverManifestsTableFilterComposer,
          $$DriverManifestsTableOrderingComposer,
          $$DriverManifestsTableAnnotationComposer,
          $$DriverManifestsTableCreateCompanionBuilder,
          $$DriverManifestsTableUpdateCompanionBuilder,
          (
            ManifestRow,
            BaseReferences<_$OmniDatabase, $DriverManifestsTable, ManifestRow>,
          ),
          ManifestRow,
          PrefetchHooks Function()
        > {
  $$DriverManifestsTableTableManager(
    _$OmniDatabase db,
    $DriverManifestsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DriverManifestsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DriverManifestsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DriverManifestsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> manifestJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DriverManifestsCompanion(
                id: id,
                manifestJson: manifestJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String manifestJson,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => DriverManifestsCompanion.insert(
                id: id,
                manifestJson: manifestJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DriverManifestsTable, ManifestRow>(table),
                  BaseReferences<
                    _$OmniDatabase,
                    $DriverManifestsTable,
                    ManifestRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DriverManifestsTableProcessedTableManager =
    ProcessedTableManager<
      _$OmniDatabase,
      $DriverManifestsTable,
      ManifestRow,
      $$DriverManifestsTableFilterComposer,
      $$DriverManifestsTableOrderingComposer,
      $$DriverManifestsTableAnnotationComposer,
      $$DriverManifestsTableCreateCompanionBuilder,
      $$DriverManifestsTableUpdateCompanionBuilder,
      (
        ManifestRow,
        BaseReferences<_$OmniDatabase, $DriverManifestsTable, ManifestRow>,
      ),
      ManifestRow,
      PrefetchHooks Function()
    >;
typedef $$DevicesTableCreateCompanionBuilder = DevicesCompanion Function({
  required String id,
  required String name,
  required String driverId,
  required String host,
  Value<int?> port,
  Value<String?> room,
  Value<String?> stableId,
  Value<String> settingsJson,
  Value<String> stateJson,
  Value<DateTime?> lastSeen,
  Value<int> rowid,
});
typedef $$DevicesTableUpdateCompanionBuilder = DevicesCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> driverId,
  Value<String> host,
  Value<int?> port,
  Value<String?> room,
  Value<String?> stableId,
  Value<String> settingsJson,
  Value<String> stateJson,
  Value<DateTime?> lastSeen,
  Value<int> rowid,
});

class $$DevicesTableFilterComposer
    extends Composer<_$OmniDatabase, $DevicesTable> {
  $$DevicesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get driverId => $composableBuilder(
    column: $table.driverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get room => $composableBuilder(
    column: $table.room,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stableId => $composableBuilder(
    column: $table.stableId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get settingsJson => $composableBuilder(
    column: $table.settingsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stateJson => $composableBuilder(
    column: $table.stateJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DevicesTableOrderingComposer
    extends Composer<_$OmniDatabase, $DevicesTable> {
  $$DevicesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get driverId => $composableBuilder(
    column: $table.driverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get room => $composableBuilder(
    column: $table.room,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stableId => $composableBuilder(
    column: $table.stableId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get settingsJson => $composableBuilder(
    column: $table.settingsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stateJson => $composableBuilder(
    column: $table.stateJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSeen => $composableBuilder(
    column: $table.lastSeen,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DevicesTableAnnotationComposer
    extends Composer<_$OmniDatabase, $DevicesTable> {
  $$DevicesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get driverId =>
      $composableBuilder(column: $table.driverId, builder: (column) => column);

  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get room =>
      $composableBuilder(column: $table.room, builder: (column) => column);

  GeneratedColumn<String> get stableId =>
      $composableBuilder(column: $table.stableId, builder: (column) => column);

  GeneratedColumn<String> get settingsJson => $composableBuilder(
    column: $table.settingsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stateJson =>
      $composableBuilder(column: $table.stateJson, builder: (column) => column);

  GeneratedColumn<DateTime> get lastSeen =>
      $composableBuilder(column: $table.lastSeen, builder: (column) => column);
}

class $$DevicesTableTableManager
    extends
        RootTableManager<
          _$OmniDatabase,
          $DevicesTable,
          DeviceRow,
          $$DevicesTableFilterComposer,
          $$DevicesTableOrderingComposer,
          $$DevicesTableAnnotationComposer,
          $$DevicesTableCreateCompanionBuilder,
          $$DevicesTableUpdateCompanionBuilder,
          (DeviceRow, BaseReferences<_$OmniDatabase, $DevicesTable, DeviceRow>),
          DeviceRow,
          PrefetchHooks Function()
        > {
  $$DevicesTableTableManager(_$OmniDatabase db, $DevicesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DevicesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DevicesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DevicesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> driverId = const Value.absent(),
                Value<String> host = const Value.absent(),
                Value<int?> port = const Value.absent(),
                Value<String?> room = const Value.absent(),
                Value<String?> stableId = const Value.absent(),
                Value<String> settingsJson = const Value.absent(),
                Value<String> stateJson = const Value.absent(),
                Value<DateTime?> lastSeen = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DevicesCompanion(
                id: id,
                name: name,
                driverId: driverId,
                host: host,
                port: port,
                room: room,
                stableId: stableId,
                settingsJson: settingsJson,
                stateJson: stateJson,
                lastSeen: lastSeen,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String driverId,
                required String host,
                Value<int?> port = const Value.absent(),
                Value<String?> room = const Value.absent(),
                Value<String?> stableId = const Value.absent(),
                Value<String> settingsJson = const Value.absent(),
                Value<String> stateJson = const Value.absent(),
                Value<DateTime?> lastSeen = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DevicesCompanion.insert(
                id: id,
                name: name,
                driverId: driverId,
                host: host,
                port: port,
                room: room,
                stableId: stableId,
                settingsJson: settingsJson,
                stateJson: stateJson,
                lastSeen: lastSeen,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DevicesTable, DeviceRow>(table),
                  BaseReferences<_$OmniDatabase, $DevicesTable, DeviceRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DevicesTableProcessedTableManager =
    ProcessedTableManager<
      _$OmniDatabase,
      $DevicesTable,
      DeviceRow,
      $$DevicesTableFilterComposer,
      $$DevicesTableOrderingComposer,
      $$DevicesTableAnnotationComposer,
      $$DevicesTableCreateCompanionBuilder,
      $$DevicesTableUpdateCompanionBuilder,
      (DeviceRow, BaseReferences<_$OmniDatabase, $DevicesTable, DeviceRow>),
      DeviceRow,
      PrefetchHooks Function()
    >;

class $OmniDatabaseManager {
  final _$OmniDatabase _db;
  $OmniDatabaseManager(this._db);
  $$DriverManifestsTableTableManager get driverManifests =>
      $$DriverManifestsTableTableManager(_db, _db.driverManifests);
  $$DevicesTableTableManager get devices =>
      $$DevicesTableTableManager(_db, _db.devices);
}
