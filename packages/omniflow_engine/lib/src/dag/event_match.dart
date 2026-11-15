import '../manifest/capability.dart';
import '../manifest/validation.dart';

/// Checks the `match` of an event trigger against the params its event
/// declares: "20 min before the next alarm" needs whole minutes, a
/// calendar trigger needs its words. An event that declares no params
/// takes any match, as before.
void checkEventMatch(
  Object? match,
  String path,
  IssueCollector issues,
  CapabilitySpec? event,
) {
  if (event == null || event.params.isEmpty) return;
  final given = match is Map ? match : const {};
  for (final MapEntry(:key, value: spec) in event.params.entries) {
    final value = given[key];
    if (value == null) {
      if (!spec.optional) issues.add('$path.$key', 'is required');
      continue;
    }
    if (spec.check(value) case final problem?) {
      issues.add('$path.$key', problem);
    }
  }
}
