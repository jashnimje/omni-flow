import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omniflow_engine/omniflow_engine.dart'
    show appLabelFor, clockOfDay;

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../design/icons.dart';

/// How the Home, Devices and device screens word a device: its one-line
/// state, its row subtitle and how long ago something happened. Only
/// wording lives here. What a device can do comes from its capability
/// types, as the engine reports them.

/// Glyphs these screens need beyond OmniIcons, from the same rounded set.
abstract final class AreaIcons {
  static const volume = Symbols.volume_up_rounded;
  static const mute = Symbols.volume_off_rounded;
  static const up = Symbols.keyboard_arrow_up_rounded;
  static const down = Symbols.keyboard_arrow_down_rounded;
  static const left = Symbols.keyboard_arrow_left_rounded;
  static const right = Symbols.keyboard_arrow_right_rounded;
  static const sent = Symbols.arrow_upward_rounded;
  static const received = Symbols.arrow_downward_rounded;
  static const battery = Symbols.battery_saver_rounded;
  static const location = Symbols.near_me_rounded;
  static const nearby = Symbols.wifi_find_rounded;
  static const notify = Symbols.notifications_active_rounded;
  static const offline = Symbols.cloud_off_rounded;
  static const ok = Symbols.check_circle_rounded;
  static const failed = Symbols.cancel_rounded;
  static const network = Symbols.lan_rounded;
  static const flash = Symbols.bolt_rounded;
  static const notFound = Symbols.search_off_rounded;
}

/// The things a person keeps in Settings, Places and people, rather than
/// on Home or in Devices.
const presenceDrivers = {'person', 'place'};

enum DeviceKind { tv, sensor, tag, board, phone, person, place, simple }

DeviceKind kindOf(DeviceView d) {
  if (TvCalls.isTv(d.json)) return DeviceKind.tv;
  switch (d.driver) {
    case 'phone':
      return DeviceKind.phone;
    case 'person':
      return DeviceKind.person;
    case 'place':
      return DeviceKind.place;
    case 'nfc_tag':
      return DeviceKind.tag;
  }
  if (d.json['board'] == true) return DeviceKind.board;
  final types = {for (final c in d.capabilities) c['type']};
  if (types.contains('sensor') &&
      types.every((t) => t == 'sensor' || t == 'event')) {
    return DeviceKind.sensor;
  }
  return DeviceKind.simple;
}

/// A device's icon, from its driver's category when the row has none.
IconData iconOf(DeviceView d, Map<String, Json> drivers) => OmniIcons.forDevice(
  {...d.json, 'category': ?drivers[d.driver]?['category']},
);

/// A driver's name without its parenthesis: "Philips WiZ Light (local
/// UDP)" reads "Philips WiZ Light".
String shortDriverName(Json? driver, String? fallback) {
  final name = '${driver?['name'] ?? fallback ?? ''}';
  final cut = name.indexOf(' (');
  return cut > 0 ? name.substring(0, cut) : name;
}

/// "now", "1 min ago", "2 h ago", "3 days ago".
String ago(DateTime at, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  final days = d.inDays;
  return days == 1 ? 'yesterday' : '$days days ago';
}

/// The time of day, "19:02" or "7:02 PM" by [hour12] (the phone's setting,
/// `hour12Provider`).
String clock(DateTime at, {bool hour12 = false}) =>
    clockOfDay(at, hour12: hour12);

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "19:02" today, "Yesterday 18:47", "3 Nov 18:10" before that.
String when(DateTime at, {DateTime? now, bool hour12 = false}) {
  final today = now ?? DateTime.now();
  final day = DateTime(at.year, at.month, at.day);
  final start = DateTime(today.year, today.month, today.day);
  final days = start.difference(day).inDays;
  final time = clock(at, hour12: hour12);
  if (days == 0) return time;
  if (days == 1) return 'Yesterday $time';
  return '${at.day} ${_months[at.month - 1]} $time';
}

/// The level a capability holds as 0 to 1, from its value range.
double? levelFraction(DeviceView d, Json cap) {
  final key = cap['stateKey'];
  final value = key is String ? d.state[key] : null;
  if (value is! num) return null;
  final range = _range(cap);
  if (range.max <= range.min) return null;
  return ((value - range.min) / (range.max - range.min)).clamp(0.0, 1.0);
}

({double min, double max, String unit}) rangeOf(Json cap) => _range(cap);

({double min, double max, String unit}) _range(Json cap) {
  final params = cap['params'] is Map ? cap['params'] as Map : const {};
  final value = params['value'] is Map ? params['value'] as Map : const {};
  return (
    min: (value['min'] as num? ?? 0).toDouble(),
    max: (value['max'] as num? ?? 100).toDouble(),
    unit: '${value['unit'] ?? ''}',
  );
}

/// A colour temperature in kelvin, from kelvin or mired.
double? kelvinOf(num value, String unit) =>
    unit == 'mired' ? (value <= 0 ? null : 1000000 / value) : value.toDouble();

String warmthWord(double kelvin) => kelvin < 3500
    ? 'warm'
    : kelvin > 5000
    ? 'cool'
    : 'neutral';

/// "80%" for a level, "3000 K" for a warmth, a number with its unit.
String formatValue(num value, String unit) {
  final n = value % 1 == 0 ? '${value.round()}' : value.toStringAsFixed(1);
  return switch (unit) {
    '' => n,
    '%' => '$n%',
    _ => '$n $unit',
  };
}

