/// "Try as if": a made-up event for one trigger of a rule, for a dry run
/// that starts from that trigger.
library;

import 'executor.dart' show FlowEffects;
import 'people_triggers.dart' show PeopleSource;

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

/// [states] with the made-up value of an as-if [msg] laid over the thing
/// it names, so a check that reads the trigger's own state sees it. A
/// message that is not a made-up state change leaves them as they are.
Map<String, Map<String, Object?>> asIfStates(
  Map<String, Map<String, Object?>> states,
  Map<String, Object?> msg,
) {
  final thing = msg['thing'];
  final key = msg['key'];
  if (msg['asIf'] != true ||
      thing is! String ||
      key is! String ||
      !msg.containsKey('value')) {
    return states;
  }
  return {
    ...states,
    thing: {...?states[thing], key: msg['value']},
  };
}

/// The effects a dry run started from [msg] uses: [base], with the
/// made-up value of an as-if message in [FlowEffects.deviceStates].
FlowEffects asIfEffects(FlowEffects base, Map<String, Object?> msg) {
  final states = asIfStates(base.deviceStates, msg);
  return identical(states, base.deviceStates)
      ? base
      : _AsIfEffects(base, states);
}

class _AsIfEffects implements FlowEffects, PeopleSource {
  _AsIfEffects(this._base, this.deviceStates);

  final FlowEffects _base;

  @override
  final Map<String, Map<String, Object?>> deviceStates;

  @override
  Set<String>? get people => switch (_base) {
    final PeopleSource s => s.people,
    _ => null,
  };

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) => _base.invokeDevice(deviceId, capabilityId, params, flowId: flowId);

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) => _base.toggleDevice(deviceId, capabilityId, flowId: flowId);

  @override
  Future<void> runFlow(String flowId, Map<String, Object?> msg) =>
      _base.runFlow(flowId, msg);

  @override
  void announce(Map<String, Object?> payload) => _base.announce(payload);

  @override
  Future<void> setGlobal(String name, Object? value) =>
      _base.setGlobal(name, value);

  @override
  Map<String, Object?> get globals => _base.globals;

  @override
  Stream<Map<String, Object?>> get events => _base.events;

  @override
  Future<Map<String, Object?>?> stateOf(String deviceId) =>
      _base.stateOf(deviceId);

  @override
  Future<List<String>> roomDevices(String room) => _base.roomDevices(room);
}
