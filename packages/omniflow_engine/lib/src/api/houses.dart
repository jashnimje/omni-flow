import 'dart:async';

import 'package:drift/drift.dart' show Variable;

import 'agent_policy.dart' show agentReadCommands;
import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'house_things.dart' show houseIdOf;
import 'hub_phone_session.dart' show isPhoneReading;
import 'presence_view.dart' show housePresence;
import 'things_runtime.dart'
    show defaultHomePlace, personDriverId, phoneDriverId;
import '../devices/device.dart';
import '../storage/database.dart';

/// The house every home starts with, and the one a home made before houses
/// becomes. Its settings stay where they were: the top-level keys of
/// `home.json` and the settings files with no house in their name.
const firstHouseId = 'home';
const firstHouseName = 'Home';

/// The longest house name.
const houseNameMax = 40;

/// The most houses one engine keeps.
const houseMax = 10;

/// Sent when a house is added, renamed or removed, with the list.
const housesChangedEvent = 'house.changed';

/// Sent when a person arrives at a place of a house: `{person, house}`, so
/// the app can switch its view to that house.
const houseArrivedEvent = 'house.arrived';

/// The id a built-in thing (the house mode, the timers) has for the flows
/// of [house]. The first house keeps the plain id, so a home made before
/// houses runs as it did.
String houseThingId(String thing, String house) =>
    house == firstHouseId ? thing : '${thing}__$house';

/// The built-in thing and the house a runtime id from [houseThingId] names,
/// or null for any other id.
(String thing, String house)? houseThingOf(String id, Iterable<String> things) {
  for (final t in things) {
    if (id == t) return (t, firstHouseId);
    if (id.startsWith('${t}__') && id.length > t.length + 2) {
      return (t, id.substring(t.length + 2));
    }
  }
  return null;
}

class House {
  const House({required this.id, required this.name, required this.order});

  final String id;
  final String name;
  final int order;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'order': order};
}

/// What carries a `house`, by table: things, rooms, automations (with
/// scenes and links) and the variables set by hand.
enum HouseKind {
  thing('devices', 'id'),
  room('rooms', 'id'),
  flow('flows', 'id'),
  variable('global_variables', 'name');

  const HouseKind(this.table, this.key);

  final String table;
  final String key;
}

/// What each list command lists, by the reply key, the kind of record each
/// entry is, and the entry field holding its id. Given `house`, the list
/// keeps that house's entries and the shared ones (people and phones);
/// without it every entry comes back. Either way each entry says its house.
const houseLists = <String, (String, HouseKind, String)>{
  'device.list': ('devices', HouseKind.thing, 'id'),
  'tag.list': ('tags', HouseKind.thing, 'id'),
  'zone.list': ('zones', HouseKind.thing, 'place'),
  'room.list': ('rooms', HouseKind.room, 'id'),
  'automation.list': ('automations', HouseKind.flow, 'id'),
  'flow.list': ('flows', HouseKind.flow, 'id'),
  'scene.list': ('scenes', HouseKind.flow, 'id'),
  'link.list': ('links', HouseKind.flow, 'id'),
};

/// The commands that save an automation, a scene or a link, which may only
/// name things of their own house.
const houseSaveCommands = {
  'automation.save',
  'flow.save',
  'scene.save',
  'scene.capture',
  'link.create',
};

/// The commands whose `house` is the house in view: the lists above and the
/// commands that make something, which put it in that house. The CLI passes
/// its own house choice to these, and an agent may give one.
const houseViewCommands = {
  ...houseListKeys,
  ...houseSaveCommands,
  'var.list',
  'var.set',
  'timer.list',
  'timer.start',
  'device.add',
  'thing.add',
  'wiz.import',
  'room.save',
  'zone.save',
  'tag.save',
  'weather.add',
  'suggest.list',
  'home.stats',
  'rule.parse',
  'rule.tokens',
  'command.interpret',
  'automation.diagram',
  'energy.summary',
  'rule.words',
  'automation.removed',
  'timer.cancel',
  'timer.pause',
  'timer.resume',
  // Each house's own settings.
  'home.mode',
  'home.mode.set',
  'home.location',
  'home.location.set',
  'alerts.get',
  'alerts.set',
  'energy.price',
  'energy.price.set',
  'awaylight.get',
  'awaylight.set',
  'awaylight.preview',
  'sunlight.get',
  'sunlight.set',
  'sunlight.apply',
};

