import '../manifest/capability.dart';
import '../manifest/validation.dart';
import '../template/template_renderer.dart';

enum NodeCategory { trigger, condition, gate, transformer, flowControl, action }

/// What a flow may refer to, so the validator can check references.
class FlowReferences {
  const FlowReferences({
    this.capabilityOf = _none,
    this.devices = const {},
    this.zones = const {},
    this.flows = const {},
  });

  /// The capability [capabilityId] of device [deviceId], or null.
  final CapabilitySpec? Function(String deviceId, String capabilityId)
  capabilityOf;
  final Set<String> devices;
  final Set<String> zones;
  final Set<String> flows;

  static CapabilitySpec? _none(String _, String _) => null;
}

typedef ConfigCheck = void Function(
  Map<String, Object?> config,
  String path,
  IssueCollector issues,
  FlowReferences refs,
);

/// A registered node type: its category, output ports and config check.
/// Every node except a trigger has one input port, `in`.
class NodeType {
  const NodeType(this.type, this.category, this.outputs, this.check);

  final String type;
  final NodeCategory category;
  final List<String> outputs;
  final ConfigCheck check;

  bool get hasInput => category != NodeCategory.trigger;
}

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const _compareOps = ['<', '<=', '>', '>=', '==', '!='];

/// The built-in node types, keyed by type name.
final Map<String, NodeType> builtInNodeTypes = {
  for (final t in <NodeType>[
    // Triggers.
    NodeType('manual', NodeCategory.trigger, ['out'], (_, _, _, _) {}),
    NodeType('time_of_day', NodeCategory.trigger, ['out'], (c, p, i, _) {
      _time(c, 'at', p, i);
      final days = c['days'];
      if (days != null &&
          (days is! List ||
              days.isEmpty ||
              days.any((d) => !_days.contains(d)))) {
        i.add('$p.days', 'must be a non-empty list of ${_days.join(', ')}');
      }
    }),
    NodeType('interval', NodeCategory.trigger, [
      'out',
    ], (c, p, i, _) => _int(c, 'seconds', p, i, min: 1)),
    NodeType('zone_change', NodeCategory.trigger, ['out'], (c, p, i, r) {
      _ref(c, 'zoneId', r.zones, 'zone', p, i);
      _oneOf(c, 'transition', ['entered', 'exited'], p, i);
    }),
    NodeType('device_state', NodeCategory.trigger, ['out'], (c, p, i, r) {
      _ref(c, 'deviceId', r.devices, 'device', p, i);
      _optionalString(c, 'key', p, i);
    }),
    NodeType('board_event', NodeCategory.trigger, ['out'], (c, p, i, _) {
      _string(c, 'event', p, i);
      _optionalString(c, 'node', p, i);
    }),
    NodeType('wifi_change', NodeCategory.trigger, [
      'out',
    ], (c, p, i, _) => _optionalString(c, 'ssid', p, i)),
    // Conditions.
    for (final composite in ['all_of', 'any_of', 'xor'])
      NodeType(composite, NodeCategory.condition, [
        'true',
        'false',
      ], (c, p, i, r) => checkRule({...c, 'type': composite}, p, i, r)),
    for (final simple in [
      'not',
      'time_window',
      'var_equals',
      'var_compare',
      'device_state_is',
    ])
      NodeType(simple, NodeCategory.condition, [
        'true',
        'false',
      ], (c, p, i, r) => checkRule({...c, 'type': simple}, p, i, r)),
    // Gates.
    NodeType('cooldown', NodeCategory.gate, [
      'out',
    ], (c, p, i, _) => _int(c, 'seconds', p, i, min: 1)),
    NodeType('debounce', NodeCategory.gate, [
      'out',
    ], (c, p, i, _) => _int(c, 'ms', p, i, min: 1)),
    // Transformers. Each reads msg.<source> (default payload) and writes msg.<into> (default value).
    NodeType('jsonpath', NodeCategory.transformer, ['out'], (c, p, i, _) {
      _string(c, 'path', p, i);
      i.jsonPath(c['path'], '$p.path');
      _paths(c, p, i);
    }),
    NodeType('regex', NodeCategory.transformer, ['out'], (c, p, i, _) {
      final pattern = _string(c, 'pattern', p, i);
      if (pattern != null) {
        try {
          RegExp(pattern);
        } on FormatException catch (e) {
          i.add(
            '$p.pattern',
            'is not a valid regular expression: ${e.message}',
          );
        }
      }
      _paths(c, p, i);
    }),
    NodeType('range_map', NodeCategory.transformer, ['out'], (c, p, i, _) {
      for (final k in ['inMin', 'inMax', 'outMin', 'outMax']) {
        if (c[k] is! num) i.add('$p.$k', 'must be a number');
      }
      if (c['inMin'] is num && c['inMin'] == c['inMax']) {
        i.add(p, 'inMin and inMax must differ');
      }
      _paths(c, p, i);
    }),
    NodeType('math', NodeCategory.transformer, ['out'], (c, p, i, _) {
      _string(c, 'expression', p, i);
      _paths(c, p, i);
    }),
    // Flow control.
    NodeType('delay', NodeCategory.flowControl, [
      'out',
    ], (c, p, i, _) => _int(c, 'ms', p, i, min: 0, max: 86400000)),
    NodeType('wait_for_event', NodeCategory.flowControl, ['event', 'timeout'], (
      c,
      p,
      i,
      _,
    ) {
      _string(c, 'event', p, i);
      _int(c, 'timeoutMs', p, i, min: 1, max: 86400000);
    }),
    NodeType('repeat', NodeCategory.flowControl, [
      'body',
      'done',
    ], (c, p, i, _) => _int(c, 'maxIterations', p, i, min: 1, max: 1000)),
    // Actions.
    NodeType('device_capability', NodeCategory.action, [
      'out',
      'error',
    ], _checkDeviceAction),
    NodeType('device_toggle', NodeCategory.action, [
      'out',
      'error',
    ], _checkToggle),
    NodeType('set_variable', NodeCategory.action, ['out', 'error'], (
      c,
      p,
      i,
      _,
    ) {
      final name = _string(c, 'name', p, i);
      if (name != null && !_variable.hasMatch(name)) {
        i.add('$p.name', r'must be $Name (global) or %name (run)');
      }
      if (!c.containsKey('value')) i.add('$p.value', 'is required');
      _templates(c['value'], '$p.value', i);
    }),
    NodeType('run_flow', NodeCategory.action, [
      'out',
      'error',
    ], (c, p, i, r) => _ref(c, 'flowId', r.flows, 'flow', p, i)),
    NodeType('notify', NodeCategory.action, ['out', 'error'], (c, p, i, _) {
      _string(c, 'title', p, i);
      _templates(c, p, i);
    }),
    NodeType('speak', NodeCategory.action, ['out', 'error'], (c, p, i, _) {
      _string(c, 'text', p, i);
      _templates(c, p, i);
    }),
  ])
    t.type: t,
};

