import '../devices/device_service.dart' show stateKeyOf;
import '../manifest/capability.dart';
import '../manifest/validation.dart';
import '../template/template_renderer.dart';

enum NodeCategory { trigger, condition, gate, transformer, flowControl, action }

/// What a flow may refer to, so the validator can check references.
class FlowReferences {
  const FlowReferences({
    this.capabilityOf = _none,
    this.devices = const {},
    this.flows = const {},
    this.calls = const {},
    this.stateKeysOf = _unknown,
    this.eventsOf = _unknown,
  });

  /// The capability [capabilityId] of device [deviceId], or null.
  final CapabilitySpec? Function(String deviceId, String capabilityId)
  capabilityOf;

  /// Every thing a flow may name: devices, the phone, people, places, tags.
  final Set<String> devices;
  final Set<String> flows;

  /// The flows each stored flow starts with `run_flow`, to find call cycles.
  final Map<String, Set<String>> calls;

  /// The state keys thing [thing] reports, or null when any key is taken.
  final Set<String>? Function(String thing) stateKeysOf;

  /// The events thing [thing] raises, or null when it may raise events its
  /// driver does not declare (a board's firmware lines), so any is taken.
  final Set<String>? Function(String thing) eventsOf;

  static CapabilitySpec? _none(String _, String _) => null;
  static Set<String>? _unknown(String _) => null;
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

/// The built-in node types, keyed by type name.
final Map<String, NodeType> builtInNodeTypes = {
  for (final t in <NodeType>[
    // Triggers.
    NodeType('manual', NodeCategory.trigger, ['out'], (_, _, _, _) {}),
    NodeType('time_of_day', NodeCategory.trigger, ['out'], (c, p, i, _) {
      _time(c, 'at', p, i);
      _dayList(c, 'days', p, i);
    }),
    NodeType('interval', NodeCategory.trigger, [
      'out',
    ], (c, p, i, _) => _int(c, 'seconds', p, i, min: 1)),
    NodeType('on', NodeCategory.trigger, ['out'], _checkOn),
    // Conditions.
    for (final composite in ['all_of', 'any_of', 'xor'])
      NodeType(composite, NodeCategory.condition, [
        'true',
        'false',
      ], (c, p, i, r) => checkRule({...c, 'type': composite}, p, i, r)),
    for (final simple in ['not', 'time_window', 'compare', 'days'])
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
      if (c['round'] != null && c['round'] is! bool) {
        i.add('$p.round', 'is true or false');
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
    // Waits for what an `on` trigger would fire on, or gives up.
    NodeType('wait_until', NodeCategory.flowControl, ['matched', 'timeout'], (
      c,
      p,
      i,
      r,
    ) {
      _checkOn({...c}..remove('timeoutMs'), p, i, r);
      _int(c, 'timeoutMs', p, i, min: 1, max: 86400000);
    }),
    NodeType('repeat', NodeCategory.flowControl, ['body', 'done'], (
      c,
      p,
      i,
      r,
    ) {
      _int(c, 'maxIterations', p, i, min: 1, max: 1000);
      if (c['everyMs'] != null) {
        _int(c, 'everyMs', p, i, min: 0, max: 86400000);
      }
      if (c['until'] != null) checkRule(c['until'], '$p.until', i, r);
    }),
    // Every branch edge runs side by side, then done once all have ended.
    NodeType('parallel', NodeCategory.flowControl, [
      'branch',
      'done',
    ], (_, _, _, _) {}),
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
      stateKeyOf(capability.stateJsonPath) == null) {
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
    case 'days':
      _dayList(c, 'days', p, i, required: true);
    case 'compare':
      _oneOf(c, 'op', compareOps, p, i);
      _value(c['left'], '$p.left', i, r);
      _value(c['right'], '$p.right', i, r);
      if (const {'<', '<=', '>', '>='}.contains(c['op'])) {
        for (final side in ['left', 'right']) {
          final v = c[side];
          if (v is Map && v.containsKey('literal') && v['literal'] is! num) {
            i.add('$p.$side.literal', 'must be a number for ${c['op']}');
          }
        }
      }
    default:
      i.add('$p.type', 'unknown rule type ${c['type']}');
  }
}

/// The comparison operators of `compare`.
const compareOps = ['<', '<=', '>', '>=', '==', '!='];

/// The ways `compare` reads a value, each the only key of its object.
const compareSources = ['literal', 'state', 'msg', 'var'];

final _msgPath = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*$');

/// A `thing.key` reference: the thing, then its (possibly dotted) key.
final thingKeyPattern = RegExp(r'^([a-z][a-z0-9_]*)\.(\S+)$');

void _value(Object? v, String p, IssueCollector i, FlowReferences r) {
  if (v is! Map || v.length != 1 || !compareSources.contains(v.keys.single)) {
    i.add(
      p,
      'must be one of {literal}, {state: "thing.key"}, {msg: "key"}, {var: "\$Name"}',
    );
    return;
  }
  final source = v.keys.single as String;
  final ref = v[source];
  switch (source) {
    case 'state':
      final m = ref is String ? thingKeyPattern.firstMatch(ref) : null;
      if (m == null) {
        i.add('$p.state', 'must be thing.key, like jade.home');
        return;
      }
      _thingKey(m.group(1)!, m.group(2)!, '$p.state', i, r, event: false);
    case 'msg':
      if (ref is! String || !_msgPath.hasMatch(ref)) {
        i.add('$p.msg', 'must be a message key like value or payload.temp');
      }
    case 'var':
      if (ref is! String || !_variable.hasMatch(ref)) {
        i.add('$p.var', r'must be $Name (global) or %name (run)');
      }
  }
}

/// Checks that [thing] exists and has the state key or event [key].
void _thingKey(
  String thing,
  String key,
  String p,
  IssueCollector i,
  FlowReferences r, {
  required bool event,
}) {
  if (!r.devices.contains(thing)) {
    i.add(p, 'no thing $thing');
    return;
  }
  final known = event ? r.eventsOf(thing) : r.stateKeysOf(thing);
  if (known == null || known.contains(key)) return;
  final what = event ? 'event' : 'state';
  i.add(
    p,
    known.isEmpty
        ? '$thing has no $what $key, and no ${what}s at all'
        : '$thing has no $what $key (it has ${(known.toList()..sort()).join(', ')})',
  );
}

/// An `on` trigger: an event, a state change (optionally to one value), or
/// a number crossing a threshold, on one thing.
void _checkOn(
  Map<String, Object?> c,
  String p,
  IssueCollector i,
  FlowReferences r,
) {
  final thing = _string(c, 'thing', p, i);
  final key = c['key'];
  if (key != null && (key is! String || key.isEmpty)) {
    i.add('$p.key', 'must be a non-empty string');
    return;
  }
  final modes = [
    for (final m in ['event', 'change', 'crosses'])
      if (c[m] != null) m,
  ];
  if (modes.length > 1) {
    i.add(
      p,
      'takes one of event, change or crosses, not ${modes.join(' and ')}',
    );
    return;
  }
  final mode = modes.firstOrNull ?? 'change';
  if (c['match'] != null && mode != 'event') {
    i.add('$p.match', 'is only for an event');
  }
  switch (mode) {
    case 'event':
      if (c['event'] != true) i.add('$p.event', 'must be true');
      final match = c['match'];
      if (match != null && match is! Map) {
        i.add('$p.match', 'must be an object of payload values');
      }
    case 'change':
      final change = c['change'];
      if (change != null &&
          (change is! Map || change.keys.any((k) => k != 'to'))) {
        i.add('$p.change', 'must be {} or {"to": value}');
      }
      if (change is Map && change.containsKey('to') && key == null) {
        i.add('$p.key', 'is required to change to a value');
      }
    case 'crosses':
      final crosses = c['crosses'];
      if (crosses is! Map ||
          crosses.length != 1 ||
          !const {'above', 'below'}.contains(crosses.keys.single) ||
          crosses.values.single is! num) {
        i.add('$p.crosses', 'must be {"above": number} or {"below": number}');
      }
  }
  if (key == null && mode != 'change') {
    i.add(
      '$p.key',
      'is required for ${mode == 'event' ? 'an event' : 'crosses'}',
    );
  }
  if (thing == null) return;
  if (!r.devices.contains(thing)) {
    i.add('$p.thing', 'no thing $thing');
  } else if (key != null) {
    _thingKey(thing, key as String, '$p.key', i, r, event: mode == 'event');
  }
}

void _dayList(
  Map<String, Object?> c,
  String key,
  String p,
  IssueCollector i, {
  bool required = false,
}) {
  final days = c[key];
  if (days == null && !required) return;
  if (days is! List || days.isEmpty || days.any((d) => !_days.contains(d))) {
    i.add('$p.$key', 'must be a non-empty list of ${_days.join(', ')}');
  }
}

String? _string(
  Map<String, Object?> c,
  String key,
  String p,
  IssueCollector i,
) => i.requiredString(c, key, p);

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
