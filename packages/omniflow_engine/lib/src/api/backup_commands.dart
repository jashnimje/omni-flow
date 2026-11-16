import 'dart:convert';

import 'agent_policy.dart' show reservedVariable;
import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'home_commands.dart';
import 'house_helpers.dart';
import 'houses.dart';
import 'stored_flows.dart';
import 'thing_setup.dart';
import 'versions.dart' show keepingVersionsOf;
import 'things_runtime.dart';
import '../dag/canonical.dart';
import '../dag/flow.dart';
import '../dag/sun.dart';
import '../dag/validator.dart';
import '../devices/adb/adb_key.dart' show adbHostKeySecret;
import '../devices/board.dart';
import '../devices/device.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';
import '../storage/secret_store.dart';
import '../version.dart';

/// What a backup says it is, so an import refuses any other JSON.
const backupSchema = 'omniflow.backup';
const backupVersion = 1;

final _id = RegExp(r'^[a-z][a-z0-9_]*$');
final _variableName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// `config.export` and `config.import`: the whole home as one JSON object,
/// and back.
///
/// A backup carries no secret and no trust. Secret settings stay in the
/// secret store, so a restored device asks for them again. Automations come
/// back untrusted, as an agent's do: a high-risk one waits for the user to
/// approve it again, and a low-risk one goes live. The agent access level
/// stays the user's, so a restored home starts at read.
class BackupCommands {
  BackupCommands(
    this._core,
    this._stored,
    this._things,
    this._home, {
    required this.removeThing,
    required this.resetThing,
    this.house,
  });

  /// The house mode and alert switches, kept under `home` beside the
  /// location.
  final HouseHelpers? house;

  final EngineCore _core;
  final StoredFlows _stored;
  final ThingsRuntime _things;
  final HomeCommands _home;

  /// Removes a thing as `device.remove` does: its secrets, history and the
  /// sessions held for it.
  final Future<void> Function(String id) removeThing;

  /// Drops what is held for a thing the import changed (a live poll, a TV
  /// session), so it starts again from its new settings.
  final void Function(String id) resetThing;

  OmniDatabase get _db => _core.db;

  /// The house a running import replaces and restores into, or null for a
  /// backup of every house, which restores each record into its own.
  String? _scope;

  Map<String, CommandHandler> get commands => {
    'config.export': export,
    'config.import': import,
  };

  /// `{house?}`: the whole home, or one house. A backup of one house holds
  /// its things (with the people and phones every house shares), rooms,
  /// automations, variables and settings, and says which house it was. A
  /// backup of every house gives each record its `house`, lists the houses,
  /// and keeps each house's settings under `houseSettings`. Either reads
  /// back on an engine from before houses, as the first house's home.
  Future<Map<String, Object?>> export(Map<String, Object?> args) async {
    final houses = _core.houses;
    final only = houses.resolve(args['house']);
    final roomHouses = await houses.housesOf(HouseKind.room);
    final variableHouses = await houses.housesOf(HouseKind.variable);
    bool inHouse(String? of) => only == null || (of ?? only) == only;
    final skipped = <String>[];
    final things = <Map<String, Object?>>[];
    for (final d in await DriftDeviceStore(_db).all()) {
      if (only != null && !houses.thingIn(d.id, only)) continue;
      final json = _thingJson(d);
      json == null
          ? skipped.add(d.id)
          : things.add({
              ...json,
              if (only == null) 'house': ?houses.thingHouses[d.id],
            });
    }
    final settingsHouse = only ?? houses.defaultId;
    return {
      'backup': {
        'schema': backupSchema,
        'version': backupVersion,
        'engine': omniflowEngineVersion,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'drivers': [
          for (final json in await DriftManifestStore(_db).all())
            jsonDecode(json),
        ],
        'rooms': [
          for (final r in await DriftRoomStore(_db).all())
            if (inHouse(roomHouses[r.id]))
              {..._roomJson(r), if (only == null) 'house': ?roomHouses[r.id]},
        ],
        'things': things,
        'automations': [
          for (final r in await DriftFlowStore(_db).all())
            if (inHouse(houses.flowHouses['${r.json['id']}']))
              {
                ..._automationJson(r),
                if (only == null)
                  'house': ?houses.flowHouses['${r.json['id']}'],
              },
        ],
        'variables': {
          for (final e in (await _userVariables()).entries)
            if (inHouse(variableHouses[e.key])) e.key: e.value,
        },
        'home': _homeJson(settingsHouse),
        if (only != null)
          'house': {'id': only, 'name': houses.nameOf(only)}
        else ...{
          'houses': [for (final h in houses.all) h.toJson()],
          'houseSettings': {for (final h in houses.all) h.id: _homeJson(h.id)},
          'variableHouses': {
            for (final e in variableHouses.entries)
              if (!reservedVariable(e.key)) e.key: e.value,
          },
        },
      },
      if (skipped.isNotEmpty) 'skipped': skipped,
    };
  }

