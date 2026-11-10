import 'dart:convert';

import 'api_error.dart';
import 'engine_core.dart';
import 'things_runtime.dart';
import '../dag/canonical.dart';
import '../dag/flow.dart';
import '../dag/flow_engine.dart';
import '../dag/links.dart';
import '../dag/migrate.dart';
import '../dag/node_types.dart';
import '../dag/validator.dart';
import '../devices/adb/adb_commands.dart' show adbCommandIsHighRisk;
import '../devices/board.dart';
import '../devices/device_service.dart' show stateKeyOf;
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../storage/database.dart';

/// The stored flows as the flow engine runs them: the trust mark and
/// revision of each flow, which flows are high risk, migrating flows from
/// retired node types, and reloading what is enabled and approved.
class StoredFlows {
  StoredFlows(this._core, this._things);

  final EngineCore _core;
  final ThingsRuntime _things;

  /// The phone, people and places, which rule shorthand resolves against.
  ThingsRuntime get things => _things;

  /// Why a stored flow still on retired node types could not be migrated.
  final _migrationErrors = <String, String>{};

  OmniDatabase get _db => _core.db;
  DriverRegistry get _registry => _core.registry;
  FlowEngine get _flows => _core.flows;

  Future<void> loadState() async {
    _flows.globals.addAll(await DriftGlobalStore(_db).all());
    for (final d in await DriftDeviceStore(_db).all()) {
      _flows.deviceStates[d.id] = d.state;
    }
    await reloadFlows();
  }

  /// What the migration needs from the stored things: the place each zone
  /// became, and the board each node name is. Every board counts, the
  /// firmware's and a v1 board on a UDP or serial driver: by its stable id
  /// (the firmware's node name), or by its own id when it has none.
  Future<FlowMigrationContext> migrationContext() async {
    final devices = await DriftDeviceStore(_db).all();
    return FlowMigrationContext(
      places: {
        for (final d in devices)
          if (d.driverId == placeDriverId) zoneIdOf(d): d.id,
      },
      boards: {
        for (final d in devices)
          if (_isBoard(_registry[d.driverId]))
            (d.stableId ?? d.id).toLowerCase(): d.id,
      },
    );
  }

  /// A board sends its own event lines: the firmware's driver, or a v1
  /// board's `microcontroller` driver over UDP or serial.
  static bool _isBoard(DriverManifest? manifest) =>
      isBoardDriver(manifest) ||
      (manifest != null &&
          manifest.category == 'microcontroller' &&
          _rawLineTransports.contains(manifest.transport.type));

  /// [flow] migrated with [context], refusing a `board_event` whose node is
  /// no board: it would become a trigger on a thing that does not exist,
  /// which loads without an issue and never fires.
  Future<Map<String, Object?>> _migrate(
    Map<String, Object?> flow,
    FlowMigrationContext context,
  ) async {
    final nodes = flow['nodes'];
    if (nodes is List) {
      final ids = {for (final d in await DriftDeviceStore(_db).all()) d.id};
      for (final n in nodes) {
        if (n is! Map || n['type'] != 'board_event') continue;
        final config = n['config'];
        final node = config is Map ? config['node'] : null;
        if (node is String && !ids.contains(context.boardFor(node))) {
          throw FlowMigrationException(
            'node ${n['id']} waits for an event from the board $node, and '
            'no board has that name. Add the board, or set the node to '
            'the id of one',
          );
        }
      }
    }
    return migrateFlow(flow, context);
  }

  /// [json] rewritten from retired node types, for a flow being saved or
  /// validated. The phone is made when the flow names it.
  Future<Map<String, Object?>> migrateInput(Map<String, Object?> json) async {
    final Map<String, Object?> migrated;
    try {
      migrated = await _migrate(json, await migrationContext());
    } on FlowMigrationException catch (e) {
      throw ApiError('invalid', e.message);
    }
    await _ensurePhone(migrated);
    return migrated;
  }

  Future<void> _ensurePhone(Map<String, Object?> json) async {
    if (mentionsThing(json['nodes'], defaultPhoneId) &&
        await DriftDeviceStore(_db).get(defaultPhoneId) == null) {
      await _things.phone();
    }
  }

  /// Rewrites every stored flow still on retired node types, once, keeping
  /// its enabled, approved and trusted marks: the rewrite means the same.
  /// A link stored before specs were kept gets its spec back from its flow.
  Future<void> migrateStored() async {
    final context = await migrationContext();
    for (final r in await DriftFlowStore(_db).all()) {
      final json = flowJsonOf(r);
      final id = '${json['id']}';
      var migrated = json;
      try {
        migrated = await _migrate(json, context);
        _migrationErrors.remove(id);
      } on FlowMigrationException catch (e) {
        _migrationErrors[id] = e.message;
      }
      // A rule saved while a failed step still stopped the rest now carries
      // on, as a rule saved today does unless it sets stopOnError.
      if (r.source == FlowRecord.rule &&
          r.spec?['stopOnError'] != true &&
          migrated['onError'] == null) {
        migrated = {...migrated, 'onError': 'continue'};
      }
      // A link stored before specs were kept is read back from the flow it
      // compiled to, which only the migrated node types describe.
      final spec = r.source == FlowRecord.link && r.spec == null
          ? linkSpecFromFlow(migrated)
          : null;
      if (identical(migrated, json) && spec == null) continue;
      if (!identical(migrated, json)) await _ensurePhone(migrated);
      await put(
        id,
        migrated,
        enabled: r.enabled,
        approved: r.approved,
        trusted: trustedOf(r),
        source: spec == null ? null : FlowRecord.link,
        spec: spec,
      );
    }
  }

