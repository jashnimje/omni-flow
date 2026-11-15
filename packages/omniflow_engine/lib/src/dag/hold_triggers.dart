import '../manifest/validation.dart';
import 'conditions.dart' show valuesEqual;
import 'flow.dart';

/// The longest a state trigger may wait for a state to hold: a week.
const holdLimitMs = 7 * 24 * 3600 * 1000;

/// What the flow engine reads from the rest of the engine for held state
/// triggers, people triggers and skipped runs. A host without it still runs
/// every flow: held triggers then never resume after a restart, people
/// come from the states that look like a person's, and an automation that
/// is off records no skips.
abstract interface class RulesHost {
  /// The changes of [key] on [thing], newest first.
  Future<List<({DateTime at, Object? value})>> stateHistory(
    String thing,
    String key,
  );

  /// The person things.
  Future<Set<String>> people();

  /// The stored automations that do not run, with why: `off` for one that
  /// is turned off, `waiting_approval` for one waiting for the user.
  Future<List<(FlowSpec, String)>> idleFlows();
}

/// Whether [value] is the state an `on` trigger [config] waits to hold:
/// the value of `change.to`, or a number past `crosses`. Null when the
/// trigger has no state to hold (an event, or any change).
bool? holdsNow(Map<String, Object?> config, Object? value) {
  final crosses = config['crosses'];
  if (crosses is Map) {
    final above = crosses['above'];
    final below = crosses['below'];
    if (value is! num) return false;
    return above is num ? value > above : value < (below as num);
  }
  final change = config['change'];
  if (change is Map && change.containsKey('to')) {
    return valuesEqual(value, change['to']);
  }
  return null;
}

/// How long an `on` trigger [config] waits for its state to hold, or null.
Duration? holdOf(Map<String, Object?> config) => config['forMs'] is int
    ? Duration(milliseconds: config['forMs'] as int)
    : null;

/// When the state in [history] (newest first) started to hold for
/// [config]: the oldest change of the newest run of changes that hold.
/// Null when the newest change does not hold, or there is none.
DateTime? heldSince(
  Map<String, Object?> config,
  List<({DateTime at, Object? value})> history,
) {
  DateTime? since;
  for (final h in history) {
    if (holdsNow(config, h.value) != true) break;
    since = h.at;
  }
  return since;
}

/// Checks an `on` node's `forMs`: whole milliseconds up to [holdLimitMs],
/// on a trigger that has a state to hold.
void checkHeldOn(Map<String, Object?> c, String p, IssueCollector i) {
  final ms = c['forMs'];
  if (ms == null) return;
  if (ms is! int || ms < 1 || ms > holdLimitMs) {
    i.add('$p.forMs', 'must be whole milliseconds from 1 to $holdLimitMs');
  }
  if (c['event'] == true || holdsNow(c, null) == null) {
    i.add('$p.forMs', 'needs a state to hold: a change to a value, or crosses');
  }
}

/// The words for [ms], for a held trigger: "5 min", "1 h", "30 s".
String holdWords(int ms) {
  if (ms > 0 && ms % 3600000 == 0) return '${ms ~/ 3600000} h';
  if (ms > 0 && ms % 60000 == 0) return '${ms ~/ 60000} min';
  if (ms % 1000 == 0) return '${ms ~/ 1000} s';
  return '$ms ms';
}
