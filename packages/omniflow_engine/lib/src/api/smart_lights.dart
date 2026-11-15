import 'dart:convert';
import 'dart:io';

import '../devices/device.dart';
import '../devices/device_service.dart';
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/param_spec.dart';

/// The parts of a light the home helpers drive: its power toggle, and its
/// brightness and white temperature where it has them.
class LightParts {
  const LightParts({required this.power, this.brightness, this.colorTemp});

  final CapabilitySpec power;
  final CapabilitySpec? brightness;
  final CapabilitySpec? colorTemp;

  String? get powerKey => stateKeyOf(power.stateJsonPath);
  String? get brightnessKey => stateKeyOf(brightness?.stateJsonPath);
  String? get colorTempKey => stateKeyOf(colorTemp?.stateJsonPath);

  /// Whether the light [state] says is on.
  bool isOn(Map<String, Object?> state) =>
      powerKey != null && state[powerKey] == true;
}

/// The light parts of a driver, or null when it is not a light: it needs
/// a power toggle with a state key, and a brightness or white temperature.
LightParts? lightPartsOf(DriverManifest? manifest) {
  if (manifest == null) return null;
  final power = manifest.capability('power');
  if (power == null ||
      power.type != CapabilityType.toggle ||
      stateKeyOf(power.stateJsonPath) == null) {
    return null;
  }
  final brightness = [
    manifest.capability('brightness'),
    manifest.capability('dimmer'),
  ].whereType<CapabilitySpec>().where((c) => c.type == CapabilityType.level);
  final colorTemp = manifest.capability('color_temp');
  final parts = LightParts(
    power: power,
    brightness: brightness.firstOrNull,
    colorTemp:
        colorTemp != null &&
            (colorTemp.type == CapabilityType.colorTemp ||
                colorTemp.type == CapabilityType.level)
        ? colorTemp
        : null,
  );
  if (manifest.category != 'lighting' &&
      parts.brightness == null &&
      parts.colorTemp == null) {
    return null;
  }
  return parts;
}

/// The light's warmest and coolest white when its scale has no unit, as
/// Tuya's 0 to 1000 does.
const _scaleWarmK = 2700;
const _scaleCoolK = 6500;

num _clamp(num v, num? min, num? max) {
  var out = v;
  if (min != null && out < min) out = min;
  if (max != null && out > max) out = max;
  return out;
}

num _whole(ParamSpec spec, num v) => spec.integer ? v.round() : v;

/// [kelvin] in the light's own units: kelvin, mireds, or a unitless scale
/// from warm to cool.
num kelvinToDevice(CapabilitySpec capability, num kelvin) {
  final spec = capability.params['value'];
  if (spec == null) return kelvin.round();
  final unit = spec.unit?.toLowerCase();
  if (unit == 'mired' || unit == 'mireds') {
    return _whole(spec, _clamp(1e6 / kelvin, spec.min, spec.max));
  }
  if (unit == 'k' || capability.type == CapabilityType.colorTemp) {
    return _whole(spec, _clamp(kelvin, spec.min, spec.max));
  }
  final min = spec.min ?? 0;
  final max = spec.max ?? 100;
  final f = ((kelvin - _scaleWarmK) / (_scaleCoolK - _scaleWarmK)).clamp(0, 1);
  return _whole(spec, min + (max - min) * f);
}

/// [percent] (1 to 100) in the light's own brightness units.
num percentToDevice(CapabilitySpec capability, num percent) {
  final spec = capability.params['value'];
  if (spec == null) return percent.round();
  final max = spec.max ?? 100;
  return _whole(spec, _clamp(max * percent / 100, spec.min, max));
}

/// Whether [a] and [b] are within 2% of the capability's range, so a light
/// rounding what it was sent does not count as a change.
bool closeTo(CapabilitySpec capability, Object? a, Object? b) {
  if (a is! num || b is! num) return a == b;
  final spec = capability.params['value'];
  final range = (spec?.max ?? 100) - (spec?.min ?? 0);
  return (a - b).abs() <= (range.abs() * 0.02).clamp(1, double.infinity);
}

/// The lights [targets] name: a light by its id, or every light in a room
/// by the room's id, each once.
List<Device> lightsOf(
  Iterable<String> targets,
  List<Device> devices,
  LightParts? Function(Device) partsOf,
) {
  final out = <String, Device>{};
  for (final t in targets) {
    for (final d in devices) {
      if ((d.id == t || d.room == t) && partsOf(d) != null) out[d.id] = d;
    }
  }
  return out.values.toList();
}

/// A small JSON file next to the database, written whole through a
/// temporary file so a crash never leaves half of it.
class JsonFileStore {
  JsonFileStore(Directory home, String name)
    : _file = File('${home.path}/$name');

  final File _file;

  Future<Map<String, Object?>> read() async {
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map) return Map<String, Object?>.from(json);
    } on FileSystemException {
      // Never written.
    } on FormatException {
      // A damaged file starts over.
    }
    return {};
  }

  Future<void> write(Map<String, Object?> json) async {
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(_file.path);
  }
}
