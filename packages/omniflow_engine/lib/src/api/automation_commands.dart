import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'flow_commands.dart';
import 'link_commands.dart';
import 'stored_flows.dart';
import 'things_runtime.dart';
import '../dag/flow.dart';
import '../dag/node_types.dart';
import '../dag/rules.dart';
import '../storage/database.dart';

/// The automation commands. An automation is one stored flow written as a
/// link, a rule or a graph: it keeps that form next to the compiled flow, so
/// each surface reopens it as it was written, and validation, approval, dry
/// runs and the run log are the flow's.
///
/// `flow.*` and `link.*` are the same automations under their old names.
class AutomationCommands {
  AutomationCommands(
    this._core,
    this._stored,
    this._flowCommands,
    this._linkCommands,
  );

  final EngineCore _core;
  final StoredFlows _stored;
  final FlowCommands _flowCommands;
  final LinkCommands _linkCommands;

  /// The command table entries, for the engine's command table.
  Map<String, CommandHandler> get commands => {
    'automation.save': save,
    'automation.list': list,
    'automation.get': get,
    'automation.enable': _flowCommands.enable,
    'automation.approve': _flowCommands.approve,
    'automation.run': run,
    'automation.dry_run': dryRun,
    'automation.log': _flowCommands.log,
    'automation.remove': _flowCommands.remove,
  };

  /// Saves `{form, spec}`: `form` is `rule`, `link` or `graph`, `spec` the
  /// rule, the link (as `link.create` takes it) or the flow. `trusted` comes
  /// only from the user's own tools. `id` names a rule that gives none, and
  /// `replace` saves a rule or a link again: without it an id another rule
  /// or link has is `exists`.
  Future<Map<String, Object?>> save(Map<String, Object?> args) async {
    final form = _form(args);
    final spec = objectArg(args, 'spec');
    final trusted = args['trusted'] == true;
    return switch (form) {
      FlowRecord.rule => _saveRule(
        _withId(spec, args),
        trusted,
        replace: args['replace'] == true,
      ),
      FlowRecord.link => _saveLink(spec, args, trusted),
      _ => _flowCommands.saveAs(
        spec,
        trusted: trusted,
        source: FlowRecord.graph,
      ),
    };
  }

  static String _form(Map<String, Object?> args) {
    final form = args['form'];
    if (form is String && FlowRecord.sources.contains(form)) return form;
    throw ApiError(
      'invalid',
      'form must be one of ${FlowRecord.sources.join(', ')}',
    );
  }

  static Map<String, Object?> _withId(
    Map<String, Object?> rule,
    Map<String, Object?> args,
  ) {
    final id = optStringArg(args, 'id');
    return id == null ? rule : {...rule, 'id': id};
  }

  /// [json] checked and compiled, with where its flow issues sit in it.
  Future<(Map<String, Object?>, FlowSpec)> _compileRule(
    Map<String, Object?> json,
  ) async {
    final rule = normalizeRule(json, context: await ruleContext());
    final compiled = compileRule(
      rule,
      enabled: json['enabled'] != false,
      refs: await _stored.references(),
    );
    final flow = await _flowCommands.checked(
      compiled.flow,
      subject: 'rule ${rule['id']}',
      toSpecPaths: compiled.toRulePaths,
    );
    return (rule, flow);
  }

  Future<Map<String, Object?>> _saveRule(
    Map<String, Object?> json,
    bool trusted, {
    required bool replace,
  }) async {
    final (rule, flow) = await _compileRule(json);
    final id = flow.id;
    final existing = await DriftFlowStore(_core.db).get(id);
    if (existing != null && existing.source != FlowRecord.rule) {
      throw ApiError(
        'exists',
        '$id is a ${existing.source}, and only a rule can be saved over a rule. '
            'Give the rule another id, or remove $id first',
      );
    }
    if (existing != null && !replace) {
      throw ApiError(
        'exists',
        'the rule $id exists. Give this rule another name or id, or save '
            'with replace: true to replace it',
      );
    }
    // The stored spec leaves enabled to the record, so saving a reopened
    // rule keeps a disabled one off.
    final enabled = json['enabled'] is bool
        ? json['enabled'] as bool
        : existing?.enabled ?? true;
    final saved = await _flowCommands.saveAs(
      flow.copyWith(enabled: enabled).toJson(),
      trusted: trusted,
      source: FlowRecord.rule,
      spec: rule,
    );
    return {...saved, 'name': rule['name']};
  }