  /// What a backup keeps of [house]'s settings: where it is, its mode and
  /// its alerts.
  Map<String, Object?> _homeJson(String house) => {
    'location': ?homeLocationJson(houseLocation(_core, house)),
    ...?this.house?.backupJson(house),
  };

  /// A thing as a backup keeps it: no state, no secret, and null when its
  /// driver is gone, since then which settings are secret is unknown.
  Map<String, Object?>? _thingJson(Device d) {
    final manifest = _core.registry[d.driverId];
    if (manifest == null) return null;
    final secret = {
      for (final s in manifest.settings)
        if (s.secret) s.key,
    };
    return {
      'id': d.id,
      'name': d.name,
      'driver': d.driverId,
      'host': d.host,
      'port': ?d.port,
      'room': ?d.room,
      'stableId': ?d.stableId,
      if (d.favourite) 'favourite': true,
      'order': ?d.order,
      'settings': {
        for (final e in d.settings.entries)
          if (!secret.contains(e.key)) e.key: e.value,
      },
    };
  }

  static Map<String, Object?> _roomJson(Room r) => {
    'id': r.id,
    'name': r.name,
    'order': r.order,
  };

  static Map<String, Object?> _automationJson(FlowRecord r) => {
    'id': r.json['id'],
    'source': r.source,
    'enabled': r.enabled,
    'flow': StoredFlows.flowJsonOf(r),
    'spec': ?r.spec,
  };

  /// The globals the user set. The engine's own (presence, Wi-Fi) are
  /// readings, which a restored home takes again.
  Future<Map<String, Object?>> _userVariables() async => {
    for (final e in (await DriftGlobalStore(_db).all()).entries)
      if (!reservedVariable(e.key)) e.key: e.value,
  };

  /// `{backup, mode?: merge | replace, dryRun?, house?}`. Checks the whole
  /// backup first and changes nothing when any part is wrong. Merge keeps
  /// what the backup does not name, replace makes the house exactly the
  /// backup. `house` is the house it restores into, the first house by
  /// default; a backup of every house with no `house` restores each record
  /// into its own house, adding the houses it names, and replace then
  /// makes the whole home the backup. A backup from before houses reads as
  /// one house. Keeps the version of every automation the import replaces.
  Future<Map<String, Object?>> import(Map<String, Object?> args) =>
      args['dryRun'] == true
      ? _import(args)
      : keepingVersionsOf(_db, () => _import(args));

  Future<Map<String, Object?>> _import(Map<String, Object?> args) async {
    final backup = objectArg(args, 'backup');
    final mode = args['mode'] ?? 'merge';
    if (mode != 'merge' && mode != 'replace') {
      throw ApiError('invalid', 'mode must be merge or replace');
    }
    final dryRun = args['dryRun'] == true;
    final replace = mode == 'replace';
    final into = _core.houses.resolve(args['house']);
    final everyHouse = into == null && backup['houses'] is List;
    _scope = everyHouse ? null : into ?? _core.houses.defaultId;
    final plan = await _plan(backup, replace: replace);

    final registered = <String>[];
    final previous = {
      for (final json in await DriftManifestStore(_db).all())
        if (_idOf(json) case final String id) id: json,
    };
    for (final d in plan.drivers) {
      _core.registry.register(d);
      registered.add('${d['id']}');
    }
    Map<String, Object?>? report;
    try {
      report = await _db.transaction(() async {
        final result = await _write(plan, replace: replace, backup: backup);
        if (dryRun) throw _Rollback(result);
        return result;
      });
    } on _Rollback catch (r) {
      report = r.report;
    } finally {
      if (dryRun || report == null) {
        for (final id in registered) {
          _core.registry.unregister(id);
          if (previous[id] case final json?) {
            _core.registry.register(jsonDecode(json));
          }
        }
      }
    }
    await _core.houses.load();
    final result = report!;
    final held = _Held(result);
    if (!dryRun) await _settle(plan, held, replace: replace);
    if (!dryRun) await _restoreSettings(backup);
    return {
      'dryRun': dryRun,
      'mode': mode,
      'applied': !dryRun,
      'house': ?_scope,
      ...result,
    };
  }

