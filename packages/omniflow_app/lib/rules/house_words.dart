import '../api/house_calls.dart';
import 'rule_spec.dart';

/// The words for the triggers, checks and steps on the things the engine
/// itself is (the house mode and the timers), in the engine's wording.

bool isHouseThing(String id) =>
    id == HouseCalls.modeThing || id == HouseCalls.timersThing;

/// "The mode changes to Night", "Timer Pasta ends", or null for any other
/// trigger.
String? houseTriggerText(OnTrigger t) {
  if (t.mode != OnMode.event) return null;
  final match = t.match ?? const {};
  if (t.thing == HouseCalls.modeThing && t.key == 'changed') {
    final mode = match['mode'];
    return mode is String
        ? 'The mode changes to ${modeName(mode)}'
        : 'The mode changes';
  }
  if (t.thing == HouseCalls.timersThing && t.key == 'ended') {
    final timer = match['timer'];
    return timer is String ? 'Timer ${modeName(timer)} ends' : 'A timer ends';
  }
  return null;
}

/// "The mode is Away", or null for any other check.
String? houseConditionText(CompareCondition c) {
  if (c.source != 'state' || c.ref != '${HouseCalls.modeThing}.mode') {
    return null;
  }
  final value = c.value;
  if (value is! String) return null;
  return switch (c.op) {
    '==' => 'The mode is ${modeName(value)}',
    '!=' => 'The mode is not ${modeName(value)}',
    _ => null,
  };
}

/// "Start a 20 min timer called Pasta", or null for any other step.
String? houseStepText(DoStep s) {
  final name = s.params['name'];
  if (s.thing == HouseCalls.modeThing && s.capability == 'set') {
    final mode = s.params['mode'];
    return mode is String
        ? 'Set the mode to ${modeName(mode)}'
        : 'Set the mode';
  }
  if (s.thing != HouseCalls.timersThing) return null;
  return switch (s.capability) {
    'start' =>
      'Start a ${durationText((s.params['ms'] as num?)?.toInt() ?? 0)} '
          'timer called $name',
    'cancel' => 'Cancel timer $name',
    'pause' => 'Pause timer $name',
    'resume' => 'Resume timer $name',
    _ => null,
  };
}