/// The list command names, for [houseViewCommands].
const houseListKeys = {
  'device.list',
  'tag.list',
  'zone.list',
  'room.list',
  'automation.list',
  'flow.list',
  'scene.list',
  'link.list',
};

/// The keys of a saved rule, scene, link or flow whose text names a thing:
/// the thing itself, or `thing.key`.
const _thingKeys = {
  // Rule and scene shorthand: `lamp.power=true`, `lamp.power`.
  'actions',
  'when',
  'then',
  'onlyIf',
  'deviceId',
  'thing',
  'on',
  'state',
  'do',
  'target',
  'toggle',
  'from',
  'to',
  'place',
  'tag',
  'device',
  'things',
  'devices',
};

/// The houses, each item's house, and the house view every list and save
/// command takes. There is no house the engine is "in": each client passes
/// the house it shows, and a command without one works on every house (a
/// list) or the first house (a save).
class Houses {
  Houses(this._core);

  final EngineCore _core;

  OmniDatabase get _db => _core.db;

  var _houses = <House>[];

  /// Each thing's house by id, for code that reacts to events and must not
  /// read the database for each one. People and phones are not in it.
  final thingHouses = <String, String>{};

  /// Each stored automation's house by id, refreshed as flows load.
  final flowHouses = <String, String>{};

  /// The household person, for an arrival reading that names nobody.
  Future<String?> Function()? householdPerson;

  /// Reloads the running flows after a move turned some off.
  Future<void> Function()? reloadFlows;

  StreamSubscription<Map<String, Object?>>? _sub;

  List<House> get all => List.unmodifiable(_houses);

  /// The first house in the list: where a save with no house goes.
  String get defaultId => _houses.isEmpty ? firstHouseId : _houses.first.id;

  House? byId(String id) => _houses.where((h) => h.id == id).firstOrNull;

  String nameOf(String id) => byId(id)?.name ?? id;

