import 'dart:convert';

import 'engine_core.dart';
import '../dag/canonical.dart';
import '../dag/flow.dart';
import '../dag/flow_engine.dart';
import '../dag/node_types.dart';
import '../dag/validator.dart';
import '../devices/board.dart';
import '../manifest/driver_registry.dart';
import '../storage/database.dart';
import '../zones/zones.dart';

/// The stored flows and zones as the flow engine runs them: the trust mark
/// and revision of each flow, which flows are high risk, and reloading
/// what is enabled and approved.
class StoredFlows {
  StoredFlows(this._core);

  final EngineCore _core;

  OmniDatabase get _db => _core.db;
  DriverRegistry get _registry => _core.registry;
  FlowEngine get _flows => _core.flows;

  Future<void> loadState() async {
    _flows.globals.addAll(await DriftGlobalStore(_db).all());
    for (final d in await DriftDeviceStore(_db).all()) {
      _flows.deviceStates[d.id] = d.state;
    }
    await reloadZones();
    await reloadFlows();
  }

  Future<void> reloadZones() async {
    final zones = <ZoneSpec>[];
    final issues = <Map<String, Object?>>[];
    for (final z in await DriftZoneStore(_db).all()) {
      try {
        zones.add(ZoneSpec.parse(z));
      } catch (e) {
        issues.add(loadIssue('zone', z['id'], e));
      }
    }
    _flows.setZones(zones);
    _core.setIssues('zone', issues);
  }

  /// The flow JSON of a stored record, as a copy the caller may change.
  static Map<String, Object?> flowJsonOf(FlowRecord r) => {...r.json};

  /// Whether the user saved or approved this version of the flow.
  static bool trustedOf(FlowRecord? r) => r?.trusted ?? false;

  /// What the user reviews before approving: a hash of the flow JSON.
  static String revisionOf(Map<String, Object?> flowJson) =>
      sha256Hex(canonicalJson(flowJson));

  Future<void> put(
    String id,
    Map<String, Object?> flowJson, {
    required bool enabled,
    required bool approved,
    required bool trusted,
  }) => DriftFlowStore(_db).put(
    id,
    flowJson,
    enabled: enabled,
    approved: approved,
    trusted: trusted,
    at: DateTime.now().toUtc(),
  );

  /// Every stored flow that parses, by id. The rest are load issues.
  Future<(List<FlowRecord>, Map<String, FlowSpec>, List<Map<String, Object?>>)>
  stored() async {
    final records = await DriftFlowStore(_db).all();
    final specs = <String, FlowSpec>{};
    final issues = <Map<String, Object?>>[];
    for (final r in records) {
      try {
        specs[r.json['id'] as String] = FlowSpec.parse(flowJsonOf(r));
      } catch (e) {
        issues.add(loadIssue('flow', r.json['id'], e));
      }
    }
    return (records, specs, issues);
  }

  /// Loads every enabled, approved flow. An untrusted flow that became high
  /// risk after it was approved (a device or driver under it now runs host
  /// commands) loses its approval and waits for the user again.
  Future<void> reloadFlows() async {
    final (records, specs, issues) = await stored();
    final risky = await highRiskFlows(specs.values);
    final load = <FlowSpec>[];
    for (final r in records) {
      final spec = specs[r.json['id']];
      if (spec == null) continue;
      var approved = r.approved;
      if (approved && !trustedOf(r) && risky.contains(spec.id)) {
        approved = false;
        await put(
          spec.id,
          flowJsonOf(r),
          enabled: r.enabled,
          approved: false,
          trusted: false,
        );
        _core.emit({'event': 'flow.approvalRevoked', 'flow': spec.id});
      }
      if (r.enabled && approved) load.add(spec);
    }
    for (final e in _flows.load(load).entries) {
      issues.add({'kind': 'flow', 'id': e.key, 'error': e.value});
    }
    _core.setIssues('flow', issues);
  }

  Future<FlowReferences> references() async {
    final devices = {
      for (final d in await DriftDeviceStore(_db).all())
        d.id: manifestFor(_registry, d),
    };
    final (_, specs, _) = await stored();
    return FlowReferences(
      devices: devices.keys.toSet(),
      zones: {
        for (final z in await DriftZoneStore(_db).all()) z['id'] as String,
      },
      flows: {
        for (final f in await DriftFlowStore(_db).all()) f.json['id'] as String,
      },
      capabilityOf: (d, c) => devices[d]?.capability(c),
      calls: {for (final f in specs.values) f.id: runFlowTargets(f)},
    );
  }

  /// True when [flow], saved over the stored flows, would be high risk.
  Future<bool> isHighRisk(FlowSpec flow) async {
    final (_, specs, _) = await stored();
    return (await highRiskFlows({...specs, flow.id: flow}.values))
        .contains(flow.id);
  }

  static final _globalRef = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)');

  /// The ids of the high-risk flows among [all]: a flow that drives a device
  /// whose driver runs host commands, that starts a high-risk flow with
  /// run_flow (it could pass arguments the target renders), or that sets a
  /// global a high-risk flow reads.
  Future<Set<String>> highRiskFlows(Iterable<FlowSpec> all) async {
    final drivers = {
      for (final d in await DriftDeviceStore(_db).all()) d.id: d.driverId,
    };
    final risky = {
      for (final f in all)
        if (f.nodes.any(
          (n) =>
              (n.type == 'device_capability' || n.type == 'device_toggle') &&
              (_registry[drivers[n.config['deviceId']] ?? '']?.isHighRisk ??
                  false),
        ))
          f.id,
    };
    Set<String> written(FlowSpec f) => {
      for (final n in f.nodes)
        if (n.type == 'set_variable' &&
            n.config['name'] is String &&
            (n.config['name'] as String).startsWith(r'$'))
          (n.config['name'] as String).substring(1),
    };
    Set<String> read(FlowSpec f) => {
      for (final n in f.nodes)
        for (final m in _globalRef.allMatches(
          jsonEncode(
            n.type == 'set_variable'
                ? ({...n.config}..remove('name'))
                : n.config,
          ),
        ))
          m.group(1)!,
    };
    for (var grew = true; grew;) {
      grew = false;
      final readByRisky = {
        for (final f in all)
          if (risky.contains(f.id)) ...read(f),
      };
      for (final f in all) {
        if (risky.contains(f.id)) continue;
        if (runFlowTargets(f).any(risky.contains) ||
            written(f).any(readByRisky.contains)) {
          grew = risky.add(f.id);
        }
      }
    }
    return risky;
  }
}
