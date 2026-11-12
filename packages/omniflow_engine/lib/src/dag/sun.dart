import 'dart:math' as math;

/// Where home is, for sunrise and sunset triggers.
typedef HomeLocation = ({double latitude, double longitude});

/// The two sun events a rule can trigger on.
enum SunEvent {
  sunrise,
  sunset;

  static SunEvent? parse(Object? name) =>
      values.where((e) => e.name == name).firstOrNull;
}

/// The furthest a sun trigger may move from its event, in minutes.
const sunOffsetLimit = 720;

/// The sun's centre this far below the horizon is sunrise or sunset: half
/// its disc plus the bend of the air, as NOAA counts it.
const _zenith = 90.833;

double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// When [event] happens in UTC on the UTC calendar day [year]-[month]-[day]
/// at [latitude] north and [longitude] east, by the NOAA solar calculator.
/// Null when the sun does not rise or set that day (polar day or night).
DateTime? sunEventUtc(
  int year,
  int month,
  int day,
  SunEvent event,
  double latitude,
  double longitude,
) {
  final midnight = DateTime.utc(year, month, day);
  final jd0 = midnight.millisecondsSinceEpoch / 86400000 + 2440587.5;
  var minutes = 720 - 4 * longitude;
  // The sun moves a little between noon and the event, so each later pass
  // recomputes its position at the last estimate.
  for (var pass = 0; pass < 3; pass++) {
    final t = (jd0 + minutes / 1440 - 2451545) / 36525;
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
    final lat = _rad(latitude);
    final cosHa =
        math.cos(_rad(_zenith)) / (math.cos(lat) * math.cos(declination)) -
        math.tan(lat) * math.tan(declination);
    if (cosHa < -1 || cosHa > 1) return null;
    final ha = _deg(math.acos(cosHa));
    final noon = 720 - 4 * longitude - eqTime;
    minutes = event == SunEvent.sunrise ? noon - 4 * ha : noon + 4 * ha;
  }
  return midnight.add(Duration(microseconds: (minutes * 60e6).round()));
}

/// When [event] happens on the calendar day of [day], in [day]'s own zone
/// (local, or UTC for a UTC time), or null when the sun does not rise or
/// set that day.
DateTime? sunEventOn(DateTime day, SunEvent event, HomeLocation home) {
  // The event on a local day can fall on the UTC day before or after.
  for (final shift in const [0, -1, 1]) {
    final utc = sunEventUtc(
      day.year,
      day.month,
      day.day + shift,
      event,
      home.latitude,
      home.longitude,
    );
    if (utc == null) continue;
    final there = day.isUtc ? utc : utc.toLocal();
    if (there.year == day.year &&
        there.month == day.month &&
        there.day == day.day) {
      return there;
    }
  }
  return null;
}

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// A whole year, so a polar night still finds its next sunrise.
const _searchDays = 370;

DateTime? _triggerOn(
  DateTime day,
  SunEvent event,
  HomeLocation home,
  int offsetMinutes,
  List<String>? days,
) {
  if (days != null && !days.contains(_weekdays[day.weekday - 1])) return null;
  return sunEventOn(day, event, home)?.add(Duration(minutes: offsetMinutes));
}

/// The first time after [now] that a sun trigger fires: [event] moved by
/// [offsetMinutes], on one of [days] (the day of the event) when given.
/// Null when it never fires within a year.
DateTime? nextSunTrigger(
  DateTime now,
  SunEvent event,
  HomeLocation home, {
  int offsetMinutes = 0,
  List<String>? days,
}) {
  // A day before today too: a late offset moves yesterday's event past now.
  for (var add = -1; add <= _searchDays; add++) {
    final day = _dayOf(now, add);
    final t = _triggerOn(day, event, home, offsetMinutes, days);
    if (t != null && t.isAfter(now)) return t;
  }
  return null;
}

/// The last time at or before [now] that a sun trigger fired, within a
/// week, as a daily time trigger looks back.
DateTime? previousSunTrigger(
  DateTime now,
  SunEvent event,
  HomeLocation home, {
  int offsetMinutes = 0,
  List<String>? days,
}) {
  for (var add = 1; add >= -8; add--) {
    final day = _dayOf(now, add);
    final t = _triggerOn(day, event, home, offsetMinutes, days);
    if (t != null && !t.isAfter(now)) return t;
  }
  return null;
}

DateTime _dayOf(DateTime now, int add) => now.isUtc
    ? DateTime.utc(now.year, now.month, now.day + add, 12)
    : DateTime(now.year, now.month, now.day + add, 12);