  /// Opens the houses: the migration first, then the list and the
  /// arrivals.
  Future<void> open() async {
    await houseMigration(_db);
    await load();
    _sub = _core.events.listen(_observe);
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> load() async {
    _houses = [
      for (final r
          in await _db
              .customSelect(
                'SELECT id, name, position FROM houses '
                'ORDER BY position, name',
              )
              .get())
        House(
          id: r.read<String>('id'),
          name: r.read<String>('name'),
          order: r.read<int>('position'),
        ),
    ];
    thingHouses
      ..clear()
      ..addAll(await housesOf(HouseKind.thing));
    flowHouses
      ..clear()
      ..addAll(await housesOf(HouseKind.flow));
  }

  /// The house [arg] names, by id or by name in any case. Null for null.
  String? resolve(Object? arg) {
    if (arg == null) return null;
    if (arg is! String || arg.trim().isEmpty) {
      throw ApiError('invalid', 'house must be a house id');
    }
    final text = arg.trim();
    final match =
        byId(text) ??
        _houses
            .where((h) => h.name.toLowerCase() == text.toLowerCase())
            .firstOrNull;
    if (match == null) {
      throw ApiError(
        'not_found',
        'There is no house $text. The houses are '
            '${_houses.map((h) => '${h.name} (${h.id})').join(', ')}',
      );
    }
    return match.id;
  }

  static const _zoneKey = #omniflowHouse;

  /// The house the running command names, or null when it names none.
  String? get commandHouse => Zone.current[_zoneKey] as String?;

  /// The house of [args]' `house`, or the first house.
  String target(Map<String, Object?> args) =>
      resolve(args['house']) ?? defaultId;

  /// Every record of [kind] that has a house, with it.
  Future<Map<String, String>> housesOf(HouseKind kind) async => {
    for (final r
        in await _db
            .customSelect(
              'SELECT ${kind.key} AS id, house FROM ${kind.table} '
              'WHERE house IS NOT NULL',
            )
            .get())
      r.read<String>('id'): r.read<String>('house'),
  };

  Future<String?> houseOf(HouseKind kind, String id) async {
    final row = await _db
        .customSelect(
          'SELECT house FROM ${kind.table} WHERE ${kind.key} = ?',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    return row?.read<String?>('house');
  }

  Future<void> put(HouseKind kind, String id, String house) async {
    await _db.customStatement(
      'UPDATE ${kind.table} SET house = ? WHERE ${kind.key} = ?',
      [house, id],
    );
    if (kind == HouseKind.thing) thingHouses[id] = house;
    if (kind == HouseKind.flow) flowHouses[id] = house;
  }

  /// Puts what was made since the last command and has no house yet in
  /// [house]: a thing (not a person or a phone), a room or an automation.
  /// Every maker of a record goes through a command, so stamping after each
  /// command covers them all without each knowing about houses.
  /// Returns whether an automation got its house.
  Future<bool> adopt(String house) async {
    var flows = false;
    for (final kind in const [
      HouseKind.thing,
      HouseKind.room,
      HouseKind.flow,
    ]) {
      final unhoused = await _db
          .customSelect(
            'SELECT ${kind.key} AS id FROM ${kind.table} WHERE house IS NULL'
            '${kind == HouseKind.thing ? _sharedThings : ''}',
          )
          .get();
      if (unhoused.isEmpty) continue;
      if (kind == HouseKind.flow) flows = true;
      await _db.customStatement(
        'UPDATE ${kind.table} SET house = ? WHERE house IS NULL'
        '${kind == HouseKind.thing ? _sharedThings : ''}',
        [house],
      );
      for (final r in unhoused) {
        final id = r.read<String>('id');
        if (kind == HouseKind.thing) thingHouses[id] = house;
        if (kind == HouseKind.flow) flowHouses[id] = house;
      }
    }
    return flows;
  }

  /// Whether [command] can make a thing, a room or an automation. A read,
  /// a phone's reading and a command to a device make none, so they skip
  /// the stamping and answer as fast as before.
  static bool _mayMake(String command) =>
      !agentReadCommands.contains(command) &&
      !isPhoneReading(command) &&
      !command.startsWith('tv.') &&
      !command.startsWith('android.') &&
      !_controls.contains(command);

  static const _controls = {
    'device.invoke',
    'device.refresh',
    'room.invoke',
    'automation.run',
    'scene.run',
    'flow.run',
    'flow.dryRun',
    'automation.dry_run',
  };

  static const _sharedThings =
      " AND driver_id NOT IN ('$personDriverId', '$phoneDriverId')";

  /// Whether [person] is at [house]. In the house of their home place it is
  /// their `home`, as before houses, so being at the office counts as out.
  /// In any other house, being at one of its places counts as in.
  bool personIn(Device person, String house) {
    if (homeHouseOf(person) == house) return person.state['home'] == true;
    final place = person.state['place'];
    return place is String && thingHouses[place] == house;
  }

  /// The house of [person]'s home place, the first house when it has none.
  String homeHouseOf(Device person) {
    final homePlace = person.settings['homePlace'];
    return thingHouses[homePlace is String && homePlace.isNotEmpty
            ? homePlace
            : defaultHomePlace] ??
        defaultId;
  }

  /// Whether the thing [id] shows in [house]: it is in it, or it is shared
  /// (a person, a phone, or one with no house yet).
  bool thingIn(String id, String house) {
    final h = thingHouses[id];
    return h == null || h == house;
  }

  // ---------------------------------------------------------------- commands

  Map<String, CommandHandler> get commands => {
    'house.list': list,
    'house.add': add,
    'house.rename': rename,
    'house.remove': remove,
  };

  Future<Map<String, Object?>> list(Map<String, Object?> _) async {
    final things = await _counts(HouseKind.thing);
    final flows = await _counts(HouseKind.flow);
    final devices = await DriftDeviceStore(_db).all();
    final who = await householdPerson?.call();
    final person = devices.where((d) => d.id == who).firstOrNull;
    return {
      'houses': [
        for (final h in _houses)
          {
            ...h.toJson(),
            'things': things[h.id] ?? 0,
            'automations': flows[h.id] ?? 0,
            if (person != null)
              'presence': housePresence(person, devices, this, h.id),
          },
      ],
    };
  }

  Future<Map<String, int>> _counts(HouseKind kind) async => {
    for (final r
        in await _db
            .customSelect(
              'SELECT house, COUNT(*) AS n FROM ${kind.table} '
              'WHERE house IS NOT NULL GROUP BY house',
            )
            .get())
      r.read<String>('house'): r.read<int>('n'),
  };

  String _name(Map<String, Object?> args) {
    final name = stringArg(args, 'name').trim();
    if (name.isEmpty || name.length > houseNameMax) {
      throw ApiError('invalid', 'a house name is 1 to $houseNameMax letters');
    }
    return name;
  }

  void _nameFree(String name, {String? except}) {
    final same = _houses
        .where(
          (h) => h.id != except && h.name.toLowerCase() == name.toLowerCase(),
        )
        .firstOrNull;
    if (same != null) {
      throw ApiError('exists', 'There is already a house called ${same.name}');
    }
  }

  /// `{name, id?}`: adds a house at the end of the list.
  Future<Map<String, Object?>> add(Map<String, Object?> args) async {
    final name = _name(args);
    _nameFree(name);
    if (_houses.length >= houseMax) {
      throw ApiError('invalid', 'A home has at most $houseMax houses');
    }
    final wanted = optStringArg(args, 'id');
    if (wanted != null && !RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch(wanted)) {
      throw ApiError('invalid', 'a house id is lower snake case, like mumbai');
    }
    if (wanted != null && byId(wanted) != null) {
      throw ApiError('exists', 'There is already a house with the id $wanted');
    }
    final base = wanted ?? houseIdOf(name) ?? 'house';
    var id = base;
    for (var n = 2; byId(id) != null; n++) {
      id = '${base}_$n';
    }
    final order = _houses.isEmpty ? 0 : _houses.last.order + 1;
    await _db.customStatement(
      'INSERT INTO houses (id, name, position) VALUES (?, ?, ?)',
      [id, name, order],
    );
    await load();
    _changed();
    return {'house': byId(id)!.toJson()};
  }

  /// `{id, name}`.
  Future<Map<String, Object?>> rename(Map<String, Object?> args) async {
    final id = resolve(stringArg(args, 'id'))!;
    final name = _name(args);
    _nameFree(name, except: id);
    await _db.customStatement('UPDATE houses SET name = ? WHERE id = ?', [
      name,
      id,
    ]);
    await load();
    _changed();
    return {'house': byId(id)!.toJson()};
  }

  /// `{id}`: removes an empty house. Its rooms go with it, and the
  /// variables set in it are kept for every house.
  Future<Map<String, Object?>> remove(Map<String, Object?> args) async {
    final id = resolve(stringArg(args, 'id'))!;
    final name = nameOf(id);
    if (_houses.length == 1) {
      throw ApiError(
        'invalid',
        '$name is the only house. A home needs at least one, so add another '
            'before removing it',
      );
    }
    final things = (await _counts(HouseKind.thing))[id] ?? 0;
    final flows = (await _counts(HouseKind.flow))[id] ?? 0;
    if (things > 0 || flows > 0) {
      final held = [
        if (things > 0) _count(things, 'thing'),
        if (flows > 0) _count(flows, 'automation'),
      ].join(' and ');
      throw ApiError(
        'invalid',
        '$name still has $held. Move them to another house or remove them '
            'first',
      );
    }
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM rooms WHERE house = ?', [id]);
      await _db.customStatement(
        'UPDATE global_variables SET house = NULL WHERE house = ?',
        [id],
      );
      await _db.customStatement('DELETE FROM houses WHERE id = ?', [id]);
    });
    await _core.loadRooms();
    await load();
    _changed(removed: id);
    return {'removed': id};
  }

