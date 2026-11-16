import 'api_error.dart';
import 'command_args.dart';
import 'command_bar.dart';
import 'engine_core.dart';
import 'stored_flows.dart';
import '../dag/flow.dart';
import '../dag/flow_engine.dart';
import '../dag/node_types.dart';
import '../dag/untrusted_templates.dart';
import '../dag/validator.dart';
import '../devices/board.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';

/// The flow commands: validate, save and approve a flow with its trust and
/// revision, enable, run, dry-run, its log, and the command bar.
class FlowCommands {
  FlowCommands(this._core, this._stored);

  final EngineCore _core;
  final StoredFlows _stored;

  OmniDatabase get _db => _core.db;
  FlowEngine get _flows => _core.flows;

  Future<Map<String, Object?>> validate(Map<String, Object?> args) async {
    final flow = FlowSpec.parse(
      await _stored.migrateInput(objectArg(args, 'flow')),
    );
    final issues = validateFlow(flow, refs: await _stored.references());
    if (issues.isNotEmpty) {
      throw ValidationException('flow ${flow.id}', issues);
    }
    return {'id': flow.id, 'highRisk': await _stored.isHighRisk(flow)};
  }

  /// A flow written with retired node types is saved migrated, so old
  /// files keep loading. A flow saved over a link or rule promotes it to a
  /// graph.
  Future<Map<String, Object?>> save(Map<String, Object?> args) => saveAs(
    objectArg(args, 'flow'),
    trusted: args['trusted'] == true,
    source: FlowRecord.graph,
  );

  /// [flowJson] migrated, parsed and validated against the stored things
  /// and flows. Throws a [ValidationException] with every issue.
  Future<FlowSpec> checked(
    Map<String, Object?> flowJson, {
    String? subject,
    List<ValidationIssue> Function(List<ValidationIssue>)? toSpecPaths,
  }) async {
    final flow = FlowSpec.parse(await _stored.migrateInput(flowJson));
    final issues = validateFlow(flow, refs: await _stored.references());
    if (issues.isNotEmpty) {
      throw ValidationException(
        subject ?? 'flow ${flow.id}',
        toSpecPaths == null ? issues : toSpecPaths(issues),
      );
    }
    return flow;
  }

  /// Validates and stores the flow [flowJson], written as [source] from [spec].
  /// [subject] and [toSpecPaths] tell validation issues in the terms of
  /// the form it was written in.
  Future<Map<String, Object?>> saveAs(
    Map<String, Object?> flowJson, {
    required bool trusted,
    required String source,
    Map<String, Object?>? spec,
    String? subject,
    List<ValidationIssue> Function(List<ValidationIssue>)? toSpecPaths,
  }) async {
    final flow = await checked(
      flowJson,
      subject: subject,
      toSpecPaths: toSpecPaths,
    );
    if (!trusted) {
      if (untrustedTriggerTextProblem(flow) case final why?) {
        throw ApiError('invalid', why);
      }
    }
    final highRisk = await _stored.isHighRisk(flow);
    // Only the user's own tools (the CLI, the app) pass trusted: true.
    // Anything else (MCP, the architect, an import) is untrusted: its
    // high-risk flows wait for approval, and it cannot quietly replace a
    // flow the user saved or approved.
    final existing = await DriftFlowStore(_db).get(flow.id);
    final approved = trusted || (!highRisk && !StoredFlows.trustedOf(existing));
    final json = flow.toJson();
    await _stored.put(
      flow.id,
      json,
      enabled: flow.enabled,
      approved: approved,
      trusted: trusted,
      source: source,
      spec: spec,
    );
    await _stored.reloadFlows();
    return {
      'id': flow.id,
      'source': source,
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
            'source': r.source,
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
      'source': record.source,
      'spec': ?record.spec,
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
    // A thing it uses may have been removed since it was saved (which
    // turned it off), so turning it back on checks it again.
    if (enabled) {
      await checked(StoredFlows.flowJsonOf(record), subject: 'automation $id');
    }
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
    return dryRunFlow(FlowSpec.parse(StoredFlows.flowJsonOf(record)), args);
  }

  /// A dry run of [flow], stored or not, with the `trigger`, `at` and `msg`
  /// in [args].
  Future<Map<String, Object?>> dryRunFlow(
    FlowSpec flow,
    Map<String, Object?> args,
  ) async {
    final id = flow.id;
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
    // A compiled rule's node labels are its steps as written, which reads
    // better in a trace than the node ids the compiler made up.
    final labels = {for (final n in flow.nodes) n.id: n.label};
    final run = trace.toJson();
    return {
      'run': {
        ...run,
        'nodes': [
          for (final n in (run['nodes'] as List).cast<Map<String, Object?>>())
            {...n, 'label': ?labels[n['node']]},
        ],
      },
    };
  }

  Future<Map<String, Object?>> log(Map<String, Object?> args) async => {
    'runs': await ExecutionLogStore(_db).recent(
      flowId: optStringArg(args, 'id'),
      limit: optIntArg(args, 'limit') ?? 20,
    ),
  };

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
