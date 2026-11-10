import 'api_error.dart';
import 'engine_core.dart';
import '../dag/conditions.dart';
import '../devices/device.dart';
import '../storage/database.dart';
import '../zones/zones.dart';

export 'nfc_tags.dart' show nfcTagDriverId, normalizeUid;

/// The driver ids of the built-in virtual things.
const phoneDriverId = 'phone';
const personDriverId = 'person';
const placeDriverId = 'place';

/// The phone the app's inputs feed when they name none.
const defaultPhoneId = 'phone';

/// The place a person counts as home when their `homePlace` is not set.
const defaultHomePlace = 'home';

const virtualHost = 'virtual';

/// The zone id a place answers to: the zone it was made from, or its own id.
String zoneIdOf(Device place) {
  final zone = place.settings['zone'];
  return zone is String && zone.isNotEmpty ? zone : place.id;
}

/// The zone a place's settings define, under the place's own id.
ZoneSpec zoneOfPlace(Device place) => ZoneSpec.parse({
  'id': place.id,
  'name': place.name,
  'ble': ?place.settings['ble'],
  'wifi': ?place.settings['wifi'],
}, requireInput: false);

/// What last decided whether the household person is home, as the person
/// thing reports it in `homeSource`. `hub` is a hub that sees the phone,
/// which no input reports yet.
const presenceSources = ['wifi', 'ble', 'hub', 'manual'];

/// The state a new virtual thing starts with, so its first real reading is
/// a change and not the first time the key appears.
Map<String, Object?> initialThingState(String driverId) => switch (driverId) {
  placeDriverId => const {'inside': false, 'people': <String>[]},
  personDriverId => const {'home': false, 'place': null},
  _ => const {},
};

/// The phone, the people, the places and the NFC tags. Their state comes
/// from the phone's inputs: Wi-Fi and BLE readings place the household
/// person in places, and an NFC scan raises events on the phone and the
/// tag. A place is today's zone, so `$Zone_<id>` and `zone.changed` stay.
class ThingsRuntime {
  ThingsRuntime(this._core);

  final EngineCore _core;

  /// Whether the household person is inside each place, by place id.
  final zones = ZoneTracker(const []);

  var _places = <String, Device>{};

  /// Places the household person is inside, oldest entry first, so their
  /// `place` is the one they reached last.
  final _entered = <String>[];

  DriftDeviceStore get _store => DriftDeviceStore(_core.db);

  Future<List<Device>> _ofDriver(String driver) async => [
    for (final d in await _store.all())
      if (d.driverId == driver) d,
  ];

  /// Moves every stored zone into a place thing, once. A zone whose id a
  /// device already has becomes `<id>_place` and keeps answering to the
  /// zone id. A zone that does not parse stays a load issue.
  Future<void> migrateZoneRows() async {
    final rows = DriftZoneStore(_core.db);
    final issues = <Map<String, Object?>>[];
    for (final row in await rows.all()) {
      final id = row['id'];
      try {
        final zone = ZoneSpec.parse(row);
        final places = await _ofDriver(placeDriverId);
        if (!places.any((p) => zoneIdOf(p) == zone.id)) {
          final placeId = await _freePlaceId(zone.id);
          await _store.put(_place(placeId, zone, zoneId: zone.id));
        }
        await rows.remove(zone.id);
      } catch (e) {
        issues.add(loadIssue('zone', id, e));
      }
    }
    _core.setIssues('zone', issues);
  }

  /// The id a new place for [zoneId] takes: the zone id, or `<id>_place`
  /// (then `_place_2` and on) when a thing already has it.
  Future<String> _freePlaceId(String zoneId) async {
    var placeId = zoneId;
    for (var n = 1; await _store.get(placeId) != null; n++) {
      placeId = n == 1 ? '${zoneId}_place' : '${zoneId}_place_$n';
    }
    return placeId;
  }

  static Device _place(
    String id,
    ZoneSpec zone, {
    String? zoneId,
    Map<String, Object?>? state,
  }) {
    final json = zone.toJson();
    return Device(
      id: id,
      name: zone.name,
      driverId: placeDriverId,
      host: virtualHost,
      settings: {
        'ble': ?json['ble'],
        'wifi': ?json['wifi'],
        if (zoneId != null && zoneId != id) 'zone': zoneId,
      },
      state: state ?? initialThingState(placeDriverId),
    );
  }