  /// Whether a flow's nodes name the thing [id] anywhere: a trigger, an
  /// action, or a `compare` reading its state.
  static bool mentionsThing(Object? value, String id) => switch (value) {
    Map m =>
      m['deviceId'] == id ||
          m['thing'] == id ||
          (m['state'] is String && (m['state'] as String).startsWith('$id.')) ||
          m.values.any((v) => mentionsThing(v, id)),
    List l => l.any((v) => mentionsThing(v, id)),
    _ => false,
  };

  /// The flow JSON of a stored record, as a copy the caller may change.
  static Map<String, Object?> flowJsonOf(FlowRecord r) => {...r.json};

  /// Whether the user saved or approved this version of the flow.
  static bool trustedOf(FlowRecord? r) => r?.trusted ?? false;

  /// What the user reviews before approving: a hash of the flow JSON.
  static String revisionOf(Map<String, Object?> flowJson) =>
      sha256Hex(canonicalJson(flowJson));

  /// Saves a flow. With no [source] the stored source and spec stay, so
  /// enabling, approving or migrating a rule keeps it a rule.
  Future<void> put(
    String id,
    Map<String, Object?> flowJson, {
    required bool enabled,
    required bool approved,
    required bool trusted,
    String? source,
    Map<String, Object?>? spec,
  }) => DriftFlowStore(_db).put(
    id,
    flowJson,
    enabled: enabled,
    approved: approved,
    trusted: trusted,
    at: DateTime.now().toUtc(),
    source: source,
    spec: spec,
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
      final migration = _migrationErrors[e.key];
      issues.add({
        'kind': 'flow',
        'id': e.key,
        'error': migration == null
            ? e.value
            : '${e.value}, and it cannot be migrated: $migration',
      });
    }
    _core.setIssues('flow', issues);
  }

  Future<FlowReferences> references() async {
    final devices = {
      for (final d in await DriftDeviceStore(_db).all())
        d.id: manifestFor(_registry, d),
    };
    final states = {
      for (final d in await DriftDeviceStore(_db).all()) d.id: d.state,
    };
    final (_, specs, _) = await stored();
    return FlowReferences(
      devices: devices.keys.toSet(),
      flows: {
        for (final f in await DriftFlowStore(_db).all()) f.json['id'] as String,
      },
      capabilityOf: (d, c) => devices[d]?.capability(c),
      calls: {for (final f in specs.values) f.id: runFlowTargets(f)},
      stateKeysOf: (t) {
        final manifest = devices[t];
        if (manifest == null) return devices.containsKey(t) ? null : {};
        if (manifest.reportsUndeclaredState) return null;
        return {
          ...?states[t]?.keys,
          for (final c in manifest.capabilities) ?stateKeyOf(c.stateJsonPath),
        };
      },
      eventsOf: (t) {
        final manifest = devices[t];
        if (manifest == null) return devices.containsKey(t) ? null : {};
        if (_rawLineTransports.contains(manifest.transport.type)) return null;
        return {
          for (final c in manifest.capabilities)
            if (c.type == CapabilityType.event) c.id,
        };
      },
    );
  }

  /// Transports whose devices send their own lines (a board's firmware, a
  /// v1 board over UDP), each an event under its own name, so an event a
  /// manifest does not declare is still one the device can raise.
  static const _rawLineTransports = {
    TransportType.omniflow,
    TransportType.udp,
    TransportType.serial,
  };

  /// True when [flow], saved over the stored flows, would be high risk.
  Future<bool> isHighRisk(FlowSpec flow) async {
    final (_, specs, _) = await stored();
    return (await highRiskFlows({...specs, flow.id: flow}.values))
        .contains(flow.id);
  }

  static final _globalRef = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)');

  /// Whether running [capability] needs the user's approval in a flow: a
  /// host command, or on a TV over ADB a raw setting or an app's data,
  /// state or presence.
  bool capabilityIsHighRisk(
    DriverManifest manifest,
    CapabilitySpec capability,
  ) =>
      capability.type.isHighRisk ||
      manifest.transport.type == TransportType.exec ||
      (manifest.transport.type == TransportType.adb &&
          adbCommandIsHighRisk(capability.command));

  /// The ids of the high-risk flows among [all]: a flow that drives a device
  /// whose driver runs host commands, or a TV step [capabilityIsHighRisk]
  /// names, that starts a high-risk flow with
  /// run_flow (it could pass arguments the target renders), or that sets a
  /// global a high-risk flow reads.
  Future<Set<String>> highRiskFlows(Iterable<FlowSpec> all) async {
    final drivers = {
      for (final d in await DriftDeviceStore(_db).all()) d.id: d.driverId,
    };
    bool drivesRisk(NodeSpec n) {
      if (n.type != 'device_capability' && n.type != 'device_toggle') {
        return false;
      }
      final manifest = _registry[drivers[n.config['deviceId']] ?? ''];
      if (manifest == null) return false;
      if (manifest.isHighRisk) return true;
      final capability = manifest.capability('${n.config['capabilityId']}');
      return capability != null && capabilityIsHighRisk(manifest, capability);
    }

    final risky = {
      for (final f in all)
        if (f.nodes.any(drivesRisk)) f.id,
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
