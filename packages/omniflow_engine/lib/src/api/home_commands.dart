import 'dart:convert';
import 'dart:io';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'stored_flows.dart';
import '../dag/sun.dart';

/// Where home is, kept in `home.json` next to the database. One location
/// for the whole home, not one per place: places are found by Wi-Fi and
/// BLE, a person may count another place as home, and a sun rule needs no
/// place at all.
class HomeLocationStore {
  HomeLocationStore(Directory home) : _file = File('${home.path}/home.json');

  final File _file;

  Future<HomeLocation?> read() async {
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map) return homeLocationOf(json['location']);
    } on FileSystemException {
      // Never set.
    } on FormatException {
      // A damaged file counts as not set, so sun rules wait for the user.
    } on ApiError {
      // The same.
    }
    return null;
  }

  /// Keeps the other keys `home.json` holds (the house mode, the alerts).
  Future<void> write(HomeLocation? location) async {
    final temp = File('${_file.path}.tmp');
    Map<String, Object?> others = {};
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map) others = Map<String, Object?>.from(json);
    } on FileSystemException {
      // Never written.
    } on FormatException {
      // Damaged: replaced whole.
    }
    others.remove('location');
    await temp.writeAsString(
      jsonEncode({...others, 'location': ?homeLocationJson(location)}),
      flush: true,
    );
    await temp.rename(_file.path);
  }
}

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

  Future<Map<String, Object?>> get(Map<String, Object?> _) async =>
      _reply(_core.flows.homeLocation);

  /// `{latitude, longitude}`, north and east positive.
  Future<Map<String, Object?>> set(Map<String, Object?> args) async {
    final location = homeLocationOf({
      'latitude': args['latitude'],
      'longitude': args['longitude'],
    });
    await apply(location);
    return _reply(location);
  }

  /// Saves [location] and moves the running sun triggers to it.
  Future<void> apply(HomeLocation? location) async {
    await store.write(location);
    _core.flows.homeLocation = location;
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