  /// Takes the mode and alerts a backup holds: into the house it restores
  /// into, or for a backup of every house, each house's own.
  Future<void> _restoreSettings(Map<String, Object?> backup) async {
    final helpers = house;
    if (helpers == null) return;
    final scope = _scope;
    if (scope != null) return helpers.restore(backup['home'], scope);
    final each = backup['houseSettings'];
    if (each is! Map) return helpers.restore(backup['home']);
    for (final e in each.entries) {
      final id = '${e.key}';
      if (_core.houses.byId(id) == null) continue;
      await helpers.restore(e.value, id);
      final location = e.value is Map ? (e.value as Map)['location'] : null;
      if (id != (_core.houses.defaultId) && location != null) {
        try {
          await _home.apply(homeLocationOf(location), house: id);
        } on ApiError {
          // A damaged location leaves that house's as it was.
        }
      }
    }
  }

  /// Puts what the import wrote in its house: every record in the house it
  /// restores into, or for a backup of every house each in the house it
  /// names (made when missing), else the first house. People and phones
  /// stay shared.
  Future<void> _stampHouses(_Plan plan, Map<String, Object?> backup) async {
    final houses = _core.houses;
    final scope = _scope;
    final known = {for (final h in houses.all) h.id};
    if (scope == null) {
      final listed = backup['houses'] as List;
      var order = houses.all.isEmpty ? 0 : houses.all.last.order + 1;
      for (final h in listed) {
        if (h is! Map) continue;
        final id = h['id'];
        final name = h['name'];
        if (id is! String || name is! String || known.contains(id)) continue;
        if (!RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch(id)) continue;
        await _db.customStatement(
          'INSERT INTO houses (id, name, position) VALUES (?, ?, ?)',
          [id, name.trim().isEmpty ? id : name.trim(), order++],
        );
        known.add(id);
      }
    }
    String houseOf(Object? named) =>
        scope ??
        (named is String && known.contains(named) ? named : houses.defaultId);
    for (final t in plan.things) {
      final driver = t['driver'];
      if (driver == personDriverId || driver == phoneDriverId) continue;
      await houses.put(HouseKind.thing, '${t['id']}', houseOf(t['house']));
    }
    for (final r in plan.rooms) {
      await houses.put(HouseKind.room, '${r['id']}', houseOf(r['house']));
    }
    for (final a in plan.automations) {
      await houses.put(HouseKind.flow, '${a['id']}', houseOf(a['house']));
    }
    final variableHouses = backup['variableHouses'];
    for (final name in plan.variables.keys) {
      await houses.put(
        HouseKind.variable,
        name,
        houseOf(variableHouses is Map ? variableHouses[name] : null),
      );
    }
  }

