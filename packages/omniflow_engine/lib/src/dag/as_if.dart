/// "Try as if": a made-up event for one trigger of a rule, for a dry run
/// that starts from that trigger.
library;

/// The trigger node a rule's `when[index]` compiles to.
String ruleTriggerNodeId(int index) => 'when_$index';

/// What a run started by the rule trigger [t] (its stored form) gets, as
/// if it had just happened: the device and the value it changed to, the
/// event and the details it matches, the person who came home, the time.
Map<String, Object?> asIfMessage(Map<String, Object?> t, {DateTime? at}) {
  final ref = t['on'];
  if (ref is String && ref.contains('.')) {
    final dot = ref.indexOf('.');
    final thing = ref.substring(0, dot);
    final key = ref.substring(dot + 1);
    final base = {'thing': thing, 'deviceId': thing, 'device': thing};
    if (t['event'] == true) {
      final match = t['match'];
      return {
        ...base,
        'key': key,
        'payload': {if (match is Map) ...match},
        'asIf': true,
      };
    }
    final (value, previous) = _change(t);
    return {
      ...base,
      'key': key,
      'value': value,
      'previous': previous,
      'payload': {key: value},
      if (t['for'] is int) 'heldMs': t['for'],
      'asIf': true,
    };
  }
  if (t['people'] != null) {
    return {'person': 'someone', 'asIf': true};
  }
  final when = at ?? DateTime.now();
  if (t['time'] != null || t['sun'] != null || t['interval'] != null) {
    return {'scheduled': when.toIso8601String(), 'asIf': true};
  }
  return {'asIf': true};
}

/// The value a state trigger changes to and from: its `change.to` and the
/// opposite, just past its `crosses` limit, or on from off.
(Object?, Object?) _change(Map<String, Object?> t) {
  final crosses = t['crosses'];
  if (crosses is Map && crosses.isNotEmpty) {
    final limit = crosses.values.single;
    if (limit is num) {
      return crosses.keys.single == 'above'
          ? (limit + 1, limit)
          : (limit - 1, limit);
    }
  }
  final change = t['change'];
  if (change is Map && change.containsKey('to')) {
    final to = change['to'];
    return (to, to is bool ? !to : null);
  }
  return (true, false);
}
