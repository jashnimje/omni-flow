import 'engine_core.dart';
import '../dag/flow.dart';
import '../dag/hold_triggers.dart';
import '../dag/people_triggers.dart' show personDriver;
import '../storage/database.dart';

/// What the flow engine reads from the stored home for held triggers,
/// people triggers and the skips of automations that do not run.
mixin EngineRulesHost implements RulesHost {
  EngineCore get rulesCore;

  @override
  Future<List<({DateTime at, Object? value})>> stateHistory(
    String thing,
    String key,
  ) async => [
    for (final e in await DriftHistoryStore(
      rulesCore.db,
    ).recent(thing, key: key, limit: 50))
      (at: e.at, value: e.value),
  ];

  @override
  Future<Set<String>> people() async => {
    for (final d in await DriftDeviceStore(rulesCore.db).all())
      if (d.driverId == personDriver) d.id,
  };

  @override
  Future<List<(FlowSpec, String)>> idleFlows() async {
    final out = <(FlowSpec, String)>[];
    for (final r in await DriftFlowStore(rulesCore.db).all()) {
      if (r.enabled && r.approved) continue;
      try {
        out.add((
          FlowSpec.parse(r.json),
          r.enabled ? 'waiting_approval' : 'off',
        ));
      } catch (_) {
        // A flow that does not parse is a load issue, not a skip.
      }
    }
    return out;
  }
}