  static Object? _idOf(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map ? decoded['id'] : null;
    } on FormatException {
      return null;
    }
  }

  /// The backup read and checked against itself and the drivers, with
  /// every problem at its path in the backup.
  Future<_Plan> _plan(
    Map<String, Object?> backup, {
    required bool replace,
  }) async {
    final issues = IssueCollector();
    if (backup['schema'] != backupSchema) {
      issues.add(
        'schema',
        'must be $backupSchema: this is not an OmniFlow backup',
      );
    }
    final version = backup['version'];
    if (version is! int || version < 1 || version > backupVersion) {
      issues.add(
        'version',
        'must be 1 to $backupVersion. A newer backup needs a newer OmniFlow',
      );
    }
    List<Map<String, Object?>> list(String key) {
      final value = backup[key];
      if (value == null) return const [];
      if (value is! List || value.any((v) => v is! Map)) {
        issues.add(key, 'must be a list of objects');
        return const [];
      }
      return [for (final v in value) Map<String, Object?>.from(v as Map)];
    }

    final drivers = list('drivers');
    final driverIds = <String>{};
    final manifests = <String, DriverManifest>{};
    for (var i = 0; i < drivers.length; i++) {
      try {
        final m = DriverManifest.parse(drivers[i]);
        if (_core.registry.isBuiltIn(m.id)) {
          issues.add('drivers[$i].id', '${m.id} is a built-in driver');
        } else if (!driverIds.add(m.id)) {
          issues.add('drivers[$i].id', 'names ${m.id} twice');
        } else {
          manifests[m.id] = m;
        }
      } on ValidationException catch (e) {
        _nest(issues, 'drivers[$i]', e.issues);
      }
    }
    DriverManifest? driver(String id) =>
        manifests[id] ??
        (_core.registry.isBuiltIn(id) || !replace ? _core.registry[id] : null);

    final rooms = list('rooms');
    final roomIds = <String>{};
    for (var i = 0; i < rooms.length; i++) {
      final r = rooms[i];
      final id = issues.requiredString(r, 'id', 'rooms[$i]');
      final name = issues.requiredString(r, 'name', 'rooms[$i]');
      issues.optionalInt(r, 'order', 'rooms[$i]');
      if (id != null && !_id.hasMatch(id)) {
        issues.add('rooms[$i].id', 'must be lower snake case');
      } else if (id != null && !roomIds.add(id)) {
        issues.add('rooms[$i].id', 'names $id twice');
      }
      if (name != null) r['name'] = name.trim();
    }
    final knownRooms = {
      ...roomIds,
      if (!replace)
        for (final r in await DriftRoomStore(_db).all()) r.id,
    };

    final things = list('things');
    final thingIds = <String>{};
    final uids = <String, String>{};
    for (var i = 0; i < things.length; i++) {
      final at = 'things[$i]';
      final t = things[i];
      final id = issues.requiredString(t, 'id', at);
      if (id != null && !_id.hasMatch(id)) {
        issues.add('$at.id', 'must be lower snake case');
      } else if (id != null && !thingIds.add(id)) {
        issues.add('$at.id', 'names $id twice');
      }
      issues.requiredString(t, 'name', at);
      final driverId = issues.requiredString(t, 'driver', at);
      final manifest = driverId == null ? null : driver(driverId);
      if (driverId != null && manifest == null) {
        issues.add(
          '$at.driver',
          'no driver $driverId, and the backup has none',
        );
      }
      issues.requiredString(t, 'host', at);
      issues.optionalInt(t, 'port', at, min: 1, max: 65535);
      issues.optionalInt(t, 'order', at);
      issues.optionalString(t, 'stableId', at);
      if (t['favourite'] != null && t['favourite'] is! bool) {
        issues.add('$at.favourite', 'must be true or false');
      }
      final room = issues.optionalString(t, 'room', at);
      if (room != null && !knownRooms.contains(room)) {
        issues.add('$at.room', 'no room $room');
      }
      final settings = t['settings'] ?? const <String, Object?>{};
      if (settings is! Map) {
        issues.add('$at.settings', 'must be an object');
        continue;
      }
      if (manifest == null) continue;
      _checkSettings(
        issues,
        '$at.settings',
        manifest,
        Map<String, Object?>.from(settings),
      );
      if (manifest.id == nfcTagDriverId && settings['uid'] != null) {
        final uid = normalizeUid(settings['uid']);
        if (uid != null && uids.containsKey(uid)) {
          issues.add('$at.settings.uid', 'the tag ${uids[uid]} has that uid');
        } else if (uid != null && id != null) {
          uids[uid] = id;
        }
      }
      if (manifest.id == placeDriverId && id != null) {
        try {
          zoneOfPlace(
            Device(
              id: id,
              name: '${t['name']}',
              driverId: placeDriverId,
              host: virtualHost,
              settings: Map<String, Object?>.from(settings),
            ),
          );
        } on ValidationException catch (e) {
          _nest(issues, '$at.settings', e.issues);
        }
      }
    }

    final automations = list('automations');
    final flowIds = <String>{};
    for (var i = 0; i < automations.length; i++) {
      final at = 'automations[$i]';
      final a = automations[i];
      final id = issues.requiredString(a, 'id', at);
      if (id != null && !flowIds.add(id)) {
        issues.add('$at.id', 'names $id twice');
      }
      if (!FlowRecord.sources.contains(a['source'] ?? FlowRecord.graph)) {
        issues.add(
          '$at.source',
          'must be one of ${FlowRecord.sources.join(', ')}',
        );
      }
      if (a['enabled'] != null && a['enabled'] is! bool) {
        issues.add('$at.enabled', 'must be true or false');
      }
      final flow = a['flow'];
      if (flow is! Map) {
        issues.add('$at.flow', 'must be an object');
      } else if (id != null && flow['id'] != id) {
        issues.add('$at.flow.id', 'must be $id, the automation id');
      }
      if (a['spec'] != null && a['spec'] is! Map) {
        issues.add('$at.spec', 'must be an object');
      }
    }

    final variables = <String, Object?>{};
    final skippedVariables = <String>[];
    final rawVariables = backup['variables'];
    if (rawVariables != null && rawVariables is! Map) {
      issues.add('variables', 'must be an object');
    } else if (rawVariables is Map) {
      for (final MapEntry(:key, :value) in rawVariables.entries) {
        if (key is! String || !_variableName.hasMatch(key)) {
          issues.add(
            'variables.$key',
            'a variable name is letters, digits and _',
          );
        } else if (reservedVariable(key)) {
          skippedVariables.add(key);
        } else {
          variables[key] = value;
        }
      }
    }

    HomeLocation? location;
    var locationGiven = false;
    final home = backup['home'];
    if (home != null && home is! Map) {
      issues.add('home', 'must be an object');
    } else if (home is Map && home['location'] != null) {
      locationGiven = true;
      try {
        location = homeLocationOf(home['location']);
      } on ApiError catch (e) {
        issues.add('home.location', e.message);
      }
    }

    if (issues.hasIssues) {
      throw ApiError(
        'invalid',
        'The backup has problems, so nothing was imported',
        issues: issues.issues,
      );
    }
    return _Plan(
      drivers: drivers,
      rooms: rooms,
      things: things,
      automations: automations,
      variables: variables,
      skippedVariables: skippedVariables,
      location: location,
      locationGiven: locationGiven,
    );
  }

  /// Plain settings of [manifest] only, as `device.add` checks them.
  void _checkSettings(
    IssueCollector issues,
    String at,
    DriverManifest manifest,
    Map<String, Object?> settings,
  ) {
    for (final key in settings.keys) {
      final spec = manifest.settings.where((s) => s.key == key).firstOrNull;
      if (spec == null) {
        issues.add('$at.$key', 'is not a setting of ${manifest.id}');
      } else if (spec.secret) {
        issues.add(
          '$at.$key',
          'is a secret, and a backup never carries one. Take it out and '
              'store it with omni secret set after the import',
        );
      }
    }
    if (isBoardDriver(manifest)) {
      try {
        parseBoardPins(
          settings['pins'],
          reserved: {for (final c in manifest.capabilities) c.id},
        );
      } on ValidationException catch (e) {
        _nest(issues, '$at.pins', e.issues);
      }
    }
    if (manifest.id == nfcTagDriverId &&
        settings['uid'] != null &&
        normalizeUid(settings['uid']) == null) {
      issues.add('$at.uid', 'must be hex, like 04:A2:2B:1C');
    }
  }

  static void _nest(
    IssueCollector issues,
    String at,
    List<ValidationIssue> inner,
  ) {
    for (final i in inner) {
      final path = i.path == r'$'
          ? at
          : i.path.startsWith(r'$.')
          ? '$at${i.path.substring(1)}'
          : i.path.startsWith(r'$[')
          ? '$at${i.path.substring(1)}'
          : '$at.${i.path}';
      issues.add(path, i.message);
    }
  }

  /// Writes [plan] inside the import's transaction, checks every
  /// automation against the home it makes, and says what changed. Throws
  /// with the issues when an automation does not fit, which rolls it back.
  Future<Map<String, Object?>> _write(
    _Plan plan, {
    required bool replace,
    required Map<String, Object?> backup,
  }) async {
    // A replace into one house removes only that house's records, and
    // keeps the drivers and the people and phones the other houses use.
    final scope = _scope;
    final roomHouses = await _core.houses.housesOf(HouseKind.room);
    final thingHouses = await _core.houses.housesOf(HouseKind.thing);
    final flowHouses = await _core.houses.housesOf(HouseKind.flow);
    final variableHouses = await _core.houses.housesOf(HouseKind.variable);
    bool outside(Map<String, String> of, String id) =>
        scope != null && of[id] != scope;
    final add = _Changes();
    final changed = _Changes();
    final same = _Changes();
    final removed = _Changes();
    void sort(_Changes into, String kind, String id) => into.add(kind, id);

    final devices = DriftDeviceStore(_db);
    final rooms = DriftRoomStore(_db);
    final flows = DriftFlowStore(_db);
    final globals = DriftGlobalStore(_db);
    final manifests = DriftManifestStore(_db);
    final now = DateTime.now().toUtc();

    // Drivers first, so the things on them are known.
    final storedDrivers = {
      for (final json in await manifests.all())
        if (_idOf(json) case final String id) id: json,
    };
    for (final d in plan.drivers) {
      final id = '${d['id']}';
      final json = jsonEncode(d);
      final before = storedDrivers[id];
      sort(
        before == null
            ? add
            : canonicalJson(jsonDecode(before)) == canonicalJson(d)
            ? same
            : changed,
        'drivers',
        id,
      );
      await manifests.put(id, json, now);
      _core.agentDrivers.remove(id);
    }
    if (replace && scope == null) {
      for (final id in storedDrivers.keys) {
        if (plan.drivers.any((d) => d['id'] == id)) continue;
        await manifests.remove(id);
        removed.add('drivers', id);
      }
    }

    final storedRooms = {for (final r in await rooms.all()) r.id: r};
    for (var i = 0; i < plan.rooms.length; i++) {
      final r = plan.rooms[i];
      final room = Room(
        id: '${r['id']}',
        name: '${r['name']}',
        order: r['order'] as int? ?? i,
      );
      final before = storedRooms[room.id];
      sort(
        before == null
            ? add
            : canonicalJson(_roomJson(before)) == canonicalJson(_roomJson(room))
            ? same
            : changed,
        'rooms',
        room.id,
      );
      await rooms.put(room);
    }
    if (replace) {
      for (final id in storedRooms.keys) {
        if (plan.rooms.any((r) => r['id'] == id)) continue;
        if (outside(roomHouses, id)) continue;
        await rooms.remove(id);
        removed.add('rooms', id);
      }
    }

    final storedThings = {for (final d in await devices.all()) d.id: d};
    final backupThingIds = {for (final t in plan.things) '${t['id']}'};
    if (replace) {
      for (final id in storedThings.keys) {
        if (backupThingIds.contains(id)) continue;
        if (outside(thingHouses, id)) continue;
        await devices.remove(id);
        await DriftHistoryStore(_db).removeDevice(id);
        await DriftBoardDescribeStore(_db).remove(id);
        removed.add('things', id);
      }
    }
    for (final t in plan.things) {
      final id = '${t['id']}';
      final driverId = '${t['driver']}';
      final before = storedThings[id];
      final keep = before != null && before.driverId == driverId;
      final device = Device(
        id: id,
        name: '${t['name']}'.trim(),
        driverId: driverId,
        host: '${t['host']}',
        port: t['port'] as int?,
        room: t['room'] as String?,
        stableId: t['stableId'] as String?,
        settings: {
          ...Map<String, Object?>.from(t['settings'] as Map? ?? const {}),
          if (driverId == nfcTagDriverId)
            'uid': ?normalizeUid((t['settings'] as Map?)?['uid']),
        },
        // A thing the import keeps on its driver keeps what it last said,
        // so its next reading is not a change that fires automations.
        state: keep ? before.state : initialThingState(driverId),
        lastSeen: keep ? before.lastSeen : null,
        favourite: t['favourite'] == true,
        order: t['order'] as int?,
      );
      sort(
        before == null
            ? add
            : canonicalJson(_thingJson(before)) ==
                  canonicalJson(_thingJson(device))
            ? same
            : changed,
        'things',
        id,
      );
      await devices.put(device);
    }

    final storedFlows = {
      for (final r in await flows.all()) '${r.json['id']}': r,
    };
    if (replace) {
      for (final id in storedFlows.keys) {
        if (plan.automations.any((a) => a['id'] == id)) continue;
        if (outside(flowHouses, id)) continue;
        await flows.remove(id);
        removed.add('automations', id);
      }
    }
    for (final a in plan.automations) {
      final id = '${a['id']}';
      final enabled = a['enabled'] != false;
      final source = '${a['source'] ?? FlowRecord.graph}';
      final spec = a['spec'] is Map
          ? Map<String, Object?>.from(a['spec'] as Map)
          : null;
      final json = {
        ...Map<String, Object?>.from(a['flow'] as Map),
        'enabled': enabled,
      };
      final before = storedFlows[id];
      sort(
        before == null
            ? add
            : canonicalJson(_automationJson(before)) ==
                  canonicalJson({
                    'id': id,
                    'source': source,
                    'enabled': enabled,
                    'flow': json,
                    'spec': ?spec,
                  })
            ? same
            : changed,
        'automations',
        id,
      );
      await flows.put(
        id,
        json,
        enabled: enabled,
        approved: false,
        at: now,
        source: source,
        spec: spec,
      );
    }

    final storedGlobals = await globals.all();
    if (replace) {
      for (final name in storedGlobals.keys) {
        if (reservedVariable(name) || plan.variables.containsKey(name)) {
          continue;
        }
        if (outside(variableHouses, name)) continue;
        await globals.remove(name);
        removed.add('variables', name);
      }
    }
    for (final MapEntry(key: name, :value) in plan.variables.entries) {
      sort(
        !storedGlobals.containsKey(name)
            ? add
            : canonicalJson({'v': storedGlobals[name]}) ==
                  canonicalJson({'v': value})
            ? same
            : changed,
        'variables',
        name,
      );
      await globals.put(name, value, now);
    }
    for (final name in plan.skippedVariables) {
      same.add('variables', name);
    }

    await _stampHouses(plan, backup);
    final here = houseLocation(_core, scope ?? _core.houses.defaultId);
    final location = plan.locationGiven
        ? plan.location
        : replace
        ? null
        : here;

    // Every automation is checked against the home the import makes: its
    // things, the other automations it runs, and the location it brings.
    final refs = await _stored.references(homeLocationSet: location != null);
    final issues = IssueCollector();
    final specs = <FlowSpec>[];
    for (var i = 0; i < plan.automations.length; i++) {
      final a = plan.automations[i];
      final id = '${a['id']}';
      try {
        final record = (await flows.get(id))!;
        final migrated = await _stored.migrateInput(
          StoredFlows.flowJsonOf(record),
        );
        final flow = FlowSpec.parse(migrated);
        _nest(issues, 'automations[$i].flow', validateFlow(flow, refs: refs));
        specs.add(flow);
        if (canonicalJson(migrated) != canonicalJson(record.json)) {
          await flows.put(
            id,
            migrated,
            enabled: record.enabled,
            approved: false,
            at: now,
          );
        }
      } on ValidationException catch (e) {
        _nest(issues, 'automations[$i].flow', e.issues);
      } on ApiError catch (e) {
        issues.add('automations[$i].flow', e.message);
      }
    }
    if (issues.hasIssues) {
      throw ApiError(
        'invalid',
        'The backup has automations that do not fit the home it makes, so '
            'nothing was imported',
        issues: issues.issues,
      );
    }

    // Approval is never restored: what is high risk waits for the user.
    final (_, allSpecs, _) = await _stored.stored();
    final risky = await _stored.highRiskFlows(allSpecs.values);
    final waiting = <String>[];
    for (final flow in specs) {
      final record = (await flows.get(flow.id))!;
      final highRisk = risky.contains(flow.id);
      if (highRisk) waiting.add(flow.id);
      await flows.put(
        flow.id,
        StoredFlows.flowJsonOf(record),
        enabled: record.enabled,
        approved: !highRisk,
        at: now,
      );
    }

    final before = here;
    final locationChange =
        canonicalJson({'l': homeLocationJson(before)}) ==
            canonicalJson({'l': homeLocationJson(location)})
        ? 'skip'
        : before == null
        ? 'add'
        : location == null
        ? 'remove'
        : 'replace';

    return {
      'add': add.toJson(),
      'replace': changed.toJson(),
      'skip': same.toJson(),
      if (replace) 'remove': removed.toJson(),
      'location': locationChange,
      'waitForApproval': waiting,
      'needsSecrets': await _needsSecrets(plan),
      '_removed': removed.of('things'),
      '_removedVariables': removed.of('variables'),
      '_changed': [...changed.of('things'), ...add.of('things')],
      '_drivers': removed.of('drivers'),
      '_location': homeLocationJson(location),
    };
  }

  /// The imported things whose secrets or pairing this engine does not
  /// hold, which the user enters again.
  Future<List<Map<String, Object?>>> _needsSecrets(_Plan plan) async {
    final out = <Map<String, Object?>>[];
    final hostKey = await _core.secrets.read(adbHostKeySecret);
    for (final t in plan.things) {
      final id = '${t['id']}';
      final manifest = _core.registry['${t['driver']}'];
      if (manifest == null) continue;
      final secrets = [
        for (final s in manifest.settings.where((s) => s.secret))
          if (await _core.secrets.read(deviceSecretKey(id, s.key)) == null)
            s.key,
      ];
      final proof = pairingProofSecret(manifest);
      final pair =
          manifest.pairingSpec != null &&
          (proof == null
              ? manifest.pairingSpec!.method == PairingMethod.adb &&
                    hostKey == null
              : await _core.secrets.read(deviceSecretKey(id, proof)) == null);
      if (secrets.isEmpty && !pair) continue;
      out.add({
        'id': id,
        'name': t['name'],
        if (secrets.isNotEmpty) 'secrets': secrets,
        if (pair) 'pair': true,
      });
    }
    return out;
  }

  /// What the engine holds besides the database catches up with an
  /// applied import.
  Future<void> _settle(_Plan plan, _Held held, {required bool replace}) async {
    for (final id in held.removedDrivers) {
      _core.registry.unregister(id);
    }
    await _core.loadRooms();
    if (replace && _scope == null) {
      _core.flows.globals.removeWhere((k, _) => !reservedVariable(k));
    } else if (replace) {
      held.removedVariables.forEach(_core.flows.globals.remove);
    }
    _core.flows.globals.addAll(plan.variables);
    for (final id in held.removedThings) {
      await removeThing(id);
    }
    for (final d in await DriftDeviceStore(_db).all()) {
      _core.flows.deviceStates[d.id] = d.state;
      if (held.changedThings.contains(d.id)) resetThing(d.id);
    }
    await _things.reload(quiet: true);
    await _home.apply(held.location, house: _scope);
  }
}

