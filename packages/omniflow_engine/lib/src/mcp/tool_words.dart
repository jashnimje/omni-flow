import '../api/agent_policy.dart';
import '../api/android_names.dart';
import '../dag/people_triggers.dart';
import '../dag/rules.dart';
import '../dag/templates.dart';
import '../devices/adb/adb_commands.dart' show adbPhoneAgentKeys;
import '../manifest/capability.dart';
import '../manifest/driver_registry.dart';

// The parts of the MCP tool descriptions that state what an agent may do
// and what the rule language holds, built from the agent policy, the rule
// model and the built-in drivers, so a description cannot say something
// the engine does not do.

String _list(Iterable<String> items) => (items.toList()..sort()).join(', ');

/// The level an agent needs for [command]: read, setup, or the user's.
String agentLevelOf(String command) => agentUserOnly.containsKey(command)
    ? 'the user\'s only'
    : agentReadCommands.contains(command)
    ? 'read'
    : agentSetupCommands.contains(command)
    ? 'setup'
    : 'not open to agents';

/// What an agent may do to an Android TV or another person's phone.
String tvAccessWords() {
  final tvSetup = [
    for (final c in agentSetupCommands)
      if (c.startsWith(tvCommandPrefix)) c,
  ];
  final tvUser = [
    for (final c in agentUserOnly.keys)
      if (c.startsWith(tvCommandPrefix)) c,
  ];
  final phoneUser = [
    for (final c in agentPhoneUserOnly.keys)
      if (c.startsWith(tvCommandPrefix)) c,
  ];
  final phoneSetup = [
    for (final c in agentPhoneSetupReads)
      if (c.startsWith(tvCommandPrefix)) c,
  ];
  return 'At setup access you send these yourself with omniflow_call: '
      '${_list(tvSetup)} (tv.app only to open, stop or get info). Always the '
      'user\'s: ${_list(tvUser)}, and tv.app for any other action. On '
      'another person\'s phone (driver android_phone_adb, the same commands '
      'as android.*) these are the user\'s too: ${_list(phoneUser)}, and '
      'tv.key takes only ${_list(adbPhoneAgentKeys)}; these need setup '
      'there: ${_list(phoneSetup)}';
}

/// What a device step does that makes an automation an agent saves wait
/// for the user's approval.
String highRiskWords() {
  final phone = DriverRegistry.withBuiltIns()['phone'];
  final acting = [
    for (final c in phone?.capabilities ?? const <CapabilitySpec>[])
      if (c.highRisk) 'phone.${c.id}',
  ];
  return 'Saved untrusted: a rule waits for the user to approve it when it '
      'drives a host-command device or a driver an agent registered, sends a '
      'web request, changes a TV or phone setting or app, types text or '
      'presses a key that types on a TV or phone, opens an app or a link on '
      'another phone, or runs a phone action that acts on its person '
      '(${_list(acting)}). Such a rule cannot be run by an agent either';
}

/// The rule kinds the rule model takes, by part.
String ruleKindWords() =>
    'Every trigger kind: ${RuleKeys.triggers.join(', ')} (on modes '
    '${RuleKeys.onModes.join(', ')}; people ${peopleTriggerKinds.join(' | ')}; '
    'event ${RuleKeys.engineEvents.join(' | ')}). Every condition kind: '
    '${RuleKeys.conditions.join(', ')} (people '
    '${peopleConditionKinds.join(' | ')}). Every step kind: '
    '${RuleKeys.steps.join(', ')}';

/// The phone thing's events and readings, from its built-in driver.
String phoneThingWords() {
  final phone = DriverRegistry.withBuiltIns()['phone'];
  final caps = phone?.capabilities ?? const <CapabilitySpec>[];
  final events = [
    for (final c in caps)
      if (c.type == CapabilityType.event) c.id,
  ];
  final states = [
    for (final c in caps)
      if (c.type == CapabilityType.sensor) c.id,
  ];
  return 'The phone thing has events ${events.join(', ')} and states '
      '${states.join(', ')}. A notification gives package and label (agents '
      'never see its words), and a calendar event only that its words '
      'matched. At read access ${_list(agentPrivateStateKeys)} and the details '
      'of ${_list(agentPrivateEventKeys)} are left out of what you see: they '
      'say where the person has been and what they do';
}

/// The rule templates by name.
String templateWords() => ruleTemplates.map((t) => t.name).join('; ');
