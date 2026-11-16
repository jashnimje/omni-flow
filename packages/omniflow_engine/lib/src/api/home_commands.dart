import 'dart:io';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'houses.dart';
import 'mode_commands.dart' show HomeFile;
import 'stored_flows.dart';
import '../dag/sun.dart';

/// Where a house is, kept in `home.json` next to the database: the
/// top-level `location` for the first house, and each other house's in its
/// own section. One location per house, not one per place: places are
/// found by Wi-Fi and BLE, a person may count another place as home, and a
/// sun rule needs no place at all.
class HomeLocationStore {
  HomeLocationStore(this._home);

  final Directory _home;

  HomeFile _file(String house) => HomeFile.house(_home, house);

  Future<HomeLocation?> read([String house = firstHouseId]) async {
    try {
      return homeLocationOf((await _file(house).read())['location']);
    } on ApiError {
      // A damaged entry counts as not set, so sun rules wait for the user.
    }
    return null;
  }

  /// Keeps the other keys `home.json` holds (the house mode, the alerts),
  /// through the one [HomeFile] writer.
  Future<void> write(HomeLocation? location, [String house = firstHouseId]) {
    final json = homeLocationJson(location);
    final file = _file(house);
    return json == null
        ? file.update(const {}, remove: const ['location'])
        : file.update({'location': json});
  }

  /// Reads where every house other than the first is, into the flow
  /// engine, and keeps it so as houses are added: a new house has no
  /// location, so its sun rules never borrow the first house's.
  Future<void> openHouses(EngineCore core) async {
    Future<void> load() async {
      final ids = {for (final h in core.houses.all) h.id}..remove(firstHouseId);
      core.flows.houseLocations.removeWhere((k, _) => !ids.contains(k));
      for (final id in ids) {
        if (core.flows.houseLocations.containsKey(id)) continue;
        core.flows.houseLocations[id] = await read(id);
      }
      core.flows.rescheduleSun();
    }

    await load();
    core.events
        .where((e) => e['event'] == housesChangedEvent)
        .listen((_) => core.track(load()));
  }
}

/// Where [house] is, as the flow engine has it.
HomeLocation? houseLocation(EngineCore core, String house) =>
    house == firstHouseId
    ? core.flows.homeLocation
    : core.flows.houseLocations[house];

/// [location] as `{latitude, longitude}`, or null.
Map<String, Object?>? homeLocationJson(HomeLocation? location) =>
    location == null
    ? null
    : {'latitude': location.latitude, 'longitude': location.longitude};

/// The location `{latitude, longitude}` names, or null for null. Throws
/// an [ApiError] for anything else.
HomeLocation? homeLocationOf(Object? json) {
  if (json == null) return null;
  if (json is! Map) {
    throw ApiError('invalid', 'location must be {latitude, longitude}');
  }
  final latitude = json['latitude'];
  final longitude = json['longitude'];
  if (latitude is! num || latitude < -90 || latitude > 90) {
    throw ApiError('invalid', 'latitude must be a number from -90 to 90');
  }
  if (longitude is! num || longitude < -180 || longitude > 180) {
    throw ApiError('invalid', 'longitude must be a number from -180 to 180');
  }
  return (latitude: latitude.toDouble(), longitude: longitude.toDouble());
}

/// `home.location` and `home.location.set`: where home is, which sunrise
/// and sunset triggers need.
class HomeCommands {
  HomeCommands(this._core, this._stored, this.store);

  final EngineCore _core;
  final StoredFlows _stored;
  final HomeLocationStore store;

  Map<String, CommandHandler> get commands => {
    'home.location': get,
    'home.location.set': set,
  };

  /// `{house?}`: where the house is, the first house when none is named.
  Future<Map<String, Object?>> get(Map<String, Object?> args) async {
    final house = _core.houses.target(args);
    return {..._reply(houseLocation(_core, house)), 'house': house};
  }

  /// `{latitude, longitude, house?}`, north and east positive.
  Future<Map<String, Object?>> set(Map<String, Object?> args) async {
    final location = homeLocationOf({
      'latitude': args['latitude'],
      'longitude': args['longitude'],
    });
    final house = _core.houses.target(args);
    await apply(location, house: house);
    return {..._reply(location), 'house': house};
  }

  /// Saves [location] as [house]'s and moves its running sun triggers.
  Future<void> apply(HomeLocation? location, {String? house}) async {
    final id = house ?? _core.houses.defaultId;
    await store.write(location, id);
    if (id == firstHouseId) {
      _core.flows.homeLocation = location;
    } else {
      _core.flows.houseLocations[id] = location;
      _core.flows.rescheduleSun();
    }
    await _stored.reloadFlows();
  }

  static Map<String, Object?> _reply(HomeLocation? location) {
    final now = DateTime.now();
    return {
      'location': homeLocationJson(location),
      if (location != null)
        'today': {
          for (final e in SunEvent.values)
            e.name: sunEventOn(now, e, location)?.toIso8601String(),
        },
    };
  }
}