/// What [BackupCommands._write] passes on for after the commit, taken out
/// of its report.
class _Held {
  _Held(Map<String, Object?> report)
    : removedThings = (report.remove('_removed') as List).cast<String>(),
      changedThings = (report.remove('_changed') as List).cast<String>(),
      removedDrivers = (report.remove('_drivers') as List).cast<String>(),
      removedVariables = (report.remove('_removedVariables') as List)
          .cast<String>(),
      location = homeLocationOf(report.remove('_location'));

  final List<String> removedThings;
  final List<String> changedThings;
  final List<String> removedDrivers;
  final List<String> removedVariables;
  final HomeLocation? location;
}

class _Plan {
  const _Plan({
    required this.drivers,
    required this.rooms,
    required this.things,
    required this.automations,
    required this.variables,
    required this.skippedVariables,
    required this.location,
    required this.locationGiven,
  });

  final List<Map<String, Object?>> drivers;
  final List<Map<String, Object?>> rooms;
  final List<Map<String, Object?>> things;
  final List<Map<String, Object?>> automations;
  final Map<String, Object?> variables;
  final List<String> skippedVariables;
  final HomeLocation? location;
  final bool locationGiven;
}

/// Ids by kind, for the import report.
class _Changes {
  final _ids = <String, List<String>>{};

  void add(String kind, String id) => _ids.putIfAbsent(kind, () => []).add(id);

  List<String> of(String kind) => _ids[kind] ?? const [];

  Map<String, Object?> toJson() => {
    for (final e in _ids.entries) e.key: e.value,
  };
}

/// Ends a dry run's transaction, so nothing it wrote stays.
class _Rollback implements Exception {
  const _Rollback(this.report);

  final Map<String, Object?> report;
}
