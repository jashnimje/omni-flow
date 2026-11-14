import 'dart:math';

/// A value a capability computes from its params before rendering, for a
/// device that wants a colour in a form templates cannot build, because
/// templates do no arithmetic. A capability names them in `derive`, and
/// its command reads each output like a param.
enum ParamDerivation {
  /// `r`, `g`, `b` (0 to 255) to `xy`, the CIE 1931 point a Hue light
  /// takes, clamped into the light's colour gamut: the device setting
  /// `gamut` (`A`, `B` or `C`, default `C`). The conversion is the one in
  /// Philips' "RGB to xy" note for the Hue API.
  hueXy('hue_xy', inputs: ['r', 'g', 'b'], outputs: ['xy']),

  /// `r`, `g`, `b` (0 to 255) to `hsv`, the 12 hex digit colour a Tuya
  /// bulb takes on its colour data point: hue 0 to 360, saturation and
  /// value 0 to 1000, four digits each. An optional `brightness` param (10
  /// to 1000) sets the value instead of the colour's own.
  tuyaHsv('tuya_hsv', inputs: ['r', 'g', 'b'], outputs: ['hsv']);

  const ParamDerivation(
    this.wireName, {
    required this.inputs,
    required this.outputs,
  });

  final String wireName;

  /// The params it reads, which the capability must declare.
  final List<String> inputs;

  /// The names it adds for the command template.
  final List<String> outputs;

  static ParamDerivation? fromWire(Object? name) =>
      values.where((d) => d.wireName == name).firstOrNull;

  /// The outputs for validated [params] and the device's [settings].
  Map<String, Object?> derive(
    Map<String, Object?> params,
    Map<String, Object?> settings,
  ) {
    final r = (params['r'] as num).toDouble();
    final g = (params['g'] as num).toDouble();
    final b = (params['b'] as num).toDouble();
    return switch (this) {
      hueXy => {'xy': rgbToHueXy(r, g, b, gamut: '${settings['gamut'] ?? ''}')},
      tuyaHsv => {
        'hsv': rgbToTuyaHsv(r, g, b, brightness: params['brightness'] as num?),
      },
    };
  }
}

/// The colour gamuts Hue lights report, as red, green and blue corners.
const hueGamuts = <String, List<(double, double)>>{
  'A': [(0.704, 0.296), (0.2151, 0.7106), (0.138, 0.08)],
  'B': [(0.675, 0.322), (0.409, 0.518), (0.167, 0.04)],
  'C': [(0.6915, 0.3083), (0.17, 0.7), (0.1532, 0.0475)],
};

/// [r], [g], [b] (0 to 255) as a Hue `[x, y]`, rounded to 4 places and
/// inside [gamut] (unknown or empty means C). Black has no chromaticity and
/// maps to the D65 white point.
List<double> rgbToHueXy(double r, double g, double b, {String gamut = 'C'}) {
  double linear(double v) {
    final c = (v / 255).clamp(0.0, 1.0);
    return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4).toDouble() : c / 12.92;
  }

  final (lr, lg, lb) = (linear(r), linear(g), linear(b));
  final x = lr * 0.664511 + lg * 0.154324 + lb * 0.162028;
  final y = lr * 0.283881 + lg * 0.668433 + lb * 0.047685;
  final z = lr * 0.000088 + lg * 0.072310 + lb * 0.986039;
  final sum = x + y + z;
  var point = sum == 0 ? (0.3127, 0.3290) : (x / sum, y / sum);
  final corners = hueGamuts[gamut.trim().toUpperCase()] ?? hueGamuts['C']!;
  if (!_inside(point, corners)) point = _closestOnTriangle(point, corners);
  double round4(double v) => (v * 10000).round() / 10000;
  return [round4(point.$1), round4(point.$2)];
}

bool _inside((double, double) p, List<(double, double)> t) {
  double side((double, double) a, (double, double) b) =>
      (p.$1 - b.$1) * (a.$2 - b.$2) - (a.$1 - b.$1) * (p.$2 - b.$2);
  final d1 = side(t[0], t[1]);
  final d2 = side(t[1], t[2]);
  final d3 = side(t[2], t[0]);
  final negative = d1 < 0 || d2 < 0 || d3 < 0;
  final positive = d1 > 0 || d2 > 0 || d3 > 0;
  return !(negative && positive);
}

(double, double) _closestOnTriangle(
  (double, double) p,
  List<(double, double)> t,
) {
  (double, double) closestOnSegment((double, double) a, (double, double) b) {
    final dx = b.$1 - a.$1;
    final dy = b.$2 - a.$2;
    final along =
        ((p.$1 - a.$1) * dx + (p.$2 - a.$2) * dy) / (dx * dx + dy * dy);
    final k = along.clamp(0.0, 1.0);
    return (a.$1 + dx * k, a.$2 + dy * k);
  }

  double distance((double, double) q) =>
      (q.$1 - p.$1) * (q.$1 - p.$1) + (q.$2 - p.$2) * (q.$2 - p.$2);
  final candidates = [
    closestOnSegment(t[0], t[1]),
    closestOnSegment(t[1], t[2]),
    closestOnSegment(t[2], t[0]),
  ];
  candidates.sort((a, b) => distance(a).compareTo(distance(b)));
  return candidates.first;
}

/// [r], [g], [b] (0 to 255) as Tuya's `HHHHSSSSVVVV` hex colour. The value
/// never drops below 10, the dimmest a Tuya bulb takes, so black is the
/// dimmest red rather than an invalid colour.
String rgbToTuyaHsv(double r, double g, double b, {num? brightness}) {
  final (rn, gn, bn) = (
    (r / 255).clamp(0.0, 1.0),
    (g / 255).clamp(0.0, 1.0),
    (b / 255).clamp(0.0, 1.0),
  );
  final high = max(rn, max(gn, bn));
  final low = min(rn, min(gn, bn));
  final delta = high - low;
  double hue;
  if (delta == 0) {
    hue = 0;
  } else if (high == rn) {
    hue = 60 * (((gn - bn) / delta) % 6);
  } else if (high == gn) {
    hue = 60 * ((bn - rn) / delta + 2);
  } else {
    hue = 60 * ((rn - gn) / delta + 4);
  }
  final saturation = high == 0 ? 0.0 : delta / high;
  final value = brightness?.toDouble() ?? high * 1000;
  String four(num v) => v.round().toRadixString(16).padLeft(4, '0');
  return four(hue.round() % 360) +
      four((saturation * 1000).clamp(0, 1000)) +
      four(value.clamp(10, 1000));
}
