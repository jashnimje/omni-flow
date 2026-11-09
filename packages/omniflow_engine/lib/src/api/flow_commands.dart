import 'api_error.dart';
import 'command_args.dart';
import 'command_bar.dart';
import 'engine_core.dart';
import 'stored_flows.dart';
import '../dag/cards.dart';
import '../dag/flow.dart';
import '../dag/flow_engine.dart';
import '../dag/node_types.dart';
import '../dag/validator.dart';
import '../devices/board.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';

/// The flow commands: validate, save and approve a flow with its trust and
/// revision, enable, run, dry-run, its log and cards, and the command bar.
class FlowCommands {
  FlowCommands(this._core, this._stored);

  final EngineCore _core;
  final StoredFlows _stored;

  OmniDatabase get _db => _core.db;
  FlowEngine get _flows => _core.flows;

  Future<Map<String, Object?>> validate(Map<String, Object?> args) async {
    final flow = FlowSpec.parse(objectArg(args, 'flow'));
    final issues = validateFlow(flow, refs: await _stored.references());
    if (issues.isNotEmpty) {
      throw ValidationException('flow ${flow.id}', issues);
    }
    return {'id': flow.id, 'highRisk': await _stored.isHighRisk(flow)};
  }

  Future<Map<String, Object?>> save(Map<String, Object?> args) async {
    final flow = FlowSpec.parse(objectArg(args, 'flow'));
    final issues = validateFlow(flow, refs: await _stored.references());
    if (issues.isNotEmpty) {
      throw ValidationException('flow ${flow.id}', issues);
    }
    final highRisk = await _stored.isHighRisk(flow);
    // Only the user's own tools (the CLI, the app) pass trusted: true.
    // Anything else (MCP, the architect, an import) is untrusted: its
    // high-risk flows wait for approval, and it cannot quietly replace a
    // flow the user saved or approved.
    final trusted = args['trusted'] == true;
    final existing = await DriftFlowStore(_db).get(flow.id);
    final approved = trusted || (!highRisk && !StoredFlows.trustedOf(existing));
    final json = flow.toJson();
    await _stored.put(
      flow.id,
      json,
      enabled: flow.enabled,
      approved: approved,
      trusted: trusted,
    );
    await _stored.reloadFlows();
    return {
      'id': flow.id,
      'highRisk': highRisk,
      'approved': approved,
      'revision': StoredFlows.revisionOf(json),
    };
  }

  Future<Map<String, Object?>> approve(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final revision = stringArg(args, 'revision');
    final record = await DriftFlowStore(_db).get(id);
    if (record == null) throw ApiError('not_found', 'no flow $id');
    final json = StoredFlows.flowJsonOf(record);
    if (StoredFlows.revisionOf(json) != revision) {
      throw ApiError(
        'conflict',
        'flow $id changed since revision $revision. Review it again',
      );
    }
    await _stored.put(
      id,
      json,
      enabled: record.enabled,
      approved: true,
      trusted: true,
    );
    await _stored.reloadFlows();
    return {'id': id, 'approved': true};
  }

  Future<Map<String, Object?>> list(Map<String, Object?> _) async {
    final (records, specs, _) = await _stored.stored();
    final risky = await _stored.highRiskFlows(specs.values);
    final dropped = _flows.droppedRuns;
    return {
      'flows': [
        for (final r in records)
          {
            'id': r.json['id'],
            'name': r.json['name'],
            'enabled': r.enabled,
            'approved': r.approved,
            'highRisk': risky.contains(r.json['id']),
            'loaded': _flows.loadedFlows.contains(r.json['id']),
            'revision': StoredFlows.revisionOf(StoredFlows.flowJsonOf(r)),
            'dropped': dropped[r.json['id']] ?? 0,
          },
      ],
      'loadIssues': _core.loadIssues,
    };
  }

  Future<Map<String, Object?>> get(Map<String, Object?> args) async {
    final record = await DriftFlowStore(_db).get(stringArg(args, 'id'));
    if (record == null) throw ApiError('not_found', 'no flow ${args['id']}');
    final json = StoredFlows.flowJsonOf(record);
    return {
      'flow': json,
      'enabled': record.enabled,
      'approved': record.approved,
      'revision': StoredFlows.revisionOf(json),
    };
  }

  Future<Map<String, Object?>> remove(Map<String, Object?> args) async {
    final removed = await DriftFlowStore(_db).remove(stringArg(args, 'id'));
    await _stored.reloadFlows();
    return {'removed': removed};
  }

  Future<Map<String, Object?>> enable(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final record = await DriftFlowStore(_db).get(id);
    if (record == null) throw ApiError('not_found', 'no flow $id');
    final enabled = args['enabled'] != false;
    await _stored.put(
      id,
      {...StoredFlows.flowJsonOf(record), 'enabled': enabled},
      enabled: enabled,
      approved: record.approved,
      trusted: StoredFlows.trustedOf(record),
    );
    await _stored.reloadFlows();
    return {'id': id, 'enabled': enabled};
  }

  Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    final traces = await _flows.run(
      stringArg(args, 'id'),
      triggerId: optStringArg(args, 'trigger'),
      msg: args['msg'] == null ? const {} : objectArg(args, 'msg'),
    );
    return {'runs': traces.map((t) => t.toJson()).toList()};
  }

  Future<Map<String, Object?>> dryRun(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final record = await DriftFlowStore(_db).get(id);
    if (record == null) throw ApiError('not_found', 'no flow $id');
    final flow = FlowSpec.parse(StoredFlows.flowJsonOf(record));
    final trigger =
        optStringArg(args, 'trigger') ??
        flow.nodes
            .where(
              (n) => builtInNodeTypes[n.type]?.category == NodeCategory.trigger,
            )
            .firstOrNull
            ?.id;
    if (trigger == null) throw ApiError('invalid', 'flow $id has no trigger');
    final at = optDateArg(args, 'at') ?? DateTime.now();
    final msg = args['msg'] == null
        ? <String, Object?>{}
        : objectArg(args, 'msg');
    final trace = await _flows.dryRun(flow, trigger, {
      'trigger': 'dry_run',
      ...msg,
    }, at);
    return {'run': trace.toJson()};
  }

  Future<Map<String, Object?>> log(Map<String, Object?> args) async => {
    'runs': await ExecutionLogStore(_db).recent(
      flowId: optStringArg(args, 'id'),
      limit: optIntArg(args, 'limit') ?? 20,
    ),
  };

  Future<Map<String, Object?>> cards(Map<String, Object?> args) async {
    final record = await DriftFlowStore(_db).get(stringArg(args, 'id'));
    if (record == null) throw ApiError('not_found', 'no flow ${args['id']}');
    final cards = projectCards(FlowSpec.parse(StoredFlows.flowJsonOf(record)));
    return cards == null ? {'tree': false} : {'tree': true, ...cards.toJson()};
  }

  /// Reads a typed command against the stored devices and flows.
  Future<Map<String, Object?>> interpret(Map<String, Object?> args) async {
    final devices = [
      for (final d in await DriftDeviceStore(_db).all())
        if (manifestFor(_core.registry, d) case final manifest?)
          CommandDevice(d.id, d.name, manifest),
    ];
    final flowList = [
      for (final f in await DriftFlowStore(_db).all())
        CommandFlow(f.json['id'] as String, f.json['name'] as String),
    ];
    return interpretCommand(
      stringArg(args, 'text'),
      devices,
      flowList,
    ).toJson();
  }
}
