import 'package:flutter/material.dart';

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../design/tokens.dart' show LightWhite;
import '../devices/device_text.dart';

/// How a Home tile shows a device's live state: the colour a light glows,
/// the reading a sensor or TV shows big, and the line under the name.

/// The colour a light that is on glows: its own colour when it reports
/// one, its white from warm to cool, or a plain warm white. Null for a
/// device that is not a light (the tile uses the accent).
Color? tileTint(DeviceView d) {
  if (powerOf(d) != true) return null;
  final s = d.state;
  if (d.capabilityOf('color_rgb') != null &&
      s['r'] is num &&
      s['g'] is num &&
      s['b'] is num) {
    final r = (s['r'] as num).toInt().clamp(0, 255);
    final g = (s['g'] as num).toInt().clamp(0, 255);
    final b = (s['b'] as num).toInt().clamp(0, 255);
    if (r + g + b > 0) return Color.fromARGB(255, r, g, b);
  }
  final temp = d.capabilityOf('color_temp');
  if (temp != null) {
    final v = s[temp['stateKey']];
    final k = v is num ? kelvinOf(v, rangeOf(temp).unit) : null;
    if (k != null) return whiteOf(k);
  }
  if (d.capabilityOf('level') != null) return LightWhite.warm;
  return null;
}

/// A light's white at [kelvin]: amber at 2200 K, pale at 6500 K.
Color whiteOf(double kelvin) => Color.lerp(
  LightWhite.warm,
  LightWhite.cool,
  ((kelvin - 2200) / (6500 - 2200)).clamp(0.0, 1.0),
)!;

/// Whether [d] has a power to switch from Home: a TV, or anything with a
/// toggle except a phone, whose first toggle is its torch.
bool hasMainPower(DeviceView d) => switch (kindOf(d)) {
  DeviceKind.tv => true,
  DeviceKind.phone => false,
  _ => d.hasPower,
};

/// A phone's line: whether its screen is on, and its battery.
String phoneLine(DeviceView d) {
  final s = d.state;
  return [
    ?_screenWords(d),
    if (s['battery'] case final num b)
      '${b.round()}% battery${s['charging'] == true ? ', charging' : ''}',
  ].join(' · ');
}

String? _screenWords(DeviceView d) => switch (d.state['screen_on']) {
  true => 'Screen on',
  false => 'Screen off',
  _ => null,
};

/// The big line of a tile: a sensor's reading, a phone's battery, or the
/// app on a TV that is on. Null when the name and state line say enough.
String? tileReading(DeviceView d) {
  if (!d.online) return null;
  switch (kindOf(d)) {
    case DeviceKind.phone:
      final b = d.state['battery'];
      return b is num ? '${b.round()}%' : null;
    case DeviceKind.sensor:
      return sensorReading(d);
    case DeviceKind.simple when !d.hasPower:
      return sensorReading(d);
    default:
      return null;
  }
}

/// The line under a tile's name. With a [tileReading] shown big, it
/// carries what is left: a TV's "Playing · vol 35", nothing for a
/// sensor.
String? tileState(DeviceView d) {
  if (d.online && kindOf(d) == DeviceKind.phone) {
    final line = tileReading(d) == null
        ? phoneLine(d)
        : [
            ?_screenWords(d),
            if (d.state['charging'] == true) 'charging',
          ].join(' · ');
    return line.isEmpty ? stateLine(d) : line;
  }
  // A TV keeps its own name as the tile's title: what it shows goes on
  // this line, never in place of the name.
  if (d.online && kindOf(d) == DeviceKind.tv) {
    final s = TvState.ofDevice(d.json);
    if (!s.isOn || s.app == null) return stateLine(d);
    return [
      appName(s.app!),
      if (s.playing == 'playing') 'Playing',
      if (s.playing == 'paused') 'Paused',
      if (s.volume != null) 'vol ${s.volume}',
    ].join(' · ');
  }
  final reading = tileReading(d);
  if (reading == null) return stateLine(d);
  if (kindOf(d) != DeviceKind.tv) return null;
  final s = TvState.ofDevice(d.json);
  final line = [
    if (s.playing == 'playing') 'Playing',
    if (s.playing == 'paused') 'Paused',
    if (s.volume != null) 'vol ${s.volume}',
  ].join(' · ');
  return line.isEmpty ? 'On' : line;
}
