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

class $FlowsTable extends Flows with TableInfo<$FlowsTable, FlowRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FlowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _flowJsonMeta = const VerificationMeta(
    'flowJson',
  );
  @override
  late final GeneratedColumn<String> flowJson = GeneratedColumn<String>(
    'flow_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _approvedMeta = const VerificationMeta(
    'approved',
  );
  @override
  late final GeneratedColumn<bool> approved = GeneratedColumn<bool>(
    'approved',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("approved" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _trustedMeta = const VerificationMeta(
    'trusted',
  );
  @override
  late final GeneratedColumn<bool> trusted = GeneratedColumn<bool>(
    'trusted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("trusted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(FlowRecord.graph),
  );
  static const VerificationMeta _specJsonMeta = const VerificationMeta(
    'specJson',
  );
  @override
  late final GeneratedColumn<String> specJson = GeneratedColumn<String>(
    'spec_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
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
  List<GeneratedColumn> get $columns => [
    id,
    flowJson,
    enabled,
    approved,
    trusted,
    source,
    specJson,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'flows';
  @override
  VerificationContext validateIntegrity(
    Insertable<FlowRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('flow_json')) {
      context.handle(
        _flowJsonMeta,
        flowJson.isAcceptableOrUnknown(data['flow_json']!, _flowJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_flowJsonMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('approved')) {
      context.handle(
        _approvedMeta,
        approved.isAcceptableOrUnknown(data['approved']!, _approvedMeta),
      );
    }
    if (data.containsKey('trusted')) {
      context.handle(
        _trustedMeta,
        trusted.isAcceptableOrUnknown(data['trusted']!, _trustedMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('spec_json')) {
      context.handle(
        _specJsonMeta,
        specJson.isAcceptableOrUnknown(data['spec_json']!, _specJsonMeta),
      );
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
  FlowRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FlowRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      flowJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}flow_json'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      approved: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}approved'],
      )!,
      trusted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}trusted'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      specJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}spec_json'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $FlowsTable createAlias(String alias) {
    return $FlowsTable(attachedDatabase, alias);
  }
}

class FlowRow extends DataClass implements Insertable<FlowRow> {
  final String id;
  final String flowJson;
  final bool enabled;

  /// False while a flow from MCP, the AI architect or an import waits for
  /// the user to approve its high-risk parts.
  final bool approved;

  /// True when the user saved or approved this version of the flow, so a
  /// later rise in its risk does not revoke the approval.
  final bool trusted;

  /// The form the automation was written in: `link`, `rule` or `graph`,
  /// so each surface reopens it as it was written.
  final String source;

  /// The link or rule the flow was compiled from. Null for a graph, which
  /// is its own spec.
  final String? specJson;
  final DateTime updatedAt;
  const FlowRow({
    required this.id,
    required this.flowJson,
    required this.enabled,
    required this.approved,
    required this.trusted,
    required this.source,
    this.specJson,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['flow_json'] = Variable<String>(flowJson);
    map['enabled'] = Variable<bool>(enabled);
    map['approved'] = Variable<bool>(approved);
    map['trusted'] = Variable<bool>(trusted);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || specJson != null) {
      map['spec_json'] = Variable<String>(specJson);
    }
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  FlowsCompanion toCompanion(bool nullToAbsent) {
    return FlowsCompanion(
      id: Value(id),
      flowJson: Value(flowJson),
      enabled: Value(enabled),
      approved: Value(approved),
      trusted: Value(trusted),
      source: Value(source),
      specJson: specJson == null && nullToAbsent
          ? const Value.absent()
          : Value(specJson),
      updatedAt: Value(updatedAt),
    );
  }

  factory FlowRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FlowRow(
      id: serializer.fromJson<String>(json['id']),
      flowJson: serializer.fromJson<String>(json['flowJson']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      approved: serializer.fromJson<bool>(json['approved']),
      trusted: serializer.fromJson<bool>(json['trusted']),
      source: serializer.fromJson<String>(json['source']),
      specJson: serializer.fromJson<String?>(json['specJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'flowJson': serializer.toJson<String>(flowJson),
      'enabled': serializer.toJson<bool>(enabled),
      'approved': serializer.toJson<bool>(approved),
      'trusted': serializer.toJson<bool>(trusted),
      'source': serializer.toJson<String>(source),
      'specJson': serializer.toJson<String?>(specJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  FlowRow copyWith({
    String? id,
    String? flowJson,
    bool? enabled,
    bool? approved,
    bool? trusted,
    String? source,
    Value<String?> specJson = const Value.absent(),
    DateTime? updatedAt,
  }) => FlowRow(
    id: id ?? this.id,
    flowJson: flowJson ?? this.flowJson,
    enabled: enabled ?? this.enabled,
    approved: approved ?? this.approved,
    trusted: trusted ?? this.trusted,
    source: source ?? this.source,
    specJson: specJson.present ? specJson.value : this.specJson,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  FlowRow copyWithCompanion(FlowsCompanion data) {
    return FlowRow(
      id: data.id.present ? data.id.value : this.id,
      flowJson: data.flowJson.present ? data.flowJson.value : this.flowJson,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      approved: data.approved.present ? data.approved.value : this.approved,
      trusted: data.trusted.present ? data.trusted.value : this.trusted,
      source: data.source.present ? data.source.value : this.source,
      specJson: data.specJson.present ? data.specJson.value : this.specJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FlowRow(')
          ..write('id: $id, ')
          ..write('flowJson: $flowJson, ')
          ..write('enabled: $enabled, ')
          ..write('approved: $approved, ')
          ..write('trusted: $trusted, ')
          ..write('source: $source, ')
          ..write('specJson: $specJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    flowJson,
    enabled,
    approved,
    trusted,
    source,
    specJson,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FlowRow &&
          other.id == this.id &&
          other.flowJson == this.flowJson &&
          other.enabled == this.enabled &&
          other.approved == this.approved &&
          other.trusted == this.trusted &&
          other.source == this.source &&
          other.specJson == this.specJson &&
          other.updatedAt == this.updatedAt);
}

class FlowsCompanion extends UpdateCompanion<FlowRow> {
  final Value<String> id;
  final Value<String> flowJson;
  final Value<bool> enabled;
  final Value<bool> approved;
  final Value<bool> trusted;
  final Value<String> source;
  final Value<String?> specJson;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const FlowsCompanion({
    this.id = const Value.absent(),
    this.flowJson = const Value.absent(),
    this.enabled = const Value.absent(),
    this.approved = const Value.absent(),
    this.trusted = const Value.absent(),
    this.source = const Value.absent(),
    this.specJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FlowsCompanion.insert({
    required String id,
    required String flowJson,
    this.enabled = const Value.absent(),
    this.approved = const Value.absent(),
    this.trusted = const Value.absent(),
    this.source = const Value.absent(),
    this.specJson = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       flowJson = Value(flowJson),
       updatedAt = Value(updatedAt);
  static Insertable<FlowRow> custom({
    Expression<String>? id,
    Expression<String>? flowJson,
    Expression<bool>? enabled,
    Expression<bool>? approved,
    Expression<bool>? trusted,
    Expression<String>? source,
    Expression<String>? specJson,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (flowJson != null) 'flow_json': flowJson,
      if (enabled != null) 'enabled': enabled,
      if (approved != null) 'approved': approved,
      if (trusted != null) 'trusted': trusted,
      if (source != null) 'source': source,
      if (specJson != null) 'spec_json': specJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FlowsCompanion copyWith({
    Value<String>? id,
    Value<String>? flowJson,
    Value<bool>? enabled,
    Value<bool>? approved,
    Value<bool>? trusted,
    Value<String>? source,
    Value<String?>? specJson,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return FlowsCompanion(
      id: id ?? this.id,
      flowJson: flowJson ?? this.flowJson,
      enabled: enabled ?? this.enabled,
      approved: approved ?? this.approved,
      trusted: trusted ?? this.trusted,
      source: source ?? this.source,
      specJson: specJson ?? this.specJson,
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
    if (flowJson.present) {
      map['flow_json'] = Variable<String>(flowJson.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (approved.present) {
      map['approved'] = Variable<bool>(approved.value);
    }
    if (trusted.present) {
      map['trusted'] = Variable<bool>(trusted.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (specJson.present) {
      map['spec_json'] = Variable<String>(specJson.value);
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
    return (StringBuffer('FlowsCompanion(')
          ..write('id: $id, ')
          ..write('flowJson: $flowJson, ')
          ..write('enabled: $enabled, ')
          ..write('approved: $approved, ')
          ..write('trusted: $trusted, ')
          ..write('source: $source, ')
          ..write('specJson: $specJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ZonesTable extends Zones with TableInfo<$ZonesTable, ZoneRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ZonesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _zoneJsonMeta = const VerificationMeta(
    'zoneJson',
  );
  @override
  late final GeneratedColumn<String> zoneJson = GeneratedColumn<String>(
    'zone_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, zoneJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'zones';
  @override
  VerificationContext validateIntegrity(
    Insertable<ZoneRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('zone_json')) {
      context.handle(
        _zoneJsonMeta,
        zoneJson.isAcceptableOrUnknown(data['zone_json']!, _zoneJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_zoneJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ZoneRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ZoneRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      zoneJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}zone_json'],
      )!,
    );
  }

  @override
  $ZonesTable createAlias(String alias) {
    return $ZonesTable(attachedDatabase, alias);
  }
}

class ZoneRow extends DataClass implements Insertable<ZoneRow> {
  final String id;
  final String zoneJson;
  const ZoneRow({required this.id, required this.zoneJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['zone_json'] = Variable<String>(zoneJson);
    return map;
  }

  ZonesCompanion toCompanion(bool nullToAbsent) {
    return ZonesCompanion(id: Value(id), zoneJson: Value(zoneJson));
  }

  factory ZoneRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ZoneRow(
      id: serializer.fromJson<String>(json['id']),
      zoneJson: serializer.fromJson<String>(json['zoneJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'zoneJson': serializer.toJson<String>(zoneJson),
    };
  }

  ZoneRow copyWith({String? id, String? zoneJson}) =>
      ZoneRow(id: id ?? this.id, zoneJson: zoneJson ?? this.zoneJson);
  ZoneRow copyWithCompanion(ZonesCompanion data) {
    return ZoneRow(
      id: data.id.present ? data.id.value : this.id,
      zoneJson: data.zoneJson.present ? data.zoneJson.value : this.zoneJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ZoneRow(')
          ..write('id: $id, ')
          ..write('zoneJson: $zoneJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, zoneJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ZoneRow &&
          other.id == this.id &&
          other.zoneJson == this.zoneJson);
}

class ZonesCompanion extends UpdateCompanion<ZoneRow> {
  final Value<String> id;
  final Value<String> zoneJson;
  final Value<int> rowid;
  const ZonesCompanion({
    this.id = const Value.absent(),
    this.zoneJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ZonesCompanion.insert({
    required String id,
    required String zoneJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       zoneJson = Value(zoneJson);
  static Insertable<ZoneRow> custom({
    Expression<String>? id,
    Expression<String>? zoneJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (zoneJson != null) 'zone_json': zoneJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ZonesCompanion copyWith({
    Value<String>? id,
    Value<String>? zoneJson,
    Value<int>? rowid,
  }) {
    return ZonesCompanion(
      id: id ?? this.id,
      zoneJson: zoneJson ?? this.zoneJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (zoneJson.present) {
      map['zone_json'] = Variable<String>(zoneJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ZonesCompanion(')
          ..write('id: $id, ')
          ..write('zoneJson: $zoneJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GlobalVariablesTable extends GlobalVariables
    with TableInfo<$GlobalVariablesTable, GlobalRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GlobalVariablesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueJsonMeta = const VerificationMeta(
    'valueJson',
  );
  @override
  late final GeneratedColumn<String> valueJson = GeneratedColumn<String>(
    'value_json',
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
  List<GeneratedColumn> get $columns => [name, valueJson, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'global_variables';
  @override
  VerificationContext validateIntegrity(
    Insertable<GlobalRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('value_json')) {
      context.handle(
        _valueJsonMeta,
        valueJson.isAcceptableOrUnknown(data['value_json']!, _valueJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_valueJsonMeta);
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
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  GlobalRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GlobalRow(
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      valueJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $GlobalVariablesTable createAlias(String alias) {
    return $GlobalVariablesTable(attachedDatabase, alias);
  }
}

class GlobalRow extends DataClass implements Insertable<GlobalRow> {
  final String name;
  final String valueJson;
  final DateTime updatedAt;
  const GlobalRow({
    required this.name,
    required this.valueJson,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    map['value_json'] = Variable<String>(valueJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  GlobalVariablesCompanion toCompanion(bool nullToAbsent) {
    return GlobalVariablesCompanion(
      name: Value(name),
      valueJson: Value(valueJson),
      updatedAt: Value(updatedAt),
    );
  }

  factory GlobalRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GlobalRow(
      name: serializer.fromJson<String>(json['name']),
      valueJson: serializer.fromJson<String>(json['valueJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'valueJson': serializer.toJson<String>(valueJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  GlobalRow copyWith({String? name, String? valueJson, DateTime? updatedAt}) =>
      GlobalRow(
        name: name ?? this.name,
        valueJson: valueJson ?? this.valueJson,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  GlobalRow copyWithCompanion(GlobalVariablesCompanion data) {
    return GlobalRow(
      name: data.name.present ? data.name.value : this.name,
      valueJson: data.valueJson.present ? data.valueJson.value : this.valueJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GlobalRow(')
          ..write('name: $name, ')
          ..write('valueJson: $valueJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, valueJson, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GlobalRow &&
          other.name == this.name &&
          other.valueJson == this.valueJson &&
          other.updatedAt == this.updatedAt);
}

class GlobalVariablesCompanion extends UpdateCompanion<GlobalRow> {
  final Value<String> name;
  final Value<String> valueJson;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const GlobalVariablesCompanion({
    this.name = const Value.absent(),
    this.valueJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GlobalVariablesCompanion.insert({
    required String name,
    required String valueJson,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : name = Value(name),
       valueJson = Value(valueJson),
       updatedAt = Value(updatedAt);
  static Insertable<GlobalRow> custom({
    Expression<String>? name,
    Expression<String>? valueJson,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (valueJson != null) 'value_json': valueJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GlobalVariablesCompanion copyWith({
    Value<String>? name,
    Value<String>? valueJson,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return GlobalVariablesCompanion(
      name: name ?? this.name,
      valueJson: valueJson ?? this.valueJson,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (valueJson.present) {
      map['value_json'] = Variable<String>(valueJson.value);
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
    return (StringBuffer('GlobalVariablesCompanion(')
          ..write('name: $name, ')
          ..write('valueJson: $valueJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ExecutionLogTable extends ExecutionLog
    with TableInfo<$ExecutionLogTable, LogRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ExecutionLogTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _runIdMeta = const VerificationMeta('runId');
  @override
  late final GeneratedColumn<String> runId = GeneratedColumn<String>(
    'run_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _flowIdMeta = const VerificationMeta('flowId');
  @override
  late final GeneratedColumn<String> flowId = GeneratedColumn<String>(
    'flow_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _outcomeMeta = const VerificationMeta(
    'outcome',
  );
  @override
  late final GeneratedColumn<String> outcome = GeneratedColumn<String>(
    'outcome',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _traceJsonMeta = const VerificationMeta(
    'traceJson',
  );
  @override
  late final GeneratedColumn<String> traceJson = GeneratedColumn<String>(
    'trace_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    runId,
    flowId,
    outcome,
    startedAt,
    traceJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'execution_log';
  @override
  VerificationContext validateIntegrity(
    Insertable<LogRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('run_id')) {
      context.handle(
        _runIdMeta,
        runId.isAcceptableOrUnknown(data['run_id']!, _runIdMeta),
      );
    } else if (isInserting) {
      context.missing(_runIdMeta);
    }
    if (data.containsKey('flow_id')) {
      context.handle(
        _flowIdMeta,
        flowId.isAcceptableOrUnknown(data['flow_id']!, _flowIdMeta),
      );
    } else if (isInserting) {
      context.missing(_flowIdMeta);
    }
    if (data.containsKey('outcome')) {
      context.handle(
        _outcomeMeta,
        outcome.isAcceptableOrUnknown(data['outcome']!, _outcomeMeta),
      );
    } else if (isInserting) {
      context.missing(_outcomeMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('trace_json')) {
      context.handle(
        _traceJsonMeta,
        traceJson.isAcceptableOrUnknown(data['trace_json']!, _traceJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_traceJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LogRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LogRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      runId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}run_id'],
      )!,
      flowId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}flow_id'],
      )!,
      outcome: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outcome'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}started_at'],
      )!,
      traceJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}trace_json'],
      )!,
    );
  }

  @override
  $ExecutionLogTable createAlias(String alias) {
    return $ExecutionLogTable(attachedDatabase, alias);
  }
}

class LogRow extends DataClass implements Insertable<LogRow> {
  final int id;
  final String runId;
  final String flowId;
  final String outcome;
  final DateTime startedAt;
  final String traceJson;
  const LogRow({
    required this.id,
    required this.runId,
    required this.flowId,
    required this.outcome,
    required this.startedAt,
    required this.traceJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['run_id'] = Variable<String>(runId);
    map['flow_id'] = Variable<String>(flowId);
    map['outcome'] = Variable<String>(outcome);
    map['started_at'] = Variable<DateTime>(startedAt);
    map['trace_json'] = Variable<String>(traceJson);
    return map;
  }

  ExecutionLogCompanion toCompanion(bool nullToAbsent) {
    return ExecutionLogCompanion(
      id: Value(id),
      runId: Value(runId),
      flowId: Value(flowId),
      outcome: Value(outcome),
      startedAt: Value(startedAt),
      traceJson: Value(traceJson),
    );
  }

  factory LogRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LogRow(
      id: serializer.fromJson<int>(json['id']),
      runId: serializer.fromJson<String>(json['runId']),
      flowId: serializer.fromJson<String>(json['flowId']),
      outcome: serializer.fromJson<String>(json['outcome']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      traceJson: serializer.fromJson<String>(json['traceJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'runId': serializer.toJson<String>(runId),
      'flowId': serializer.toJson<String>(flowId),
      'outcome': serializer.toJson<String>(outcome),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'traceJson': serializer.toJson<String>(traceJson),
    };
  }

  LogRow copyWith({
    int? id,
    String? runId,
    String? flowId,
    String? outcome,
    DateTime? startedAt,
    String? traceJson,
  }) => LogRow(
    id: id ?? this.id,
    runId: runId ?? this.runId,
    flowId: flowId ?? this.flowId,
    outcome: outcome ?? this.outcome,
    startedAt: startedAt ?? this.startedAt,
    traceJson: traceJson ?? this.traceJson,
  );
  LogRow copyWithCompanion(ExecutionLogCompanion data) {
    return LogRow(
      id: data.id.present ? data.id.value : this.id,
      runId: data.runId.present ? data.runId.value : this.runId,
      flowId: data.flowId.present ? data.flowId.value : this.flowId,
      outcome: data.outcome.present ? data.outcome.value : this.outcome,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      traceJson: data.traceJson.present ? data.traceJson.value : this.traceJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LogRow(')
          ..write('id: $id, ')
          ..write('runId: $runId, ')
          ..write('flowId: $flowId, ')
          ..write('outcome: $outcome, ')
          ..write('startedAt: $startedAt, ')
          ..write('traceJson: $traceJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, runId, flowId, outcome, startedAt, traceJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LogRow &&
          other.id == this.id &&
          other.runId == this.runId &&
          other.flowId == this.flowId &&
          other.outcome == this.outcome &&
          other.startedAt == this.startedAt &&
          other.traceJson == this.traceJson);
}

class ExecutionLogCompanion extends UpdateCompanion<LogRow> {
  final Value<int> id;
  final Value<String> runId;
  final Value<String> flowId;
  final Value<String> outcome;
  final Value<DateTime> startedAt;
  final Value<String> traceJson;
  const ExecutionLogCompanion({
    this.id = const Value.absent(),
    this.runId = const Value.absent(),
    this.flowId = const Value.absent(),
    this.outcome = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.traceJson = const Value.absent(),
  });
  ExecutionLogCompanion.insert({
    this.id = const Value.absent(),
    required String runId,
    required String flowId,
    required String outcome,
    required DateTime startedAt,
    required String traceJson,
  }) : runId = Value(runId),
       flowId = Value(flowId),
       outcome = Value(outcome),
       startedAt = Value(startedAt),
       traceJson = Value(traceJson);
  static Insertable<LogRow> custom({
    Expression<int>? id,
    Expression<String>? runId,
    Expression<String>? flowId,
    Expression<String>? outcome,
    Expression<DateTime>? startedAt,
    Expression<String>? traceJson,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (runId != null) 'run_id': runId,
      if (flowId != null) 'flow_id': flowId,
      if (outcome != null) 'outcome': outcome,
      if (startedAt != null) 'started_at': startedAt,
      if (traceJson != null) 'trace_json': traceJson,
    });
  }

  ExecutionLogCompanion copyWith({
    Value<int>? id,
    Value<String>? runId,
    Value<String>? flowId,
    Value<String>? outcome,
    Value<DateTime>? startedAt,
    Value<String>? traceJson,
  }) {
    return ExecutionLogCompanion(
      id: id ?? this.id,
      runId: runId ?? this.runId,
      flowId: flowId ?? this.flowId,
      outcome: outcome ?? this.outcome,
      startedAt: startedAt ?? this.startedAt,
      traceJson: traceJson ?? this.traceJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (runId.present) {
      map['run_id'] = Variable<String>(runId.value);
    }
    if (flowId.present) {
      map['flow_id'] = Variable<String>(flowId.value);
    }
    if (outcome.present) {
      map['outcome'] = Variable<String>(outcome.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (traceJson.present) {
      map['trace_json'] = Variable<String>(traceJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ExecutionLogCompanion(')
          ..write('id: $id, ')
          ..write('runId: $runId, ')
          ..write('flowId: $flowId, ')
          ..write('outcome: $outcome, ')
          ..write('startedAt: $startedAt, ')
          ..write('traceJson: $traceJson')
          ..write(')'))
        .toString();
  }
}

class $BoardDescribesTable extends BoardDescribes
    with TableInfo<$BoardDescribesTable, BoardDescribeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BoardDescribesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _describeJsonMeta = const VerificationMeta(
    'describeJson',
  );
  @override
  late final GeneratedColumn<String> describeJson = GeneratedColumn<String>(
    'describe_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seenAtMeta = const VerificationMeta('seenAt');
  @override
  late final GeneratedColumn<DateTime> seenAt = GeneratedColumn<DateTime>(
    'seen_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [deviceId, describeJson, seenAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'board_describes';
  @override
  VerificationContext validateIntegrity(
    Insertable<BoardDescribeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('describe_json')) {
      context.handle(
        _describeJsonMeta,
        describeJson.isAcceptableOrUnknown(
          data['describe_json']!,
          _describeJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_describeJsonMeta);
    }
    if (data.containsKey('seen_at')) {
      context.handle(
        _seenAtMeta,
        seenAt.isAcceptableOrUnknown(data['seen_at']!, _seenAtMeta),
      );
    } else if (isInserting) {
      context.missing(_seenAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {deviceId};
  @override
  BoardDescribeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BoardDescribeRow(
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      describeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}describe_json'],
      )!,
      seenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}seen_at'],
      )!,
    );
  }

  @override
  $BoardDescribesTable createAlias(String alias) {
    return $BoardDescribesTable(attachedDatabase, alias);
  }
}

class BoardDescribeRow extends DataClass
    implements Insertable<BoardDescribeRow> {
  final String deviceId;
  final String describeJson;
  final DateTime seenAt;
  const BoardDescribeRow({
    required this.deviceId,
    required this.describeJson,
    required this.seenAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['device_id'] = Variable<String>(deviceId);
    map['describe_json'] = Variable<String>(describeJson);
    map['seen_at'] = Variable<DateTime>(seenAt);
    return map;
  }

  BoardDescribesCompanion toCompanion(bool nullToAbsent) {
    return BoardDescribesCompanion(
      deviceId: Value(deviceId),
      describeJson: Value(describeJson),
      seenAt: Value(seenAt),
    );
  }

  factory BoardDescribeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BoardDescribeRow(
      deviceId: serializer.fromJson<String>(json['deviceId']),
      describeJson: serializer.fromJson<String>(json['describeJson']),
      seenAt: serializer.fromJson<DateTime>(json['seenAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'deviceId': serializer.toJson<String>(deviceId),
      'describeJson': serializer.toJson<String>(describeJson),
      'seenAt': serializer.toJson<DateTime>(seenAt),
    };
  }

  BoardDescribeRow copyWith({
    String? deviceId,
    String? describeJson,
    DateTime? seenAt,
  }) => BoardDescribeRow(
    deviceId: deviceId ?? this.deviceId,
    describeJson: describeJson ?? this.describeJson,
    seenAt: seenAt ?? this.seenAt,
  );
  BoardDescribeRow copyWithCompanion(BoardDescribesCompanion data) {
    return BoardDescribeRow(
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      describeJson: data.describeJson.present
          ? data.describeJson.value
          : this.describeJson,
      seenAt: data.seenAt.present ? data.seenAt.value : this.seenAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BoardDescribeRow(')
          ..write('deviceId: $deviceId, ')
          ..write('describeJson: $describeJson, ')
          ..write('seenAt: $seenAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(deviceId, describeJson, seenAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BoardDescribeRow &&
          other.deviceId == this.deviceId &&
          other.describeJson == this.describeJson &&
          other.seenAt == this.seenAt);
}

class BoardDescribesCompanion extends UpdateCompanion<BoardDescribeRow> {
  final Value<String> deviceId;
  final Value<String> describeJson;
  final Value<DateTime> seenAt;
  final Value<int> rowid;
  const BoardDescribesCompanion({
    this.deviceId = const Value.absent(),
    this.describeJson = const Value.absent(),
    this.seenAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BoardDescribesCompanion.insert({
    required String deviceId,
    required String describeJson,
    required DateTime seenAt,
    this.rowid = const Value.absent(),
  }) : deviceId = Value(deviceId),
       describeJson = Value(describeJson),
       seenAt = Value(seenAt);
  static Insertable<BoardDescribeRow> custom({
    Expression<String>? deviceId,
    Expression<String>? describeJson,
    Expression<DateTime>? seenAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (deviceId != null) 'device_id': deviceId,
      if (describeJson != null) 'describe_json': describeJson,
      if (seenAt != null) 'seen_at': seenAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BoardDescribesCompanion copyWith({
    Value<String>? deviceId,
    Value<String>? describeJson,
    Value<DateTime>? seenAt,
    Value<int>? rowid,
  }) {
    return BoardDescribesCompanion(
      deviceId: deviceId ?? this.deviceId,
      describeJson: describeJson ?? this.describeJson,
      seenAt: seenAt ?? this.seenAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (describeJson.present) {
      map['describe_json'] = Variable<String>(describeJson.value);
    }
    if (seenAt.present) {
      map['seen_at'] = Variable<DateTime>(seenAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BoardDescribesCompanion(')
          ..write('deviceId: $deviceId, ')
          ..write('describeJson: $describeJson, ')
          ..write('seenAt: $seenAt, ')
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
  late final $FlowsTable flows = $FlowsTable(this);
  late final $ZonesTable zones = $ZonesTable(this);
  late final $GlobalVariablesTable globalVariables = $GlobalVariablesTable(
    this,
  );
  late final $ExecutionLogTable executionLog = $ExecutionLogTable(this);
  late final $BoardDescribesTable boardDescribes = $BoardDescribesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    driverManifests,
    devices,
    flows,
    zones,
    globalVariables,
    executionLog,
    boardDescribes,
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
typedef $$FlowsTableCreateCompanionBuilder = FlowsCompanion Function({
  required String id,
  required String flowJson,
  Value<bool> enabled,
  Value<bool> approved,
  Value<bool> trusted,
  Value<String> source,
  Value<String?> specJson,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$FlowsTableUpdateCompanionBuilder = FlowsCompanion Function({
  Value<String> id,
  Value<String> flowJson,
  Value<bool> enabled,
  Value<bool> approved,
  Value<bool> trusted,
  Value<String> source,
  Value<String?> specJson,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$FlowsTableFilterComposer extends Composer<_$OmniDatabase, $FlowsTable> {
  $$FlowsTableFilterComposer({
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

  ColumnFilters<String> get flowJson => $composableBuilder(
    column: $table.flowJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get approved => $composableBuilder(
    column: $table.approved,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get specJson => $composableBuilder(
    column: $table.specJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FlowsTableOrderingComposer
    extends Composer<_$OmniDatabase, $FlowsTable> {
  $$FlowsTableOrderingComposer({
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

  ColumnOrderings<String> get flowJson => $composableBuilder(
    column: $table.flowJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get approved => $composableBuilder(
    column: $table.approved,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get specJson => $composableBuilder(
    column: $table.specJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FlowsTableAnnotationComposer
    extends Composer<_$OmniDatabase, $FlowsTable> {
  $$FlowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get flowJson =>
      $composableBuilder(column: $table.flowJson, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<bool> get approved =>
      $composableBuilder(column: $table.approved, builder: (column) => column);

  GeneratedColumn<bool> get trusted =>
      $composableBuilder(column: $table.trusted, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get specJson =>
      $composableBuilder(column: $table.specJson, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$FlowsTableTableManager
    extends
        RootTableManager<
          _$OmniDatabase,
          $FlowsTable,
          FlowRow,
          $$FlowsTableFilterComposer,
          $$FlowsTableOrderingComposer,
          $$FlowsTableAnnotationComposer,
          $$FlowsTableCreateCompanionBuilder,
          $$FlowsTableUpdateCompanionBuilder,
          (FlowRow, BaseReferences<_$OmniDatabase, $FlowsTable, FlowRow>),
          FlowRow,
          PrefetchHooks Function()
        > {
  $$FlowsTableTableManager(_$OmniDatabase db, $FlowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FlowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FlowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FlowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> flowJson = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<bool> approved = const Value.absent(),
                Value<bool> trusted = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> specJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FlowsCompanion(
                id: id,
                flowJson: flowJson,
                enabled: enabled,
                approved: approved,
                trusted: trusted,
                source: source,
                specJson: specJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String flowJson,
                Value<bool> enabled = const Value.absent(),
                Value<bool> approved = const Value.absent(),
                Value<bool> trusted = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> specJson = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => FlowsCompanion.insert(
                id: id,
                flowJson: flowJson,
                enabled: enabled,
                approved: approved,
                trusted: trusted,
                source: source,
                specJson: specJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FlowsTable, FlowRow>(table),
                  BaseReferences<_$OmniDatabase, $FlowsTable, FlowRow>(
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

typedef $$FlowsTableProcessedTableManager =
    ProcessedTableManager<
      _$OmniDatabase,
      $FlowsTable,
      FlowRow,
      $$FlowsTableFilterComposer,
      $$FlowsTableOrderingComposer,
      $$FlowsTableAnnotationComposer,
      $$FlowsTableCreateCompanionBuilder,
      $$FlowsTableUpdateCompanionBuilder,
      (FlowRow, BaseReferences<_$OmniDatabase, $FlowsTable, FlowRow>),
      FlowRow,
      PrefetchHooks Function()
    >;
typedef $$ZonesTableCreateCompanionBuilder = ZonesCompanion Function({
  required String id,
  required String zoneJson,
  Value<int> rowid,
});
typedef $$ZonesTableUpdateCompanionBuilder = ZonesCompanion Function({
  Value<String> id,
  Value<String> zoneJson,
  Value<int> rowid,
});

class $$ZonesTableFilterComposer extends Composer<_$OmniDatabase, $ZonesTable> {
  $$ZonesTableFilterComposer({
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

  ColumnFilters<String> get zoneJson => $composableBuilder(
    column: $table.zoneJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ZonesTableOrderingComposer
    extends Composer<_$OmniDatabase, $ZonesTable> {
  $$ZonesTableOrderingComposer({
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

  ColumnOrderings<String> get zoneJson => $composableBuilder(
    column: $table.zoneJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ZonesTableAnnotationComposer
    extends Composer<_$OmniDatabase, $ZonesTable> {
  $$ZonesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get zoneJson =>
      $composableBuilder(column: $table.zoneJson, builder: (column) => column);
}

class $$ZonesTableTableManager
    extends
        RootTableManager<
          _$OmniDatabase,
          $ZonesTable,
          ZoneRow,
          $$ZonesTableFilterComposer,
          $$ZonesTableOrderingComposer,
          $$ZonesTableAnnotationComposer,
          $$ZonesTableCreateCompanionBuilder,
          $$ZonesTableUpdateCompanionBuilder,
          (ZoneRow, BaseReferences<_$OmniDatabase, $ZonesTable, ZoneRow>),
          ZoneRow,
          PrefetchHooks Function()
        > {
  $$ZonesTableTableManager(_$OmniDatabase db, $ZonesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ZonesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ZonesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ZonesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> zoneJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => ZonesCompanion(id: id, zoneJson: zoneJson, rowid: rowid),
          createCompanionCallback: ({
            required String id,
            required String zoneJson,
            Value<int> rowid = const Value.absent(),
          }) => ZonesCompanion.insert(id: id, zoneJson: zoneJson, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ZonesTable, ZoneRow>(table),
                  BaseReferences<_$OmniDatabase, $ZonesTable, ZoneRow>(
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

typedef $$ZonesTableProcessedTableManager =
    ProcessedTableManager<
      _$OmniDatabase,
      $ZonesTable,
      ZoneRow,
      $$ZonesTableFilterComposer,
      $$ZonesTableOrderingComposer,
      $$ZonesTableAnnotationComposer,
      $$ZonesTableCreateCompanionBuilder,
      $$ZonesTableUpdateCompanionBuilder,
      (ZoneRow, BaseReferences<_$OmniDatabase, $ZonesTable, ZoneRow>),
      ZoneRow,
      PrefetchHooks Function()
    >;
typedef $$GlobalVariablesTableCreateCompanionBuilder =
    GlobalVariablesCompanion Function({
      required String name,
      required String valueJson,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$GlobalVariablesTableUpdateCompanionBuilder =
    GlobalVariablesCompanion Function({
      Value<String> name,
      Value<String> valueJson,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$GlobalVariablesTableFilterComposer
    extends Composer<_$OmniDatabase, $GlobalVariablesTable> {
  $$GlobalVariablesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GlobalVariablesTableOrderingComposer
    extends Composer<_$OmniDatabase, $GlobalVariablesTable> {
  $$GlobalVariablesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GlobalVariablesTableAnnotationComposer
    extends Composer<_$OmniDatabase, $GlobalVariablesTable> {
  $$GlobalVariablesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get valueJson =>
      $composableBuilder(column: $table.valueJson, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$GlobalVariablesTableTableManager
    extends
        RootTableManager<
          _$OmniDatabase,
          $GlobalVariablesTable,
          GlobalRow,
          $$GlobalVariablesTableFilterComposer,
          $$GlobalVariablesTableOrderingComposer,
          $$GlobalVariablesTableAnnotationComposer,
          $$GlobalVariablesTableCreateCompanionBuilder,
          $$GlobalVariablesTableUpdateCompanionBuilder,
          (
            GlobalRow,
            BaseReferences<_$OmniDatabase, $GlobalVariablesTable, GlobalRow>,
          ),
          GlobalRow,
          PrefetchHooks Function()
        > {
  $$GlobalVariablesTableTableManager(
    _$OmniDatabase db,
    $GlobalVariablesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GlobalVariablesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GlobalVariablesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GlobalVariablesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> name = const Value.absent(),
                Value<String> valueJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GlobalVariablesCompanion(
                name: name,
                valueJson: valueJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String name,
                required String valueJson,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => GlobalVariablesCompanion.insert(
                name: name,
                valueJson: valueJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$GlobalVariablesTable, GlobalRow>(table),
                  BaseReferences<
                    _$OmniDatabase,
                    $GlobalVariablesTable,
                    GlobalRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GlobalVariablesTableProcessedTableManager =
    ProcessedTableManager<
      _$OmniDatabase,
      $GlobalVariablesTable,
      GlobalRow,
      $$GlobalVariablesTableFilterComposer,
      $$GlobalVariablesTableOrderingComposer,
      $$GlobalVariablesTableAnnotationComposer,
      $$GlobalVariablesTableCreateCompanionBuilder,
      $$GlobalVariablesTableUpdateCompanionBuilder,
      (
        GlobalRow,
        BaseReferences<_$OmniDatabase, $GlobalVariablesTable, GlobalRow>,
      ),
      GlobalRow,
      PrefetchHooks Function()
    >;
typedef $$ExecutionLogTableCreateCompanionBuilder =
    ExecutionLogCompanion Function({
      Value<int> id,
      required String runId,
      required String flowId,
      required String outcome,
      required DateTime startedAt,
      required String traceJson,
    });
typedef $$ExecutionLogTableUpdateCompanionBuilder =
    ExecutionLogCompanion Function({
      Value<int> id,
      Value<String> runId,
      Value<String> flowId,
      Value<String> outcome,
      Value<DateTime> startedAt,
      Value<String> traceJson,
    });

class $$ExecutionLogTableFilterComposer
    extends Composer<_$OmniDatabase, $ExecutionLogTable> {
  $$ExecutionLogTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get runId => $composableBuilder(
    column: $table.runId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get flowId => $composableBuilder(
    column: $table.flowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get traceJson => $composableBuilder(
    column: $table.traceJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ExecutionLogTableOrderingComposer
    extends Composer<_$OmniDatabase, $ExecutionLogTable> {
  $$ExecutionLogTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get runId => $composableBuilder(
    column: $table.runId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get flowId => $composableBuilder(
    column: $table.flowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get traceJson => $composableBuilder(
    column: $table.traceJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ExecutionLogTableAnnotationComposer
    extends Composer<_$OmniDatabase, $ExecutionLogTable> {
  $$ExecutionLogTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get runId =>
      $composableBuilder(column: $table.runId, builder: (column) => column);

  GeneratedColumn<String> get flowId =>
      $composableBuilder(column: $table.flowId, builder: (column) => column);

  GeneratedColumn<String> get outcome =>
      $composableBuilder(column: $table.outcome, builder: (column) => column);

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<String> get traceJson =>
      $composableBuilder(column: $table.traceJson, builder: (column) => column);
}

class $$ExecutionLogTableTableManager
    extends
        RootTableManager<
          _$OmniDatabase,
          $ExecutionLogTable,
          LogRow,
          $$ExecutionLogTableFilterComposer,
          $$ExecutionLogTableOrderingComposer,
          $$ExecutionLogTableAnnotationComposer,
          $$ExecutionLogTableCreateCompanionBuilder,
          $$ExecutionLogTableUpdateCompanionBuilder,
          (LogRow, BaseReferences<_$OmniDatabase, $ExecutionLogTable, LogRow>),
          LogRow,
          PrefetchHooks Function()
        > {
  $$ExecutionLogTableTableManager(_$OmniDatabase db, $ExecutionLogTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ExecutionLogTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ExecutionLogTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ExecutionLogTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> runId = const Value.absent(),
                Value<String> flowId = const Value.absent(),
                Value<String> outcome = const Value.absent(),
                Value<DateTime> startedAt = const Value.absent(),
                Value<String> traceJson = const Value.absent(),
              }) => ExecutionLogCompanion(
                id: id,
                runId: runId,
                flowId: flowId,
                outcome: outcome,
                startedAt: startedAt,
                traceJson: traceJson,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String runId,
                required String flowId,
                required String outcome,
                required DateTime startedAt,
                required String traceJson,
              }) => ExecutionLogCompanion.insert(
                id: id,
                runId: runId,
                flowId: flowId,
                outcome: outcome,
                startedAt: startedAt,
                traceJson: traceJson,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ExecutionLogTable, LogRow>(table),
                  BaseReferences<_$OmniDatabase, $ExecutionLogTable, LogRow>(
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

typedef $$ExecutionLogTableProcessedTableManager =
    ProcessedTableManager<
      _$OmniDatabase,
      $ExecutionLogTable,
      LogRow,
      $$ExecutionLogTableFilterComposer,
      $$ExecutionLogTableOrderingComposer,
      $$ExecutionLogTableAnnotationComposer,
      $$ExecutionLogTableCreateCompanionBuilder,
      $$ExecutionLogTableUpdateCompanionBuilder,
      (LogRow, BaseReferences<_$OmniDatabase, $ExecutionLogTable, LogRow>),
      LogRow,
      PrefetchHooks Function()
    >;
typedef $$BoardDescribesTableCreateCompanionBuilder =
    BoardDescribesCompanion Function({
      required String deviceId,
      required String describeJson,
      required DateTime seenAt,
      Value<int> rowid,
    });
typedef $$BoardDescribesTableUpdateCompanionBuilder =
    BoardDescribesCompanion Function({
      Value<String> deviceId,
      Value<String> describeJson,
      Value<DateTime> seenAt,
      Value<int> rowid,
    });

class $$BoardDescribesTableFilterComposer
    extends Composer<_$OmniDatabase, $BoardDescribesTable> {
  $$BoardDescribesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get describeJson => $composableBuilder(
    column: $table.describeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get seenAt => $composableBuilder(
    column: $table.seenAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BoardDescribesTableOrderingComposer
    extends Composer<_$OmniDatabase, $BoardDescribesTable> {
  $$BoardDescribesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get describeJson => $composableBuilder(
    column: $table.describeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get seenAt => $composableBuilder(
    column: $table.seenAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BoardDescribesTableAnnotationComposer
    extends Composer<_$OmniDatabase, $BoardDescribesTable> {
  $$BoardDescribesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get describeJson => $composableBuilder(
    column: $table.describeJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get seenAt =>
      $composableBuilder(column: $table.seenAt, builder: (column) => column);
}

class $$BoardDescribesTableTableManager
    extends
        RootTableManager<
          _$OmniDatabase,
          $BoardDescribesTable,
          BoardDescribeRow,
          $$BoardDescribesTableFilterComposer,
          $$BoardDescribesTableOrderingComposer,
          $$BoardDescribesTableAnnotationComposer,
          $$BoardDescribesTableCreateCompanionBuilder,
          $$BoardDescribesTableUpdateCompanionBuilder,
          (
            BoardDescribeRow,
            BaseReferences<
              _$OmniDatabase,
              $BoardDescribesTable,
              BoardDescribeRow
            >,
          ),
          BoardDescribeRow,
          PrefetchHooks Function()
        > {
  $$BoardDescribesTableTableManager(
    _$OmniDatabase db,
    $BoardDescribesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BoardDescribesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BoardDescribesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BoardDescribesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> deviceId = const Value.absent(),
                Value<String> describeJson = const Value.absent(),
                Value<DateTime> seenAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BoardDescribesCompanion(
                deviceId: deviceId,
                describeJson: describeJson,
                seenAt: seenAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String deviceId,
                required String describeJson,
                required DateTime seenAt,
                Value<int> rowid = const Value.absent(),
              }) => BoardDescribesCompanion.insert(
                deviceId: deviceId,
                describeJson: describeJson,
                seenAt: seenAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BoardDescribesTable, BoardDescribeRow>(table),
                  BaseReferences<
                    _$OmniDatabase,
                    $BoardDescribesTable,
                    BoardDescribeRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BoardDescribesTableProcessedTableManager =
    ProcessedTableManager<
      _$OmniDatabase,
      $BoardDescribesTable,
      BoardDescribeRow,
      $$BoardDescribesTableFilterComposer,
      $$BoardDescribesTableOrderingComposer,
      $$BoardDescribesTableAnnotationComposer,
      $$BoardDescribesTableCreateCompanionBuilder,
      $$BoardDescribesTableUpdateCompanionBuilder,
      (
        BoardDescribeRow,
        BaseReferences<_$OmniDatabase, $BoardDescribesTable, BoardDescribeRow>,
      ),
      BoardDescribeRow,
      PrefetchHooks Function()
    >;

class $OmniDatabaseManager {
  final _$OmniDatabase _db;
  $OmniDatabaseManager(this._db);
  $$DriverManifestsTableTableManager get driverManifests =>
      $$DriverManifestsTableTableManager(_db, _db.driverManifests);
  $$DevicesTableTableManager get devices =>
      $$DevicesTableTableManager(_db, _db.devices);
  $$FlowsTableTableManager get flows =>
      $$FlowsTableTableManager(_db, _db.flows);
  $$ZonesTableTableManager get zones =>
      $$ZonesTableTableManager(_db, _db.zones);
  $$GlobalVariablesTableTableManager get globalVariables =>
      $$GlobalVariablesTableTableManager(_db, _db.globalVariables);
  $$ExecutionLogTableTableManager get executionLog =>
      $$ExecutionLogTableTableManager(_db, _db.executionLog);
  $$BoardDescribesTableTableManager get boardDescribes =>
      $$BoardDescribesTableTableManager(_db, _db.boardDescribes);
}
