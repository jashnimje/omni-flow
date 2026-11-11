import '../template/template_renderer.dart';
import 'param_spec.dart';
import 'validation.dart';

enum CapabilityType {
  toggle('toggle'),
  level('level'),
  colorTemp('color_temp'),
  colorRgb('color_rgb'),
  dpadRemote('dpad_remote'),
  textCommand('text_command'),
  exec('exec'),
  sensor('sensor'),
  action('action'),

  /// Something that happens: momentary, with a payload, keeping no state
  /// and taking no command (a button press, an NFC scan).
  event('event');

  const CapabilityType(this.wireName);

  final String wireName;

  static CapabilityType? fromWire(Object? name) =>
      values.where((t) => t.wireName == name).firstOrNull;

  /// The params every capability of this type takes. A manifest can narrow
  /// them (a level's min and max) or add more.
  Map<String, ParamSpec> get defaultParams => switch (this) {
    toggle => const {'value': ParamSpec(type: ParamType.boolean)},
    level => const {'value': ParamSpec(type: ParamType.number)},
    colorTemp => const {'value': ParamSpec(type: ParamType.number, unit: 'K')},
    colorRgb => const {
      'r': ParamSpec(type: ParamType.number, min: 0, max: 255),
      'g': ParamSpec(type: ParamType.number, min: 0, max: 255),
      'b': ParamSpec(type: ParamType.number, min: 0, max: 255),
    },
    dpadRemote => const {
      'value': ParamSpec(
        type: ParamType.enumeration,
        values: ['up', 'down', 'left', 'right', 'ok', 'back', 'home'],
      ),
    },
    textCommand => const {'value': ParamSpec(type: ParamType.string)},
    exec || sensor || action || event => const {},
  };

  bool get hasCommand => this != sensor && this != event;

  bool get isHighRisk => this == exec;
}

final _idPattern = RegExp(r'^[a-z][a-z0-9_]*$');

/// An event key may be dotted, so a part of a thing can raise its own
/// events: `button.pressed` on a board.
final eventKeyPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');
const _prefixedRoots = ['state.', 'device.', 'msg.', r'$', '%'];

class CapabilitySpec {
  const CapabilitySpec({
    required this.id,
    required this.type,
    required this.label,
    required this.params,
    required this.command,
    this.stateJsonPath,
    this.onOff,
    this.values = const [],
  });

  final String id;
  final CapabilityType type;
  final String label;
  final Map<String, ParamSpec> params;

  /// The structured command template, null for a sensor.
  final Object? command;
  final String? stateJsonPath;

  /// For a toggle whose device has its own words for on and off (`"ON"`,
  /// `"OFF"`): what `true` and `false` are sent as, and read back from.
  final (Object, Object)? onOff;

  /// The values a sensor reports, when it has a fixed set (a TV's power is
  /// on, asleep or off), so a check or trigger on it is a choice, not text.
  final List<Object> values;

  /// [value] as the device says it, for a toggle with [onOff].
  Object? toDevice(Object? value) =>
      onOff == null || value is! bool ? value : (value ? onOff!.$1 : onOff!.$2);

  /// A device value read back as `true` or `false` when it is one of the
  /// [onOff] words (case does not matter), unchanged otherwise.
  Object? fromDevice(Object? value) {
    final words = onOff;
    if (words == null || value is bool) return value;
    bool same(Object word) => word is String && value is String
        ? word.toLowerCase() == value.toLowerCase()
        : word == value;
    if (same(words.$1)) return true;
    if (same(words.$2)) return false;
    return value;
  }