final _variable = RegExp(r'^[$%][A-Za-z_][A-Za-z0-9_]*$');

/// A toggle flips a device's on/off capability, so the capability must be
/// a toggle that reports its state.
void _checkToggle(
  Map<String, Object?> c,
  String p,
  IssueCollector i,
  FlowReferences r,
) {
  final deviceId = _ref(c, 'deviceId', r.devices, 'device', p, i);
  final capabilityId = _string(c, 'capabilityId', p, i);
  if (deviceId == null || capabilityId == null) return;
  if (!r.devices.contains(deviceId)) return;
  final capability = r.capabilityOf(deviceId, capabilityId);
  if (capability == null) {
    i.add('$p.capabilityId', '$deviceId has no capability $capabilityId');
  } else if (capability.type != CapabilityType.toggle ||
      capability.stateJsonPath == null) {
    i.add(
      '$p.capabilityId',
      '$capabilityId is not an on/off toggle with state',
    );
  }
}

void _checkDeviceAction(
  Map<String, Object?> c,
  String p,
  IssueCollector i,
  FlowReferences r,
) {
  final deviceId = _ref(c, 'deviceId', r.devices, 'device', p, i);
  final capabilityId = _string(c, 'capabilityId', p, i);
  final params = c['params'] ?? const {};
  if (params is! Map) {
    i.add('$p.params', 'must be an object');
    return;
  }
  _templates(params, '$p.params', i);
  if (deviceId == null ||
      capabilityId == null ||
      !r.devices.contains(deviceId)) {
    return;
  }
  final capability = r.capabilityOf(deviceId, capabilityId);
  if (capability == null) {
    i.add('$p.capabilityId', '$deviceId has no capability $capabilityId');
    return;
  }
  // Literal params are checked now. A templated one is checked when it runs.
  final literal = {
    for (final e in params.entries)
      if (!(e.value is String && (e.value as String).contains('{{')))
        e.key as String: e.value,
  };
  for (final key in literal.keys) {
    if (!capability.params.containsKey(key)) {
      i.add('$p.params.$key', 'is not a param of $capabilityId');
    }
  }
  for (final e in capability.params.entries) {
    final value = literal[e.key];
    if (value == null) {
      if (!e.value.optional && !params.containsKey(e.key)) {
        i.add('$p.params.${e.key}', 'is required');
      }
      continue;
    }
    final problem = e.value.check(value);
    if (problem != null) i.add('$p.params.${e.key}', problem);
  }
}

