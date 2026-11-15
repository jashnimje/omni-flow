import 'conditions.dart';

/// Why a trigger fired and nothing ran. A [condition] said no, the
/// automation was [off], [waitingApproval], in its [cooldown], already
/// [running] (single mode), had too many runs going or waiting ([busy],
/// [queueFull]), you were already being asked ([asking]), you said not now
/// ([declined]) or did not answer ([unanswered]), or it [changed] before
/// it could run.
abstract final class SkipKind {
  static const condition = 'condition';
  static const off = 'off';
  static const waitingApproval = 'waiting_approval';
  static const cooldown = 'cooldown';
  static const running = 'running';
  static const busy = 'busy';
  static const queueFull = 'queue_full';
  static const asking = 'asking';
  static const declined = 'declined';
  static const unanswered = 'unanswered';
  static const changed = 'changed';

  /// The kind for a dropped run's reason, as the runner and ask-first
  /// write it.
  static String ofDropReason(String? reason) => switch (reason) {
    'cooldown' => cooldown,
    'running' => running,
    'too_many_runs' => busy,
    'queue_full' => queueFull,
    'it is already asking you' => asking,
    'you chose not now' => declined,
    'not answered' => unanswered,
    _ => changed,
  };
}

/// One trigger that fired without a run: when, which trigger node and its
/// words, why, and for a [SkipKind.condition] the part of the condition
/// that said no (`rule`) with the value it saw (`actual`).
class SkipEntry {
  const SkipEntry({
    required this.at,
    required this.flowId,
    required this.trigger,
    required this.triggerLabel,
    required this.kind,
    this.stop,
  });

  final DateTime at;
  final String flowId;
  final String trigger;
  final String? triggerLabel;
  final String kind;

  /// `{node, rule, actual?}` for a condition.
  final Map<String, Object?>? stop;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'flow': flowId,
    'trigger': trigger,
    'triggerLabel': ?triggerLabel,
    'kind': kind,
    'stop': ?stop,
  };
}

/// The last skipped triggers of each automation, newest first, in memory.
/// They are gone after a restart, which is when people stop asking about
/// them.
class SkipLog {
  SkipLog({this.perFlow = 20, this.maxFlows = 500});

  final int perFlow;

  /// The most automations kept, so removed ones cannot pile up.
  final int maxFlows;
  final _byFlow = <String, List<SkipEntry>>{};

  void add(SkipEntry e) {
    final list = _byFlow.remove(e.flowId) ?? [];
    _byFlow[e.flowId] = list;
    list.insert(0, e);
    if (list.length > perFlow) list.removeRange(perFlow, list.length);
    while (_byFlow.length > maxFlows) {
      _byFlow.remove(_byFlow.keys.first);
    }
  }

  List<SkipEntry> of(String flowId) =>
      List.unmodifiable(_byFlow[flowId] ?? const <SkipEntry>[]);

  void forget(String flowId) => _byFlow.remove(flowId);
}

/// The part of the condition [rule] that made it false under [ctx]: the
/// first false rule of an all_of, the whole rule for an any_of, xor or not
/// (no one part said no), or the rule itself. With `actual`, the value a
/// compare saw on its left. Null when [rule] holds.
Map<String, Object?>? failingPart(Map<String, Object?> rule, EvalContext ctx) {
  if (evaluateRule(rule, ctx)) return null;
  if (rule['type'] == 'all_of') {
    for (final r in (rule['rules'] as List)) {
      final part = failingPart(Map<String, Object?>.from(r as Map), ctx);
      if (part != null) return part;
    }
  }
  return {
    'rule': rule,
    if (rule['type'] == 'compare') 'actual': ctx.value(rule['left']),
  };
}