  static CapabilitySpec? parse(
    Object? json,
    String path,
    IssueCollector issues,
  ) {
    if (json is! Map) {
      issues.add(path, 'must be an object');
      return null;
    }
    final map = Map<String, Object?>.from(json);
    final before = issues.issues.length;
    final id = issues.requiredString(map, 'id', path);
    final type = CapabilityType.fromWire(map['type']);
    if (id != null &&
        !(type == CapabilityType.event ? eventKeyPattern : _idPattern).hasMatch(
          id,
        )) {
      issues.add(
        '$path.id',
        type == CapabilityType.event
            ? 'must be lower snake case, dotted parts allowed'
            : 'must be lower snake case',
      );
    }
    if (type == null) {
      issues.add(
        '$path.type',
        'must be one of ${CapabilityType.values.map((t) => t.wireName).join(', ')}',
      );
    }
    final label = issues.optionalString(map, 'label', path);
    final params = <String, ParamSpec>{...?type?.defaultParams};
    final rawParams = issues.optionalMap(map, 'params', path) ?? const {};
    for (final entry in rawParams.entries) {
      final spec = ParamSpec.parse(
        entry.value,
        '$path.params.${entry.key}',
        issues,
      );
      if (spec != null) params[entry.key] = spec;
    }
    final command = map['command'];
    if (type != null && type.hasCommand && command == null) {
      issues.add('$path.command', 'is required for a ${type.wireName}');
    }
    if (type == CapabilityType.sensor && command != null) {
      issues.add('$path.command', 'a sensor has no command');
    }
    if (type == CapabilityType.event && command != null) {
      issues.add('$path.command', 'an event has no command');
    }
    if (command != null) {
      _checkPlaceholders(command, params, '$path.command', issues);
    }
    final stateJsonPath = issues.optionalString(map, 'stateJsonPath', path);
    if (type == CapabilityType.event && stateJsonPath != null) {
      issues.add('$path.stateJsonPath', 'an event keeps no state');
    }
    issues.jsonPath(stateJsonPath, '$path.stateJsonPath');
    final rawOnOff = map['onOff'];
    (Object, Object)? onOff;
    if (rawOnOff != null) {
      if (type != CapabilityType.toggle) {
        issues.add('$path.onOff', 'is only for a toggle');
      } else if (rawOnOff is! List ||
          rawOnOff.length != 2 ||
          rawOnOff.any((v) => v == null || v is Map || v is List)) {
        issues.add('$path.onOff', 'must be [on, off], two plain values');
      } else {
        onOff = (rawOnOff[0] as Object, rawOnOff[1] as Object);
      }
    }
    final rawValues = map['values'];
    var values = const <Object>[];
    if (rawValues != null) {
      if (type != CapabilityType.sensor) {
        issues.add('$path.values', 'is only for a sensor');
      } else if (rawValues is! List ||
          rawValues.isEmpty ||
          rawValues.any((v) => v == null || v is Map || v is List)) {
        issues.add('$path.values', 'must be a list of plain values');
      } else {
        values = List<Object>.unmodifiable(rawValues.cast<Object>());
      }
    }
    if (issues.issues.length > before || id == null || type == null) {
      return null;
    }
    return CapabilitySpec(
      id: id,
      type: type,
      label: label ?? id,
      params: params,
      command: command,
      stateJsonPath: stateJsonPath,
      onOff: onOff,
      values: values,
    );
  }

  static void _checkPlaceholders(
    Object command,
    Map<String, ParamSpec> params,
    String path,
    IssueCollector issues,
  ) {
    final List<Placeholder> found;
    try {
      found = placeholdersIn(command);
    } on TemplateException catch (e) {
      issues.add(path, e.message);
      return;
    }
    for (final placeholder in found) {
      for (final p in placeholder.paths) {
        if (_prefixedRoots.any(p.startsWith)) continue;
        final root = p.split('.').first;
        if (!params.containsKey(root)) {
          issues.add(
            path,
            '{{${placeholder.source}}} reads "$root", which is not a declared param (use state.$root for device state)',
          );
        }
      }
    }
  }

  /// Checks [input] against the declared params and returns the params to
  /// render with. Throws a [ValidationException] listing every problem.
  Map<String, Object?> validateParams(Map<String, Object?> input) {
    final issues = <ValidationIssue>[];
    for (final key in input.keys) {
      if (!params.containsKey(key)) {
        issues.add(ValidationIssue('params.$key', 'is not a param of $id'));
      }
    }
    for (final entry in params.entries) {
      final value = input[entry.key];
      if (value == null) {
        if (!entry.value.optional) {
          issues.add(ValidationIssue('params.${entry.key}', 'is required'));
        }
        continue;
      }
      final problem = entry.value.check(value);
      if (problem != null) {
        issues.add(ValidationIssue('params.${entry.key}', problem));
      }
    }
    if (issues.isNotEmpty) throw ValidationException('params for $id', issues);
    // 80.0 from a slider or a scaled link renders as "80.0", which a device
    // taking whole numbers refuses.
    return Map.unmodifiable({
      for (final MapEntry(:key, :value) in input.entries)
        key: params[key]!.integer && value is double ? value.round() : value,
    });
  }
}
