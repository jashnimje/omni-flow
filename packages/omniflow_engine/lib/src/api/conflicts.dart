import '../dag/canonical.dart';

/// Two automations that set one device capability to different values
/// when the same thing happens: one undoes the other, and which wins is
/// down to timing.
class AutomationConflict {
  const AutomationConflict({
    required this.a,
    required this.b,
    required this.thing,
    required this.capability,
    required this.paramsA,
    required this.paramsB,
    required this.triggerLabel,
  });

  final String a;
  final String b;
  final String thing;
  final String capability;
  final Map<String, Object?> paramsA;
  final Map<String, Object?> paramsB;

  /// The shared trigger's words, from the first automation.
  final String triggerLabel;
}

/// What a trigger node waits for, to tell whether two can fire together:
/// the same thing and key with changes that can be the same change, the
/// same time of day (whatever the days), the same sun time, the same
/// people change, or the engine starting. Manual and interval triggers
/// never count.
String? _triggerKey(Map<String, Object?> node) {
  final c = node['config'] is Map
      ? Map<String, Object?>.from(node['config'] as Map)
      : const <String, Object?>{};
  switch (node['type']) {
    case 'on':
      return 'on:${c['thing']}.${c['key']}';
    case 'time_of_day':
      return 'time:${c['at']}';
    case 'sun':
      return 'sun:${c['event']}:${c['offsetMinutes'] ?? 0}';
    case 'people_change':
      return 'people:${c['when']}';
    case 'engine_started':
      return 'engine_started';
  }
  return null;
}

/// Whether two `on` triggers on the same key can fire on one change: both
/// events, or both state changes whose targets do not rule each other out
/// (on and off, above and below).
bool _onOverlaps(Map<String, Object?> a, Map<String, Object?> b) {
  if ((a['event'] == true) != (b['event'] == true)) return false;
  if (a['event'] == true) return true;
  String shape(Map<String, Object?> c) {
    if (c['crosses'] is Map) {
      return 'crosses:${(c['crosses'] as Map).keys.single}';
    }
    final change = c['change'];
    if (change is Map && change.containsKey('to')) {
      return 'to:${canonicalJson(change['to'])}';
    }
    return 'any';
  }

  final sa = shape(a);
  final sb = shape(b);
  return sa == 'any' || sb == 'any' || sa == sb;
}

Map<String, Object?> _config(Map<String, Object?> node) => node['config'] is Map
    ? Map<String, Object?>.from(node['config'] as Map)
    : const {};

Iterable<Map<String, Object?>> _nodes(Map<String, Object?> flow) => [
  for (final n in (flow['nodes'] as List? ?? const []))
    if (n is Map) Map<String, Object?>.from(n),
];

/// Every pair of [flows] (enabled flow JSON, by id) that sets a device
/// capability to different values on overlapping triggers.
List<AutomationConflict> findConflicts(
  Map<String, Map<String, Object?>> flows,
) {
  final out = <AutomationConflict>[];
  final ids = flows.keys.toList()..sort();
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final a = flows[ids[i]]!;
      final b = flows[ids[j]]!;
      final shared = _sharedTrigger(a, b);
      if (shared == null) continue;
      final setsA = _sets(a);
      final setsB = _sets(b);
      for (final e in setsA.entries) {
        final other = setsB[e.key];
        if (other == null || canonicalJson(other) == canonicalJson(e.value)) {
          continue;
        }
        final dot = e.key.indexOf('.');
        out.add(
          AutomationConflict(
            a: ids[i],
            b: ids[j],
            thing: e.key.substring(0, dot),
            capability: e.key.substring(dot + 1),
            paramsA: e.value,
            paramsB: other,
            triggerLabel: shared,
          ),
        );
      }
    }
  }
  return out;
}

/// The label of a trigger of [a] that overlaps one of [b], or null.
String? _sharedTrigger(Map<String, Object?> a, Map<String, Object?> b) {
  for (final ta in _nodes(a)) {
    final key = _triggerKey(ta);
    if (key == null) continue;
    for (final tb in _nodes(b)) {
      if (_triggerKey(tb) != key) continue;
      if (ta['type'] == 'on' && !_onOverlaps(_config(ta), _config(tb))) {
        continue;
      }
      return '${ta['label'] ?? ta['id']}';
    }
  }
  return null;
}

/// What [flow] sets, by `thing.capability`: the params of each device
/// step. A step whose device or params come from a template, or that sets
/// one capability two ways, is left out, since its value is not fixed.
Map<String, Map<String, Object?>> _sets(Map<String, Object?> flow) {
  final out = <String, Map<String, Object?>>{};
  final mixed = <String>{};
  for (final n in _nodes(flow)) {
    if (n['type'] != 'device_capability') continue;
    final c = _config(n);
    final thing = c['deviceId'];
    final capability = c['capabilityId'];
    final params = c['params'] is Map
        ? Map<String, Object?>.from(c['params'] as Map)
        : const <String, Object?>{};
    if (thing is! String || capability is! String || thing.contains('{{')) {
      continue;
    }
    if (canonicalJson(params).contains('{{')) continue;
    final key = '$thing.$capability';
    if (out.containsKey(key) &&
        canonicalJson(out[key]) != canonicalJson(params)) {
      mixed.add(key);
    }
    out[key] = params;
  }
  return {
    for (final e in out.entries)
      if (!mixed.contains(e.key)) e.key: e.value,
  };
}