  static String _count(int n, String what) => '$n $what${n == 1 ? '' : 's'}';

  void _changed({String? removed}) => _core.emit({
    'event': housesChangedEvent,
    'houses': [for (final h in _houses) h.toJson()],
    'removed': ?removed,
  });

  // ------------------------------------------------------------ the scope

  /// Runs [command] in the house its `house` argument names: refuses a save
  /// that names a thing of another house, puts what the command made in
  /// the house, and keeps a list to that house with each entry's house.
  Future<Map<String, Object?>> scoped(
    String command,
    Map<String, Object?> args,
    CommandHandler handler,
  ) async {
    final view = resolve(args['house']);
    var inner = args;
    if (view != null) inner = {...args, 'house': view};
    String? saveTarget;
    String? moveTo;
    if (houseSaveCommands.contains(command)) {
      moveTo = resolve(args['moveTo']);
      inner = {...inner}..remove('moveTo');
      saveTarget = moveTo ?? await _saveTarget(args, view);
      await checkNames(inner, saveTarget);
    } else if (view != null && _readsOneHouse.contains(command)) {
      await _checkInView(inner, view);
    }
    // Code deep in a command (a room named on device.add) reads the house
    // from the zone rather than through every call between.
    final result = await runZoned(
      () => handler(inner),
      zoneValues: {_zoneKey: saveTarget ?? view},
    );
    final into = saveTarget ?? view ?? defaultId;
    var placed = _mayMake(command) && await adopt(into);
    final saved = result['id'];
    // A save over an automation keeps its house: only moveTo moves it.
    if (saved is String &&
        saveTarget != null &&
        flowHouses[saved] != saveTarget &&
        (moveTo != null || flowHouses[saved] == null)) {
      await put(HouseKind.flow, saved, saveTarget);
      placed = true;
    }
    // The flow loaded before it had a house, so it runs again as its own
    // house's: that house's mode, timers and location.
    if (placed && into != firstHouseId) await reloadFlows?.call();
    if (command == 'var.set' && result['name'] is String) {
      await put(
        HouseKind.variable,
        result['name'] as String,
        view ?? defaultId,
      );
    }
    final spec = houseLists[command];
    if (spec != null) return _filtered(result, spec, view);
    if (command == 'var.list') return _variables(result, view);
    if (command == 'device.get') return _withHouse(result, 'device');
    if (_flowReads.contains(command) && args['id'] is String) {
      return {...result, 'house': ?flowHouses[args['id']]};
    }
    return result;
  }