/// Checks one condition rule, recursing into all_of, any_of, xor and not.
void checkRule(Object? rule, String p, IssueCollector i, FlowReferences r) {
  if (rule is! Map) {
    i.add(p, 'a rule must be an object');
    return;
  }
  final c = Map<String, Object?>.from(rule);
  switch (c['type']) {
    case 'all_of' || 'any_of' || 'xor':
      final rules = c['rules'];
      if (rules is! List || rules.isEmpty) {
        i.add('$p.rules', 'needs at least one rule');
        return;
      }
      for (var k = 0; k < rules.length; k++) {
        checkRule(rules[k], '$p.rules[$k]', i, r);
      }
    case 'not':
      checkRule(c['rule'], '$p.rule', i, r);
    case 'time_window':
      _time(c, 'start', p, i);
      _time(c, 'end', p, i);
    case 'var_equals':
      _variableName(c, p, i);
      if (!c.containsKey('value')) i.add('$p.value', 'is required');
    case 'var_compare':
      _variableName(c, p, i);
      _oneOf(c, 'op', _compareOps, p, i);
      if (c['value'] is! num) i.add('$p.value', 'must be a number');
    case 'device_state_is':
      _ref(c, 'deviceId', r.devices, 'device', p, i);
      _string(c, 'key', p, i);
      if (!c.containsKey('value')) i.add('$p.value', 'is required');
    default:
      i.add('$p.type', 'unknown rule type ${c['type']}');
  }
}

final _msgField = RegExp(r'^msg\.[A-Za-z_][A-Za-z0-9_]*$');

void _variableName(Map<String, Object?> c, String p, IssueCollector i) {
  final name = _string(c, 'name', p, i);
  if (name != null && !_variable.hasMatch(name) && !_msgField.hasMatch(name)) {
    i.add('$p.name', r'must be $Name, %name or msg.key');
  }
}

String? _string(
  Map<String, Object?> c,
  String key,
  String p,
  IssueCollector i,
) => i.requiredString(c, key, p);

void _optionalString(
  Map<String, Object?> c,
  String key,
  String p,
  IssueCollector i,
) => i.optionalString(c, key, p);

void _int(
  Map<String, Object?> c,
  String key,
  String p,
  IssueCollector i, {
  int? min,
  int? max,
}) {
  if (c[key] == null) {
    i.add('$p.$key', 'is required');
    return;
  }
  i.optionalInt(c, key, p, min: min, max: max);
}

void _time(Map<String, Object?> c, String key, String p, IssueCollector i) {
  final v = c[key];
  if (v is! String || !_hhmm.hasMatch(v)) {
    i.add('$p.$key', 'must be a 24-hour time like 18:00');
  }
}

void _oneOf(
  Map<String, Object?> c,
  String key,
  List<String> options,
  String p,
  IssueCollector i,
) {
  if (!options.contains(c[key])) {
    i.add('$p.$key', 'must be one of ${options.join(', ')}');
  }
}

String? _ref(
  Map<String, Object?> c,
  String key,
  Set<String> known,
  String what,
  String p,
  IssueCollector i,
) {
  final id = _string(c, key, p, i);
  if (id != null && !known.contains(id)) i.add('$p.$key', 'no $what $id');
  return id;
}

void _paths(Map<String, Object?> c, String p, IssueCollector i) {
  for (final k in ['source', 'into']) {
    final v = c[k];
    if (v != null &&
        (v is! String ||
            !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*$')
                .hasMatch(v))) {
      i.add('$p.$k', 'must be a dotted msg path like payload.temp');
    }
  }
}

void _templates(Object? value, String p, IssueCollector i) {
  try {
    placeholdersIn(value);
  } on TemplateException catch (e) {
    i.add(p, e.message);
  }
}
