import '../dag/sun.dart';
import '../dag/web_request.dart';

/// The driver of the weather thing.
const weatherDriverId = 'weather';

/// Open-Meteo's forecast API. It needs no account or key.
final openMeteoForecast = Uri.parse('https://api.open-meteo.com/v1/forecast');

/// How often a weather thing asks for the weather.
const weatherEvery = Duration(hours: 1);

/// How long to wait after a failed request before trying again.
const weatherRetry = Duration(minutes: 15);

/// The forecast request for [home], rounded to two decimals (about a
/// kilometre) so the exact address never leaves the phone.
Uri weatherRequest(HomeLocation home, {Uri? base}) {
  final at = base ?? openMeteoForecast;
  return at.replace(
    queryParameters: {
      ...at.queryParameters,
      'latitude': home.latitude.toStringAsFixed(2),
      'longitude': home.longitude.toStringAsFixed(2),
      'current':
          'temperature_2m,apparent_temperature,relative_humidity_2m,'
          'wind_speed_10m,weather_code,uv_index',
      'hourly': 'precipitation,precipitation_probability',
      'daily': 'temperature_2m_max,temperature_2m_min',
      'timezone': 'auto',
      'forecast_days': '2',
    },
  );
}

/// The words for a WMO weather code, as Open-Meteo documents them.
String weatherWords(int? code) => switch (code) {
  0 => 'Clear sky',
  1 => 'Mainly clear',
  2 => 'Partly cloudy',
  3 => 'Cloudy',
  45 || 48 => 'Fog',
  51 || 53 || 55 => 'Drizzle',
  56 || 57 => 'Freezing drizzle',
  61 => 'Light rain',
  63 => 'Rain',
  65 => 'Heavy rain',
  66 || 67 => 'Freezing rain',
  71 => 'Light snow',
  73 => 'Snow',
  75 => 'Heavy snow',
  77 => 'Snow grains',
  80 => 'Light showers',
  81 => 'Showers',
  82 => 'Heavy showers',
  85 || 86 => 'Snow showers',
  95 => 'Thunderstorm',
  96 || 99 => 'Thunderstorm with hail',
  _ => 'Unknown',
};

/// Rain counts as expected from this chance, in percent.
const rainExpectedChance = 50;

/// Or from this much rain, in millimetres.
const rainExpectedMm = 0.3;

num? _num(Object? v) => v is num ? v : null;

num? _at(Object? list, int i) =>
    list is List && i >= 0 && i < list.length ? _num(list[i]) : null;

/// The weather thing's state from an Open-Meteo forecast [reply], read at
/// [now]. Throws a [FormatException] for a reply without the current
/// weather.
Map<String, Object?> weatherState(Object? reply, DateTime now) {
  if (reply is! Map || reply['current'] is! Map) {
    throw const FormatException('the weather service sent no current weather');
  }
  final current = reply['current'] as Map;
  final code = _num(current['weather_code'])?.toInt();
  // Hourly rain at hour T is what falls in the hour before T, so the next
  // hour's rain is the entry one hour after the current hour starts.
  num? rain;
  num? chance;
  final hourly = reply['hourly'];
  final time = current['time'];
  if (hourly is Map && hourly['time'] is List && time is String) {
    final start = DateTime.tryParse(time);
    if (start != null) {
      final next = DateTime(
        start.year,
        start.month,
        start.day,
        start.hour + 1,
      ).toIso8601String().substring(0, 16);
      final i = (hourly['time'] as List).indexOf(next);
      rain = _at(hourly['precipitation'], i);
      chance = _at(hourly['precipitation_probability'], i);
    }
  }
  final daily = reply['daily'];
  return {
    'temperature': _num(current['temperature_2m']),
    'feels_like': _num(current['apparent_temperature']),
    'humidity': _num(current['relative_humidity_2m']),
    'wind_speed': _num(current['wind_speed_10m']),
    'uv_index': _num(current['uv_index']),
    'weather_code': code,
    'condition': weatherWords(code),
    'rain_next_hour': rain,
    'rain_chance_next_hour': chance,
    'rain_expected':
        (chance ?? 0) >= rainExpectedChance || (rain ?? 0) >= rainExpectedMm,
    'high_today': daily is Map ? _at(daily['temperature_2m_max'], 0) : null,
    'low_today': daily is Map ? _at(daily['temperature_2m_min'], 0) : null,
    'updated_at': now.toUtc().toIso8601String(),
    'problem': null,
  };
}

/// What the weather thing says while home has no location.
const weatherNeedsHome =
    'Set where home is first: Settings, Home location. The weather is read '
    'for that place';

/// Asks Open-Meteo for the weather at home, through the engine's web
/// requester, which refuses this machine and link-local addresses.
class WeatherSource {
  WeatherSource({WebRequester? web, Uri? base})
    : web = web ?? const IoWebRequester(),
      base = base ?? openMeteoForecast;

  final WebRequester web;
  final Uri base;

  /// The state for a weather thing at [home] now.
  Future<Map<String, Object?>> read(HomeLocation home, DateTime now) async {
    final reply = await web.send(
      'GET',
      weatherRequest(home, base: base),
      headers: const {'accept': 'application/json'},
    );
    if (reply.status != 200) {
      throw StateError(
        'the weather service answered ${reply.status}, try again later',
      );
    }
    return weatherState(reply.body, now);
  }
}