  /// Rebuilds the zone tracker from the place things. A place whose inputs
  /// did not change keeps whether it is inside, and a renamed place is not
  /// rebuilt at all. A new or edited place is checked against the last Wi-Fi
  /// reading at once. Where that moves a place in or out, the new
  /// state is written without a state change or `zone.changed`: the person
  /// did not move, so no exit or entry trigger may fire. [quiet] does the
  /// same for every state, for the engine opening, where places start
  /// outside and a remembered inside from before must not fire exit triggers.
  Future<void> reload({bool quiet = false}) async {
    final places = await _ofDriver(placeDriverId);
    final specs = <ZoneSpec>[];
    final issues = <Map<String, Object?>>[];
    for (final p in places) {
      try {
        specs.add(_trackedZone(p));
      } catch (e) {
        issues.add(loadIssue('place', p.id, e));
      }
    }
    final before = {for (final id in _places.keys) id: zones.isInside(id)};
    _places = {for (final p in places) p.id: p};
    zones.update(specs);
    if (_lastWifi case final w?) zones.wifi(w.ssid, w.bssid, w.at);
    _entered.removeWhere((id) => !zones.isInside(id));
    final edited = <String>{};
    for (final place in _places.values) {
      final inside = zones.isInside(place.id);
      if (inside && !_entered.contains(place.id)) _entered.add(place.id);
      if ((before[place.id] ?? false) == inside) continue;
      edited.add(place.id);
      await _core.flows.setGlobal('Zone_${zoneIdOf(place)}', inside);
    }
    _core.setIssues('place', issues);
    await _sync(quiet: quiet, quietPlaces: edited);
  }

  /// The zone the tracker follows for [place]. The name stays out, so a
  /// rename does not reset a beacon's presence.
  static ZoneSpec _trackedZone(Device place) => ZoneSpec.parse({
    'id': place.id,
    'ble': ?place.settings['ble'],
    'wifi': ?place.settings['wifi'],
  }, requireInput: false);

  ({String? ssid, String? bssid, DateTime at})? _lastWifi;

  /// The input behind the readings being applied now, one of
  /// [presenceSources].
  String? _source;

