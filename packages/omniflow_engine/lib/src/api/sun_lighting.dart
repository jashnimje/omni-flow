import 'dart:math' as math;

import 'api_error.dart';
import '../dag/sun.dart';

/// Who the engine names as the sender of a follow-the-sun change, so a
/// manual change can be told from its own.
const sunlightBy = 'sunlight';

/// How often followed lights are brought to the curve.
const sunlightEvery = Duration(minutes: 5);

/// How long a light is left alone after someone changes it by hand.
const sunlightPause = Duration(hours: 1);

/// The sun this far below the horizon counts as night: civil twilight.
const _nightElevation = -6.0;

double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// The sun's height above the horizon in degrees at [at] for [home], by
/// the NOAA solar position formulas sun.dart uses for sunrise and sunset.
double sunElevation(DateTime at, HomeLocation home) {
  final utc = at.toUtc();
  final jd = utc.millisecondsSinceEpoch / 86400000 + 2440587.5;
  final t = (jd - 2451545) / 36525;
  final l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360;
  final m = 357.52911 + t * (35999.05029 - 0.0001537 * t);
  final e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
  final c =
      math.sin(_rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
      math.sin(_rad(2 * m)) * (0.019993 - 0.000101 * t) +
      math.sin(_rad(3 * m)) * 0.000289;
  final omega = 125.04 - 1934.136 * t;
  final apparent = l0 + c - 0.00569 - 0.00478 * math.sin(_rad(omega));
  final meanObliquity =
      23 +
      (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60;
  final obliquity = meanObliquity + 0.00256 * math.cos(_rad(omega));
  final declination = math.asin(
    math.sin(_rad(obliquity)) * math.sin(_rad(apparent)),
  );
  final y = math.pow(math.tan(_rad(obliquity / 2)), 2).toDouble();
  final eqTime =
      4 *
      _deg(
        y * math.sin(2 * _rad(l0)) -
            2 * e * math.sin(_rad(m)) +
            4 * e * y * math.sin(_rad(m)) * math.cos(2 * _rad(l0)) -
            0.5 * y * y * math.sin(4 * _rad(l0)) -
            1.25 * e * e * math.sin(2 * _rad(m)),
      );
  final minutes = utc.hour * 60 + utc.minute + utc.second / 60;
  final solarTime = (minutes + eqTime + 4 * home.longitude) % 1440;
  final hourAngle = _rad(solarTime / 4 - 180);
  final lat = _rad(home.latitude);
  final cosZenith =
      math.sin(lat) * math.sin(declination) +
      math.cos(lat) * math.cos(declination) * math.cos(hourAngle);
  return 90 - _deg(math.acos(cosZenith.clamp(-1.0, 1.0)));
}

/// The sun's highest point on [day]'s calendar day, sampled every ten
/// minutes.
double peakElevation(DateTime day, HomeLocation home) {
  final start = DateTime(day.year, day.month, day.day);
  var peak = -90.0;
  for (var m = 0; m < 1440; m += 10) {
    peak = math.max(peak, sunElevation(start.add(Duration(minutes: m)), home));
  }
  return peak;
}

/// A followed light's range: the warmest and dimmest at night, the coolest
/// and brightest at the day's highest sun.
class SunCurve {
  const SunCurve({
    this.minK = 2200,
    this.maxK = 5000,
    this.minBrightness = 30,
    this.maxBrightness = 100,
  });

  final int minK;
  final int maxK;
  final int minBrightness;
  final int maxBrightness;

  static const lowestK = 2000;
  static const highestK = 6500;

  /// The curve [json] gives, filling in from [base]. Throws an [ApiError]
  /// for a value out of range.
  factory SunCurve.of(
    Map<String, Object?> json, [
    SunCurve base = const SunCurve(),
  ]) {
    int pick(String key, int fallback, int min, int max, String words) {
      final v = json[key];
      if (v == null) return fallback;
      if (v is! num || v < min || v > max) {
        throw ApiError('invalid', '$key must be $words from $min to $max');
      }
      return v.round();
    }

    final curve = SunCurve(
      minK: pick('minK', base.minK, lowestK, highestK, 'a kelvin number'),
      maxK: pick('maxK', base.maxK, lowestK, highestK, 'a kelvin number'),
      minBrightness: pick(
        'minBrightness',
        base.minBrightness,
        1,
        100,
        'a percent',
      ),
      maxBrightness: pick(
        'maxBrightness',
        base.maxBrightness,
        1,
        100,
        'a percent',
      ),
    );
    if (curve.minK > curve.maxK) {
      throw ApiError('invalid', 'minK must not be above maxK');
    }
    if (curve.minBrightness > curve.maxBrightness) {
      throw ApiError(
        'invalid',
        'minBrightness must not be above maxBrightness',
      );
    }
    return curve;
  }

  Map<String, Object?> toJson() => {
    'minK': minK,
    'maxK': maxK,
    'minBrightness': minBrightness,
    'maxBrightness': maxBrightness,
  };

  /// How far into the day the sun is at [elevation], from 0 at night to 1
  /// at the day's [peak], eased so the change is gentle at both ends.
  static double dayShare(double elevation, double peak) {
    if (peak <= _nightElevation) return 0;
    final f = ((elevation - _nightElevation) / (peak - _nightElevation)).clamp(
      0.0,
      1.0,
    );
    return f * f * (3 - 2 * f);
  }

  /// The white temperature and brightness for a sun at [elevation] on a
  /// day whose highest sun is [peak].
  ({int kelvin, int brightness}) at(double elevation, double peak) {
    final s = dayShare(elevation, peak);
    return (
      kelvin: (minK + (maxK - minK) * s).round(),
      brightness: (minBrightness + (maxBrightness - minBrightness) * s).round(),
    );
  }

  /// The curve over [day] every [step], for the settings page's preview.
  List<Map<String, Object?>> preview(
    DateTime day,
    HomeLocation home, {
    Duration step = const Duration(minutes: 30),
  }) {
    final start = DateTime(day.year, day.month, day.day);
    final peak = peakElevation(day, home);
    return [
      for (var t = start; t.day == start.day; t = t.add(step))
        () {
          final e = sunElevation(t, home);
          final v = at(e, peak);
          return {
            'at': t.toIso8601String(),
            'elevation': double.parse(e.toStringAsFixed(1)),
            'kelvin': v.kelvin,
            'brightness': v.brightness,
          };
        }(),
    ];
  }
}