  /// The reads of one automation, which say its house.
  static const _flowReads = {'automation.get', 'flow.get'};

  /// The commands that read one automation or an unsaved rule, which in a
  /// house may only name that house's things and automations.
  static const _readsOneHouse = {
    'rule.tokens',
    'rule.words',
    'automation.diagram',
  };

  /// A stored automation is read in its own house, whatever the view, and
  /// an unsaved rule in the house in view.
  Future<void> _checkInView(Map<String, Object?> args, String view) async {
    final id = args['id'];
    final house = id is String ? flowHouses[id] : null;
    await checkNames(args, house != null && byId(house) != null ? house : view);
  }

  /// The house a save goes to: the house of the automation it saves over,
  /// whatever house the client shows now (its view may have moved on by
  /// arrival while the automation was open), else the house given, else
  /// the first house. `moveTo` is the one way to move a saved automation.
  Future<String> _saveTarget(Map<String, Object?> args, String? view) async {
    final id = args['id'];
    if (id is String) {
      final house = await houseOf(HouseKind.flow, id);
      if (house != null && byId(house) != null) return house;
    }
    return view ?? defaultId;
  }

  /// Refuses [args] when they name a thing of a house other than [house]:
  /// "Desk lamp is in Bangalore, not Mumbai".
  Future<void> checkNames(Map<String, Object?> args, String house) async {
    final named = <String>{};
    void walk(Object? value, String? key) {
      switch (value) {
        case Map m:
          for (final e in m.entries) {
            walk(e.value, '${e.key}');
          }
        case List l:
          for (final v in l) {
            walk(v, key);
          }
        case String s when key != null && _thingKeys.contains(key):
          named.add(s);
          final dot = s.indexOf('.');
          if (dot > 0) named.add(s.substring(0, dot));
      }
    }

    walk(args, null);
    for (final id in named) {
      final other = thingHouses[id];
      if (other == null || other == house || byId(other) == null) continue;
      final device = await DriftDeviceStore(_db).get(id);
      throw ApiError(
        'invalid',
        '${device?.name ?? id} is in ${nameOf(other)}, not ${nameOf(house)}. '
            'An automation, scene or link can only use things of its own '
            'house',
      );
    }
  }

  Future<Map<String, Object?>> _filtered(
    Map<String, Object?> result,
    (String, HouseKind, String) spec,
    String? view,
  ) async {
    final (key, kind, idField) = spec;
    final items = result[key];
    if (items is! List) return result;
    final houses = kind == HouseKind.thing ? thingHouses : await housesOf(kind);
    final kept = <Object?>[];
    for (final item in items) {
      if (item is! Map) {
        kept.add(item);
        continue;
      }
      final house = houses[item[idField]];
      if (view != null && house != null && house != view) continue;
      kept.add(<String, Object?>{...item, 'house': ?house});
    }
    return {...result, key: kept};
  }