  /// The person whose phone this engine reads: the one a phone names in
  /// its `person` setting, or the only person when there is one.
  Future<String?> householdPerson() async {
    final people = {for (final p in await _ofDriver(personDriverId)) p.id};
    final phones = await _ofDriver(phoneDriverId)
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final phone in phones) {
      final person = phone.settings['person'];
      if (person is String && people.contains(person)) return person;
    }
    return people.length == 1 ? people.single : null;
  }

  /// Writes each place's `inside` and `people`, and the household person's
  /// `home` and `place`, where they differ from what the tracker says.
  Future<void> _sync({
    bool quiet = false,
    Set<String> quietPlaces = const {},
  }) async {
    final person = await householdPerson();
    for (final place in _places.values) {
      final inside = zones.isInside(place.id);
      await _merge(place.id, {
        'inside': inside,
        'people': [if (inside && person != null) person],
      }, quiet: quiet || quietPlaces.contains(place.id));
    }
    if (person == null) return;
    final device = await _store.get(person);
    if (device == null) return;
    final home = device.settings['homePlace'];
    final homeZone = home is String && home.isNotEmpty
        ? home
        : defaultHomePlace;
    final homePlace = _places.values
        .where((p) => p.id == homeZone || zoneIdOf(p) == homeZone)
        .firstOrNull;
    final isHome = homePlace != null && zones.isInside(homePlace.id);
    await _merge(person, {
      'home': isHome,
      'place': _entered.lastOrNull,
      ..._presenceChange(device, isHome),
    }, quiet: quiet || quietPlaces.isNotEmpty);
  }

  /// `homeSource` and `homeSince` when [home] is a change for [person].
  Map<String, Object?> _presenceChange(Device person, bool home) =>
      valuesEqual(person.state['home'], home)
      ? const {}
      : {
          'homeSince': DateTime.now().toUtc().toIso8601String(),
          'homeSource': ?_source,
        };

  /// Sets whether [personId] (the household person when null) is home, as
  /// the user says. The next reading that moves them in or out of their
  /// home place decides again.
  Future<Map<String, Object?>> setHome(bool home, {String? personId}) async {
    final id =
        personId ??
        await householdPerson() ??
        (throw ApiError('not_found', 'no household person: add one first'));
    final person = await _store.get(id);
    if (person == null || person.driverId != personDriverId) {
      throw ApiError('not_found', 'no person $id');
    }
    final previous = _source;
    _source = 'manual';
    try {
      await _merge(id, {'home': home, ..._presenceChange(person, home)});
    } finally {
      _source = previous;
    }
    return (await _store.get(id))!.state;
  }

  Future<void> _merge(
    String id,
    Map<String, Object?> values, {
    bool quiet = false,
  }) async {
    final device = await _store.get(id);
    if (device == null) return;
    final current = device.state;
    if (values.entries.every((e) => valuesEqual(current[e.key], e.value)) &&
        values.keys.every(current.containsKey)) {
      return;
    }
    if (quiet) {
      await _store.put(device.copyWith(state: {...current, ...values}));
    } else {
      await _core.devices.mergeState(id, values);
    }
  }

  Future<void> _apply(List<ZoneChange> changes) async {
    for (final c in changes) {
      final place = _places[c.zoneId];
      final zone = place == null ? c.zoneId : zoneIdOf(place);
      final inside = c.transition == ZoneTransition.entered;
      _entered.remove(c.zoneId);
      if (inside) _entered.add(c.zoneId);
      await _core.flows.setGlobal('Zone_$zone', inside);
      _core.emit({
        'event': 'zone.changed',
        ...c.toJson(),
        'zone': zone,
        'place': c.zoneId,
      });
    }
    if (changes.isNotEmpty) await _sync();
  }

  /// The phone thing [id], or the default phone, made on first use.
  Future<Device> phone([String? id]) async {
    final want = id ?? defaultPhoneId;
    final existing = await _store.get(want);
    if (existing != null) {
      if (existing.driverId != phoneDriverId) {
        throw ApiError('invalid', '$want is not a phone');
      }
      return existing;
    }
    if (id != null && id != defaultPhoneId) {
      throw ApiError('not_found', 'no phone $id');
    }
    final made = const Device(
      id: defaultPhoneId,
      name: 'Phone',
      driverId: phoneDriverId,
      host: virtualHost,
    );
    await _store.put(made);
    return made;
  }

  /// The phone's Wi-Fi. Keeps `$WifiSsid` and `$HomeWifiConnected` (the
  /// SSID is in the global `$HomeSsids` list) current, and the places.
  Future<void> wifi(
    String? ssid,
    String? bssid,
    DateTime at, {
    String? phoneId,
  }) async {
    final device = await phone(phoneId);
    final homes = _core.flows.globals['HomeSsids'];
    await _core.flows.setGlobal('WifiSsid', ssid);
    await _core.flows.setGlobal(
      'HomeWifiConnected',
      ssid != null && homes is List && homes.contains(ssid),
    );
    _core.emit({'event': 'wifi.changed', 'ssid': ssid, 'bssid': bssid});
    await _merge(device.id, {'wifi_ssid': ssid, 'wifi_bssid': bssid});
    _lastWifi = (ssid: ssid, bssid: bssid, at: at);
    _source = 'wifi';
    await _apply(zones.wifi(ssid, bssid, at));
  }

  /// One BLE reading from the phone's scan.
  Future<void> ble(String name, double rssi, DateTime at) {
    _source = 'ble';
    return _apply(zones.bleReading(name, rssi, at));
  }

  /// About once a second, so a beacon that went quiet ends in an exit.
  Future<void> tick(DateTime at) {
    final changes = zones.tick(at);
    if (changes.isNotEmpty) _source = 'ble';
    return _apply(changes);
  }

  /// The phone's battery level (0 to 100) and whether it is charging.
  Future<Map<String, Object?>> battery({
    num? level,
    bool? charging,
    String? phoneId,
  }) async {
    if (level == null && charging == null) {
      throw ApiError('invalid', 'needs level or charging');
    }
    if (level != null && (level < 0 || level > 100)) {
      throw ApiError('invalid', 'level must be 0 to 100');
    }
    final device = await phone(phoneId);
    await _merge(device.id, {'battery': ?level, 'charging': ?charging});
    return (await _store.get(device.id))!.state;
  }

  /// Saves [zone] as the place that answers to its id. A new zone whose id
  /// another thing has gets a place id the way stored zones migrate.
  Future<String> saveZone(ZoneSpec zone) async {
    final existing = (await _ofDriver(placeDriverId))
        .where((p) => zoneIdOf(p) == zone.id)
        .firstOrNull;
    final String placeId;
    if (existing != null) {
      placeId = existing.id;
      await _core.devices.updateDevice(
        existing.id,
        (d) => _place(
          d.id,
          zone,
          zoneId: zoneIdOf(d),
          state: d.state,
        ).placed(room: d.room, order: d.order).copyWith(favourite: d.favourite),
      );
    } else {
      placeId = await _freePlaceId(zone.id);
      await _store.put(_place(placeId, zone, zoneId: zone.id));
    }
    await reload();
    return placeId;
  }

  /// The place that answers to the zone [zoneId], or null.
  Future<Device?> placeForZone(String zoneId) async =>
      (await _ofDriver(placeDriverId))
          .where((p) => zoneIdOf(p) == zoneId)
          .firstOrNull;

  /// Every place as the zone it is, with whether it is inside.
  Future<Map<String, Object?>> listZones() async {
    final places = await _ofDriver(placeDriverId);
    return {
      'zones': [
        for (final p in places)
          if (_tryZone(p) case final zone?)
            {
              ...zone.toJson(),
              'id': zoneIdOf(p),
              'place': p.id,
              'inside': zones.isInside(p.id),
            },
      ],
      'needBle': [
        for (final id in zones.zonesNeedingBle)
          if (_places[id] case final p?) zoneIdOf(p) else id,
      ],
    };
  }

  static ZoneSpec? _tryZone(Device place) {
    try {
      return zoneOfPlace(place);
    } catch (_) {
      return null;
    }
  }

  /// Zone states by zone id, as `sensor.ble` and `sensor.wifi` return them.
  Map<String, bool> get zoneStates => {
    for (final e in zones.states.entries)
      (_places[e.key] == null ? e.key : zoneIdOf(_places[e.key]!)): e.value,
  };
}