/// The brightness and warmth of a light that is on: "80% · warm".
String? _lightLine(DeviceView d) {
  final parts = <String>[];
  final level = d.capabilityOf('level');
  if (level != null) {
    final v = d.state[level['stateKey']];
    if (v is num) parts.add(formatValue(v, rangeOf(level).unit));
  }
  final temp = d.capabilityOf('color_temp');
  if (temp != null) {
    final v = d.state[temp['stateKey']];
    final k = v is num ? kelvinOf(v, rangeOf(temp).unit) : null;
    if (k != null) parts.add(warmthWord(k));
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

/// A TV app's name from its package, the engine's way: com.netflix.ninja
/// reads "Netflix".
String appName(String package) => appLabelFor(package);

/// What a TV is doing: "Netflix · vol 35", "Asleep".
String tvLine(DeviceView d) {
  final s = TvState.ofDevice(d.json);
  if (s.power == 'asleep') return 'Asleep';
  if (s.power == 'off') return 'Off';
  final line = [
    if (s.app != null) appName(s.app!),
    if (s.volume != null) 'vol ${s.volume}',
  ].join(' · ');
  if (line.isNotEmpty) return line;
  return s.isOn ? 'On' : 'Not read yet';
}

/// A sensor's reading with its unit, or null before it reports.
String? sensorReading(DeviceView d) {
  for (final c in d.capabilities) {
    if (c['type'] != 'sensor') continue;
    final v = d.state[c['stateKey']];
    if (v == null) continue;
    final unit = '${d.state['unit_of_measurement'] ?? d.state['unit'] ?? ''}';
    return switch (v) {
      final bool b => b ? 'on' : 'off',
      final num n =>
        unit.isEmpty ? formatValue(n, '') : '${formatValue(n, '')} $unit',
      _ => '$v',
    };
  }
  return null;
}

/// When a tag was last scanned, or null when never.
DateTime? lastScanned(DeviceView d) =>
    DateTime.tryParse('${d.state['last_scanned']}')?.toLocal();

/// The power state, or null before the device has reported it.
bool? powerOf(DeviceView d) {
  final key = d.capabilityOf('toggle')?['stateKey'];
  if (key is! String || !d.state.containsKey(key)) return null;
  return d.state[key] == true;
}

/// Whether the device shows as on (its power, or a TV that is awake).
bool isLit(DeviceView d) => switch (kindOf(d)) {
  DeviceKind.tv => TvState.ofDevice(d.json).isOn,
  _ => powerOf(d) == true,
};

/// The one line under a tile's name: "80% · warm", "Netflix · vol 35",
/// "Off", "Offline", "2 h ago".
String stateLine(DeviceView d, {DateTime? now}) {
  if (!d.online) return 'Offline';
  switch (kindOf(d)) {
    case DeviceKind.tv:
      return tvLine(d);
    case DeviceKind.tag:
      final at = lastScanned(d);
      return at == null ? 'Not scanned yet' : ago(at, now: now);
    case DeviceKind.phone:
      return _phoneLine(d) ?? 'This phone';
    case DeviceKind.sensor:
      return sensorReading(d) ?? 'No reading yet';
    case DeviceKind.board:
      final first = d.state.entries
          .where((e) => e.value is num || e.value is bool)
          .firstOrNull;
      if (first == null) return 'Online';
      return '${first.key} ${switch (first.value) {
        final bool b => b ? 'on' : 'off',
        final Object? v => '$v',
      }}';
    case DeviceKind.person || DeviceKind.place:
      return switch (d.state['home'] ?? d.state['inside']) {
        true => 'Home',
        false => 'Away',
        _ => '',
      };
    case DeviceKind.simple:
      if (d.hasPower) {
        final on = powerOf(d);
        if (on == null) return 'Not read yet';
        return on ? (_lightLine(d) ?? 'On') : 'Off';
      }
      return sensorReading(d) ??
          (d.lastSeen == null ? '' : 'seen ${ago(d.lastSeen!, now: now)}');
  }
}

String? _phoneLine(DeviceView d) {
  final parts = [
    if (d.state['wifi_ssid'] case final String ssid when ssid.isNotEmpty) ssid,
    if (d.state['battery'] case final num b) '${b.round()}%',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// A Devices row's subtitle: the driver, then what it is doing.
String rowSubtitle(DeviceView d, String driverName, {DateTime? now}) {
  final String detail;
  if (!d.online) {
    final seen = d.lastSeen;
    detail = seen == null ? 'offline' : 'offline since ${when(seen, now: now)}';
  } else {
    detail = switch (kindOf(d)) {
      DeviceKind.tag => switch (lastScanned(d)) {
        final at? => 'scanned ${ago(at, now: now)}',
        null => 'not scanned yet',
      },
      DeviceKind.board => [
        if (d.json['settings'] case {'pins': final List pins})
          '${pins.length} pins',
        'online',
      ].join(' · '),
      _ => stateLine(d, now: now),
    };
  }
  return [
    if (driverName.isNotEmpty) driverName,
    if (detail.isNotEmpty) detail,
  ].join(' · ');
}

/// A tile's level bar, for a light that is on.
double? tileLevel(DeviceView d) {
  if (!d.online || powerOf(d) != true) return null;
  final level = d.capabilityOf('level');
  return level == null ? null : levelFraction(d, level);
}

/// The person thing the household's greeting and presence come from.
DeviceView? personOf(Iterable<DeviceView> devices) =>
    devices.where((d) => d.driver == 'person').firstOrNull;

/// "Good morning" (5 to 12), "Good afternoon" (to 18), otherwise "Good
/// evening": 1 am is not morning.
String greeting(DateTime now) => switch (now.hour) {
  >= 5 && < 12 => 'Good morning',
  >= 12 && < 18 => 'Good afternoon',
  _ => 'Good evening',
};