  /// A dry run of the stored automation `id`, or of a rule or graph given
  /// as `{form, spec}` before it is saved. `trigger`, `at` and `msg` as for
  /// `flow.dryRun`.
  Future<Map<String, Object?>> dryRun(Map<String, Object?> args) async {
    if (args['id'] != null && args['spec'] == null) {
      return _flowCommands.dryRun(args);
    }
    final spec = objectArg(args, 'spec');
    final flow = switch (_form(args)) {
      FlowRecord.rule => (await _compileRule(_withId(spec, args))).$2,
      FlowRecord.graph => await _flowCommands.checked(spec),
      _ => throw ApiError(
        'invalid',
        'a link dry-runs once it is saved: pass its id',
      ),
    };
    return _flowCommands.dryRunFlow(flow, args);
  }

  Future<Map<String, Object?>> _saveLink(
    Map<String, Object?> link,
    Map<String, Object?> args,
    bool trusted,
  ) => _linkCommands.create({
    ...link,
    'trusted': trusted,
    if (args['replace'] == true) 'replace': true,
  });

  /// What rule shorthand resolves against: the places, and the household
  /// person with the place that counts as their home.
  Future<RuleContext> ruleContext() async {
    final devices = await DriftDeviceStore(_core.db).all();
    final places = <String, String>{
      for (final d in devices)
        if (d.driverId == placeDriverId) ...{zoneIdOf(d): d.id, d.id: d.id},
    };
    final person = await _stored.things.householdPerson();
    final home = devices
        .where((d) => d.id == person)
        .firstOrNull
        ?.settings['homePlace'];
    return RuleContext(
      places: places,
      person: person,
      personHome:
          places[home is String && home.isNotEmpty ? home : defaultHomePlace],
    );
  }

  /// Every automation, optionally only those written as `source`.
  Future<Map<String, Object?>> list(Map<String, Object?> args) async {
    final source = optStringArg(args, 'source');
    if (source != null && !FlowRecord.sources.contains(source)) {
      throw ApiError(
        'invalid',
        'source must be one of ${FlowRecord.sources.join(', ')}',
      );
    }
    final listed = await _flowCommands.list(const {});
    return {
      'automations': [
        for (final a in (listed['flows'] as List).cast<Map<String, Object?>>())
          if (source == null || a['source'] == source) a,
      ],
      'loadIssues': listed['loadIssues'],
    };
  }

  /// One automation in the form it was written in (`spec`: the rule, the
  /// link, or the graph itself) and the flow that runs it.
  Future<Map<String, Object?>> get(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final record = await DriftFlowStore(_core.db).get(id);
    if (record == null) throw ApiError('not_found', 'no automation $id');
    final flow = StoredFlows.flowJsonOf(record);
    final (_, specs, _) = await _stored.stored();
    return {
      'id': id,
      'name': flow['name'],
      'source': record.source,
      'spec': record.source == FlowRecord.graph ? flow : record.spec,
      'flow': flow,
      'enabled': record.enabled,
      'approved': record.approved,
      'highRisk': (await _stored.highRiskFlows(specs.values)).contains(id),
      'revision': StoredFlows.revisionOf(flow),
    };
  }

  /// Runs an automation now: its manual triggers, the trigger given, or
  /// when it has no manual trigger its first trigger, as if that fired.
  Future<Map<String, Object?>> run(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    var trigger = optStringArg(args, 'trigger');
    if (trigger == null) {
      final record = await DriftFlowStore(_core.db).get(id);
      final nodes = record == null
          ? const <NodeSpec>[]
          : FlowSpec.parse(StoredFlows.flowJsonOf(record)).nodes;
      if (!nodes.any((n) => n.type == 'manual')) {
        trigger = nodes
            .where(
              (n) => builtInNodeTypes[n.type]?.category == NodeCategory.trigger,
            )
            .firstOrNull
            ?.id;
      }
    }
    return _flowCommands.run({...args, 'trigger': ?trigger});
  }
}