  Future<Map<String, Object?>> _variables(
    Map<String, Object?> result,
    String? view,
  ) async {
    final vars = result['variables'];
    if (view == null || vars is! Map) return result;
    final houses = await housesOf(HouseKind.variable);
    return {
      ...result,
      'variables': {
        for (final e in vars.entries)
          if (houses[e.key] == null || houses[e.key] == view) e.key: e.value,
      },
    };
  }

  Map<String, Object?> _withHouse(Map<String, Object?> result, String key) {
    final item = result[key];
    if (item is! Map) return result;
    return {
      ...result,
      key: <String, Object?>{...item, 'house': ?thingHouses[item['id']]},
    };
  }

  // ------------------------------------------------------------- moving

  /// Moves the thing [id] to [house]. Its room stays only when it is in
  /// that house, and every enabled automation of the old house that uses
  /// it is turned off, as removing the thing does. Returns their ids.
  Future<List<String>> moveThing(String id, String house) async {
    final from = thingHouses[id];
    if (from == house) return const [];
    final device = await _core.device(id);
    if (device.driverId == personDriverId || device.driverId == phoneDriverId) {
      throw ApiError(
        'invalid',
        '${device.name} is shared by every house, so it does not move',
      );
    }
    final room = device.room;
    if (room != null && await houseOf(HouseKind.room, room) != house) {
      await _core.devices.updateDevice(
        id,
        (d) => d.placed(room: null, order: d.order),
      );
    }
    await put(HouseKind.thing, id, house);
    final off = <String>[];
    final flows = DriftFlowStore(_db);
    for (final r in await flows.all()) {
      final flowId = '${r.json['id']}';
      if (!r.enabled || flowHouses[flowId] == house) continue;
      if (!_mentions(r.json['nodes'], id)) continue;
      await flows.put(
        flowId,
        {...r.json, 'enabled': false},
        enabled: false,
        approved: r.approved,
        trusted: r.trusted,
        at: DateTime.now().toUtc(),
      );
      off.add(flowId);
    }
    if (off.isNotEmpty) await reloadFlows?.call();
    for (final f in off) {
      _core.emit({
        'event': 'automation.changed',
        'command': 'device.organize',
        'id': f,
      });
    }
    _core.emit({
      'event': 'house.thingMoved',
      'thing': id,
      'from': ?from,
      'house': house,
      'turnedOff': off,
    });
    return off;
  }

  static bool _mentions(Object? value, String id) => switch (value) {
    Map m =>
      m['deviceId'] == id ||
          m['thing'] == id ||
          (m['state'] is String && (m['state'] as String).startsWith('$id.')) ||
          m.values.any((v) => _mentions(v, id)),
    List l => l.any((v) => _mentions(v, id)),
    _ => false,
  };

  // ----------------------------------------------------------- arrivals

  void _observe(Map<String, Object?> e) {
    if (e['event'] != 'zone.changed' || e['transition'] != 'entered') return;
    final place = e['place'];
    final house = place is String ? thingHouses[place] : null;
    if (house == null) return;
    _core.track(_arrived(e['person'], house));
  }

  Future<void> _arrived(Object? person, String house) async {
    final who = person is String ? person : await householdPerson?.call();
    _core.emit({
      'event': houseArrivedEvent,
      'person': ?who,
      'house': house,
      'name': nameOf(house),
    });
  }
}

/// Makes the first house and puts every record in it, once: on the first
/// open of a home made before houses, and of a new home. One transaction,
/// and a home that already has a house is left as it is.
Future<bool> houseMigration(OmniDatabase db) => db.transaction(() async {
  final any = await db.customSelect('SELECT 1 FROM houses LIMIT 1').get();
  if (any.isNotEmpty) return false;
  await db.customStatement(
    'INSERT INTO houses (id, name, position) VALUES (?, ?, 0)',
    [firstHouseId, firstHouseName],
  );
  await db.customStatement(
    'UPDATE devices SET house = ? WHERE house IS NULL'
    "${Houses._sharedThings}",
    [firstHouseId],
  );
  for (final table in const ['rooms', 'flows', 'global_variables']) {
    await db.customStatement(
      'UPDATE $table SET house = ? WHERE house IS NULL',
      [firstHouseId],
    );
  }
  return true;
});
