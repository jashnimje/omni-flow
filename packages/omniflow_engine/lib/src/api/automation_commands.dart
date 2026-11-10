import 'api_error.dart';
import 'automation_view.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'flow_commands.dart';
import 'link_commands.dart';
import 'stored_flows.dart';
import 'things_runtime.dart';
import '../dag/flow.dart';
import '../dag/node_types.dart';
import '../dag/rule_shorthand.dart';
import '../dag/rules.dart';
import '../dag/templates.dart';
import '../devices/board.dart' show manifestFor;
import '../manifest/validation.dart';
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
    'automation.templates': templates,
    'scene.save': saveSceneCommand,
    'scene.list': listScenes,
    'scene.run': runScene,
    'scene.remove': removeScene,
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
      FlowRecord.scene => saveScene(_withId(spec, args), trusted),
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
      FlowRecord.scene => (await _compileScene(_withId(spec, args))).$2,
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

  /// Every automation, with its sentence, the things it uses and its last
  /// run. `source` keeps one form, `device` and `tag` those that use that
  /// thing, and `needsYou` those waiting for approval or whose last run
  /// failed while they are on.
  Future<Map<String, Object?>> list(Map<String, Object?> args) async {
    final source = optStringArg(args, 'source');
    if (source != null && !FlowRecord.sources.contains(source)) {
      throw ApiError(
        'invalid',
        'source must be one of ${FlowRecord.sources.join(', ')}',
      );
    }
    final device = optStringArg(args, 'device');
    final tag = optStringArg(args, 'tag');
    final needsYou = args['needsYou'];
    if (needsYou != null && needsYou is! bool) {
      throw ApiError('invalid', 'needsYou must be true or false');
    }
    final listed = await _flowCommands.list(const {});
    final records = {
      for (final r in await DriftFlowStore(_core.db).all()) r.json['id']: r,
    };
    final lastRuns = await ExecutionLogStore(_core.db).lastByFlow();
    final sentences = await sentenceContext();
    final out = <Map<String, Object?>>[];
    for (final a in (listed['flows'] as List).cast<Map<String, Object?>>()) {
      final record = records[a['id']];
      if (record == null || (source != null && a['source'] != source)) continue;
      final things = thingsIn(record.json['nodes']);
      if (device != null && !things.contains(device)) continue;
      if (tag != null && !things.contains(tag)) continue;
      final trace = lastRuns[a['id']];
      final lastRun = trace == null ? null : lastRunOf(trace);
      final waiting = a['approved'] != true;
      final failing = a['enabled'] == true && lastRun?['ok'] == false;
      if (needsYou == true && !waiting && !failing) continue;
      out.add({
        ...a,
        'needsApproval': waiting,
        'needsYou': waiting || failing,
        'sentence': sentences.sentence(record),
        'lastRun': ?lastRun,
        'devices': things.toList()..sort(),
        'controls': thingsDriven(record.json).toList()..sort(),
        if (record.source == FlowRecord.scene) 'icon': ?record.spec?['icon'],
      });
    }
    return {'automations': out, 'loadIssues': listed['loadIssues']};
  }

  /// What the automation sentences read: thing names and drivers, the
  /// household person, and the automation names.
  Future<SentenceContext> sentenceContext() async {
    final devices = await DriftDeviceStore(_core.db).all();
    return SentenceContext(
      names: {for (final d in devices) d.id: d.name},
      drivers: {for (final d in devices) d.id: ?manifestFor(_core.registry, d)},
      person: await _stored.things.householdPerson(),
      automations: {
        for (final f in await DriftFlowStore(_core.db).all())
          '${f.json['id']}': '${f.json['name']}',
      },
    );
  }

  /// `{id?, values?}`: the rule templates. With `id` and `values`, that
  /// template with its placeholders filled, ready for `automation.save`.
  Future<Map<String, Object?>> templates(Map<String, Object?> args) async {
    final id = optStringArg(args, 'id');
    final chosen = id == null
        ? ruleTemplates
        : ruleTemplates.where((t) => t.id == id).toList();
    if (chosen.isEmpty) throw ApiError('not_found', 'no template $id');
    if (args['values'] == null) {
      return {
        'templates': [for (final t in chosen) t.toJson()],
      };
    }
    if (id == null) throw ApiError('invalid', 'values needs a template id');
    try {
      return {
        'templates': [
          {
            ...chosen.single.toJson(),
            'spec': fillTemplate(chosen.single, objectArg(args, 'values')),
            'filled': true,
          },
        ],
      };
    } on TemplateFillException catch (e) {
      throw ApiError('invalid', e.message);
    }
  }

  static final _scenePath = RegExp(r'^then\[0\](?:\.together\[(\d+)\]\[0\])?');

  /// [scene] checked as a scene, and compiled through the rule compiler: a
  /// manual trigger and its actions side by side.
  Future<(Map<String, Object?>, FlowSpec)> _compileScene(
    Map<String, Object?> scene,
  ) async {
    final issues = IssueCollector();
    for (final key in scene.keys) {
      if (!const {'id', 'name', 'icon', 'actions'}.contains(key)) {
        issues.add(key, 'is not a scene key (id, name, icon, actions)');
      }
    }
    final name = scene['name'];
    if (name is! String || name.trim().isEmpty) {
      issues.add('name', 'is required');
    }
    final icon = scene['icon'];
    if (icon != null && (icon is! String || icon.isEmpty)) {
      issues.add('icon', 'must be an icon name');
    }
    final actions = scene['actions'];
    final steps = <Map<String, Object?>>[];
    if (actions is! List || actions.isEmpty) {
      issues.add('actions', 'needs at least one action');
    } else {
      for (var i = 0; i < actions.length; i++) {
        var a = actions[i];
        if (a is String) {
          try {
            a = expandStep(a);
          } on ShorthandException catch (e) {
            issues.add('actions[$i]', '"${actions[i]}" ${e.message}');
            continue;
          }
        }
        if (a is! Map || a['do'] is! String) {
          issues.add('actions[$i]', 'must be {do: "thing.action", params?}');
        } else if (a.keys.any((k) => k != 'do' && k != 'params')) {
          issues.add('actions[$i]', 'takes only do and params');
        } else {
          steps.add(Map<String, Object?>.from(a));
        }
      }
    }
    final id = scene['id'];
    if (issues.hasIssues) {
      throw ValidationException('scene ${id ?? ''}'.trim(), [
        for (final i in issues.issues)
          ValidationIssue(
            i.path.startsWith(r'$.') ? i.path.substring(2) : i.path,
            i.message,
          ),
      ]);
    }
    final rule = {
      'id': id,
      'name': name,
      'when': [
        {'manual': true},
      ],
      'then': steps.length == 1
          ? steps
          : [
              {
                'together': [
                  for (final s in steps) [s],
                ],
              },
            ],
      'mode': RunMode.queued.name,
    };
    try {
      final (normalized, flow) = await _compileRule(rule);
      return (
        {'id': normalized['id'], 'name': name, 'icon': ?icon, 'actions': steps},
        flow,
      );
    } on ValidationException catch (e) {
      throw ValidationException('scene ${id ?? ''}'.trim(), [
        for (final i in e.issues)
          ValidationIssue(
            i.path.replaceFirstMapped(
              _scenePath,
              (m) => 'actions[${m.group(1) ?? 0}]',
            ),
            i.message,
          ),
      ]);
    }
  }

  /// Saves a scene as an automation. With no id it gets one from its name
  /// that no automation has. An id another kind of automation has is
  /// `exists`, and an id a scene has saves over it.
  Future<Map<String, Object?>> saveScene(
    Map<String, Object?> scene,
    bool trusted,
  ) async {
    final store = DriftFlowStore(_core.db);
    var id = scene['id'];
    if (id == null && scene['name'] is String) {
      final base = ruleIdFor(scene['name'] as String);
      id = base;
      for (var n = 2; await store.get(id as String) != null; n++) {
        id = '${base}_$n';
      }
    }
    final (spec, flow) = await _compileScene({...scene, 'id': id});
    final existing = await store.get(flow.id);
    if (existing != null && existing.source != FlowRecord.scene) {
      throw ApiError(
        'exists',
        '${flow.id} is a ${existing.source}. Give the scene another id',
      );
    }
    final saved = await _flowCommands.saveAs(
      flow.copyWith(enabled: existing?.enabled ?? true).toJson(),
      trusted: trusted,
      source: FlowRecord.scene,
      spec: spec,
    );
    return {...saved, 'name': spec['name']};
  }

  /// `scene.save {id?, name, icon?, actions, trusted?}`.
  Future<Map<String, Object?>> saveSceneCommand(Map<String, Object?> args) =>
      saveScene({
        for (final key in const ['id', 'name', 'icon', 'actions'])
          if (args.containsKey(key)) key: args[key],
      }, args['trusted'] == true);

  Future<Map<String, Object?>> listScenes(Map<String, Object?> _) async {
    final listed = await list({'source': FlowRecord.scene});
    final specs = {
      for (final r in await DriftFlowStore(_core.db).all())
        if (r.source == FlowRecord.scene) r.json['id']: r.spec,
    };
    return {
      'scenes': [
        for (final a
            in (listed['automations'] as List).cast<Map<String, Object?>>())
          {
            'id': a['id'],
            'name': a['name'],
            'icon': ?specs[a['id']]?['icon'],
            'actions': specs[a['id']]?['actions'] ?? const [],
            'enabled': a['enabled'],
            'approved': a['approved'],
            'needsApproval': a['needsApproval'],
            'highRisk': a['highRisk'],
            'revision': a['revision'],
            'sentence': a['sentence'],
            'devices': a['devices'],
            'lastRun': ?a['lastRun'],
          },
      ],
    };
  }

  Future<FlowRecord> _scene(String id) async {
    final record = await DriftFlowStore(_core.db).get(id);
    if (record == null) throw ApiError('not_found', 'no scene $id');
    if (record.source != FlowRecord.scene) {
      throw ApiError('invalid', '$id is a ${record.source}, not a scene');
    }
    return record;
  }

  Future<Map<String, Object?>> runScene(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    await _scene(id);
    return _flowCommands.run({'id': id});
  }

  Future<Map<String, Object?>> removeScene(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    await _scene(id);
    return _flowCommands.remove({'id': id});
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
