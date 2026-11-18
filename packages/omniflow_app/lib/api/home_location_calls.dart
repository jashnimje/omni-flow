import 'engine_calls.dart' show Json;
import 'engine_client.dart';

/// Where home is (`home.location`, `home.location.set`), which sunrise and
/// sunset, the weather and Follow the sun all need.
abstract final class HomeLocationCalls {
  static const get = 'home.location';
  static const set = 'home.location.set';

  /// [name] is the place as people say it ("Bengaluru, India"). The
  /// engine keeps it with the location, and a location sent without one
  /// clears it.
  static Json setArgs(double latitude, double longitude, {String? name}) => {
    'latitude': latitude,
    'longitude': longitude,
    'name': ?name,
  };
}

/// Home's place and today's sun there, as `home.location` gives them.
class HomeLocationView {
  const HomeLocationView({
    this.latitude,
    this.longitude,
    this.sunrise,
    this.sunset,
    this.name,
  });

  factory HomeLocationView.of(Json r) {
    final at = r['location'] is Map ? r['location'] as Map : const {};
    final today = r['today'] is Map ? r['today'] as Map : const {};
    double? number(Object? v) => v is num ? v.toDouble() : null;
    DateTime? time(Object? v) => DateTime.tryParse('$v')?.toLocal();
    return HomeLocationView(
      latitude: number(at['latitude']),
      longitude: number(at['longitude']),
      sunrise: time(today['sunrise']),
      sunset: time(today['sunset']),
      name: r['name'] is String && (r['name'] as String).isNotEmpty
          ? r['name'] as String
          : null,
    );
  }

  final double? latitude;
  final double? longitude;

  /// The place name saved with the location, or null when none was given.
  final String? name;

  /// Today's sunrise and sunset at home, local time. Null on a day the
  /// sun does not rise or set there.
  final DateTime? sunrise;
  final DateTime? sunset;

  bool get isSet => latitude != null && longitude != null;
}

/// Reads and sets home's place through [client]. Neither throws: a failed
/// read is null, and a failed set is the engine's reply.
class HomeLocationApi {
  const HomeLocationApi(this._client);

  final EngineClient _client;

  Future<HomeLocationView?> read() async {
    try {
      final r = await _client.call(HomeLocationCalls.get);
      return r['ok'] == true && r.containsKey('location')
          ? HomeLocationView.of(r)
          : null;
    } on Object {
      return null;
    }
  }

  Future<Json> set(double latitude, double longitude, {String? name}) async {
    try {
      return await _client.call(
        HomeLocationCalls.set,
        HomeLocationCalls.setArgs(latitude, longitude, name: name),
      );
    } on Object catch (e) {
      return {
        'ok': false,
        'error': {'type': 'failed', 'message': '$e'},
      };
    }
  }
}
