import '../dag/canonical.dart';
import '../dag/links.dart' show linkSpecFromFlow;
import '../dag/node_types.dart';
import '../dag/rules.dart' show compiledNodeId, normalizeRule;
import '../dag/skips.dart';
import '../manifest/validation.dart';
import '../storage/database.dart';
import 'api_error.dart';
import 'automation_commands.dart';
import 'automation_view.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'rules_core_commands.dart' show RulesCoreCommands;
import 'stored_flows.dart';

/// `automation.diagram`: an automation as a decision graph the app lays out
/// top to bottom, with each node's place in the rule and the words the
/// sentence uses for it. The design is `docs/flow-diagram-design.md`.
///
/// - `{id}` or `{spec, form?}` (an unsaved rule, scene, link or graph):
///   `{nodes, edges, source}`.
/// - `run` (a run id from the log) or `last: true`: the run's path lit, each
///   node's `status` and each decision's `seen`, and `taken` on edges.
/// - `dryRun` (what `automation.dry_run` or `flow.dryRun` returned): the
///   same for a test run or Try as if.
/// - `skipsToo: true`: the newest skip, when it is newer than the run, marks
///   the check that said no.
class AutomationDiagramCommands {
  AutomationDiagramCommands(this._core, this._automations) {
    _core.flows.nodePath ??= pathOf;
  }

  final EngineCore _core;
  final AutomationCommands _automations;

  /// Per automation, the rule path of each compiled node, from the last
  /// diagram of it, so a live `run.node` can say where in the rule it is.
  final _paths = <String, Map<String, String>>{};

  Map<String, CommandHandler> get commands => {'automation.diagram': diagram};

  /// The rule path of the compiled node [node] of [flow], when a diagram of
  /// it has been drawn.
  String? pathOf(String flow, String node) => _paths[flow]?[node];

  Future<Map<String, Object?>> diagram(Map<String, Object?> args) async {
    final words = await _automations.sentenceContext();
    final id = optStringArg(args, 'id');
    final Diagram d;
    FlowRecord? record;
    var continueOnError = true;
    final issues = <ValidationIssue>[];
    if (args['spec'] != null) {
      final spec = objectArg(args, 'spec');
      final form = optStringArg(args, 'form') ?? FlowRecord.rule;
      if (!FlowRecord.sources.contains(form)) {
        throw ApiError(
          'invalid',
          'form must be one of ${FlowRecord.sources.join(', ')}',
        );
      }
      var rule = spec;
      if (form == FlowRecord.rule) {
        try {
          rule = normalizeRule(spec, context: await _automations.ruleContext());
        } on ValidationException catch (e) {
          // A rule being edited may be unfinished: it still shows.
          issues.addAll(e.issues);
        }
        continueOnError = rule['stopOnError'] != true;
      }
      d = Diagram.of(form, rule, words);
    } else {
      if (id == null) throw ApiError('invalid', 'id or spec is required');
      record = await DriftFlowStore(_core.db).get(id);
      if (record == null) throw ApiError('not_found', 'no automation $id');
      final flow = StoredFlows.flowJsonOf(record);
      continueOnError = flow['onError'] == 'continue';
      final spec = record.source == FlowRecord.link
          ? record.spec ?? linkSpecFromFlow(flow)
          : record.spec;
      d = Diagram.of(record.source, spec, words, flow: flow);
      if (d.readOnly) {
        _paths.remove(id);
      } else {
        _paths[id] = d.compiledPaths;
      }
    }

    Map<String, Object?>? trace;
    if (args['dryRun'] != null) {
      final dry = objectArg(args, 'dryRun');
      final run = dry['run'];
      trace = run is Map ? Map<String, Object?>.from(run) : dry;
    } else if (args['run'] != null || args['last'] == true) {
      if (id == null) throw ApiError('invalid', 'a run needs the id');
      trace = await _logged(id, optStringArg(args, 'run'));
    }
    Map<String, Object?>? skip;
    if (args['skipsToo'] == true && id != null) {
      final latest = _core.flows.skips.of(id).firstOrNull;
      final started = DateTime.tryParse('${trace?['startedAt']}');
      if (latest != null && (started == null || latest.at.isAfter(started))) {
        skip = {
          ...latest.toJson(),
          'reason': RulesCoreCommands.skipReason(latest, words, record),
        };
        trace = d.skipTrace(latest, record?.json);
      }
    }
    if (trace != null) d.mark(trace, continueOnError: continueOnError);
    return {
      ...d.toJson(),
      if (trace != null && skip == null)
        'run': {
          'run': trace['run'],
          'outcome': trace['outcome'],
          'startedAt': trace['startedAt'],
          'dryRun': trace['dryRun'] == true,
        },
      'skip': ?skip,
      if (issues.isNotEmpty)
        'issues': [
          for (final i in issues) {'path': i.path, 'message': i.message},
        ],
    };
  }

  Future<Map<String, Object?>> _logged(String id, String? run) async {
    final log = ExecutionLogStore(_core.db);
    final runs = await log.recent(flowId: id, limit: run == null ? 1 : 1000);
    final found = run == null
        ? runs.firstOrNull
        : runs.where((r) => r['run'] == run).firstOrNull;
    if (found == null) {
      throw ApiError(
        'not_found',
        run == null ? '$id has not run yet' : 'no run $run of $id in the log',
      );
    }
    return found;
  }
}

/// A pending way out of a node, waiting for the node it leads to: from
/// where, its label, and where a "+" on it adds.
class _Open {
  const _Open(this.from, {this.label, this.insert, this.alsoInsert});

  final String from;
  final String? label;
  final Map<String, Object?>? insert;
  final Map<String, Object?>? alsoInsert;

  _Open at(Map<String, Object?> where) => insert != null
      ? this
      : _Open(from, label: label, insert: where, alsoInsert: alsoInsert);
}

Map<String, Object?> _insert(String path, String as) => {
  'path': path,
  'as': as,
};

List<Map<String, Object?>> _maps(Object? v) => [
  for (final e in v is List ? v : const []) Map<String, Object?>.from(e as Map),
];

/// An automation as diagram nodes and edges.
class Diagram {
  Diagram._(this.source);

  /// The diagram of [spec] written as [source] (`rule`, `scene`, `link`), or
  /// of the graph [flow]. A spec of an older shape falls back to its graph.
  factory Diagram.of(
    String source,
    Map<String, Object?>? spec,
    SentenceContext words, {
    Map<String, Object?>? flow,
  }) {
    if (spec != null && source != FlowRecord.graph) {
      try {
        final d = Diagram._(source);
        switch (source) {
          case FlowRecord.rule:
            _RuleProjector(d, words).rule(spec);
          case FlowRecord.scene:
            d._scene(spec, words);
          case FlowRecord.link:
            d._link(spec, words);
        }
        return d;
      } catch (_) {
        if (flow == null) rethrow;
      }
    }
    return Diagram._(source).._graph(flow ?? spec ?? const {});
  }

  final String source;
  final nodes = <Map<String, Object?>>[];
  final edges = <Map<String, Object?>>[];

  /// A raw graph or a link: no paths and no insert points.
  bool readOnly = false;

  final _byId = <String, Map<String, Object?>>{};

  /// For a try group: the compiled ids of its own steps.
  final _failing = <String, Set<String>>{};

  /// For an ask that branches: each answer's if step, by compiled id.
  final _answers = <String, Map<String, String?>>{};

  /// For an onlyIf check: its place among the onlyIf conditions.
  final _parts = <String, int>{};
  var _onlyIfCount = 0;

  /// For a raw graph edge: the port it leaves by.
  final _ports = <int, String>{};

  Map<String, Object?> toJson() => {
    'nodes': nodes,
    'edges': edges,
    'source': source,
    if (readOnly) 'readOnly': true,
  };

  /// The rule path of each compiled node.
  Map<String, String> get compiledPaths {
    final out = <String, String>{};
    for (final n in nodes) {
      final path = n['path'];
      if (path is! String) continue;
      for (final id in (n['compiled'] as List? ?? const []).cast<String>()) {
        out.putIfAbsent(id, () => id == 'only_if' ? '/onlyIf' : path);
      }
    }
    return out;
  }

  String _node(
    String id,
    String kind,
    String? path,
    String words, {
    List<String> compiled = const [],
    Map<String, Object?> extra = const {},
  }) {
    final n = <String, Object?>{
      'id': id,
      'kind': kind,
      'path': ?path,
      'words': words,
      ...extra,
      if (compiled.isNotEmpty) 'compiled': compiled,
    };
    nodes.add(n);
    _byId[id] = n;
    return id;
  }

  void _edge(
    String from,
    String to, {
    String? label,
    Map<String, Object?>? insert,
    Map<String, Object?>? alsoInsert,
  }) => edges.add({
    'from': from,
    'to': to,
    'label': ?label,
    'insert': ?insert,
    'alsoInsert': ?alsoInsert,
  });

  void _connect(List<_Open> open, String to) {
    for (final o in open) {
      _edge(
        o.from,
        to,
        label: o.label,
        insert: o.insert,
        alsoInsert: o.alsoInsert,
      );
    }
  }

  /// A scene: its actions, all at once, in one group.
  void _scene(Map<String, Object?> spec, SentenceContext w) {
    final actions = _maps(spec['actions']);
    final many = actions.length > 1;
    final group = _node(
      '/actions',
      'group',
      '/actions',
      '${spec['name']}',
      compiled: ['when_0', if (many) 'then_0'],
      extra: {'group': 'scene'},
    );
    final start = nodes.length;
    final merge = '/actions#merge';
    final ends = <_Open>[];
    for (var i = 0; i < actions.length; i++) {
      final a = actions[i];
      final id = _node(
        '/actions/$i',
        'step',
        '/actions/$i',
        w.action('${a['do']}', a['params'] as Map?),
        compiled: [many ? 'then_0_together_${i}_0' : 'then_0'],
        extra: {'thing': ?_thingOf(a['do'])},
      );
      _edge(group, id, insert: _insert('/actions/$i', 'step'));
      ends.add(_Open(id, insert: _insert('/actions/${i + 1}', 'step')));
    }
    _byId[group]!['children'] = [for (final n in nodes.skip(start)) n['id']];
    _node(merge, 'merge', null, '');
    _connect(ends, merge);
  }

  /// A link: its trigger, then its step.
  void _link(Map<String, Object?> spec, SentenceContext w) {
    readOnly = true;
    final chips = w.link(spec);
    String chip(String kind) =>
        '${chips.firstWhere((c) => c['kind'] == kind)['text']}';
    final from = _node(
      '/from',
      'trigger',
      '/from',
      chip('when'),
      compiled: ['source'],
      extra: {'thing': ?_thingOf(spec['from'])},
    );
    final to = _node(
      '/to',
      'step',
      '/to',
      chip('then'),
      compiled: ['flip', 'apply'],
      extra: {'thing': ?_thingOf(spec['to'])},
    );
    _edge(from, to);
  }

  /// A raw graph: its nodes and edges, with no paths.
  void _graph(Map<String, Object?> flow) {
    readOnly = true;
    for (final n in _maps(flow['nodes'])) {
      final type = '${n['type']}';
      final kind = switch (builtInNodeTypes[type]?.category) {
        NodeCategory.trigger => 'trigger',
        NodeCategory.condition => 'decision',
        _ when type == 'ask' => 'ask',
        _ when const {'delay', 'wait_until', 'wait_for_event'}.contains(type) =>
          'wait',
        _ => 'step',
      };
      _node(
        '${n['id']}',
        kind,
        null,
        '${n['label'] ?? n['id']}',
        compiled: ['${n['id']}'],
      );
    }
    for (final e in _maps(flow['edges'])) {
      final from = Map<String, Object?>.from(e['from'] as Map);
      final to = Map<String, Object?>.from(e['to'] as Map);
      final port = '${from['port'] ?? 'out'}';
      _ports[edges.length] = port;
      _edge(
        '${from['node']}',
        '${to['node']}',
        label: switch (port) {
          'true' => 'yes',
          'false' => 'no',
          'error' => 'fails',
          'body' => 'each',
          'timeout' => 'otherwise',
          _ => null,
        },
      );
    }
  }

  static String? _thingOf(Object? ref) {
    if (ref is! String || ref.startsWith('{{')) return null;
    final dot = ref.indexOf('.');
    return dot < 1 ? null : ref.substring(0, dot);
  }

  /// A run that a skip stands for: the trigger fired, and the check that
  /// said no said it with the value it saw.
  Map<String, Object?> skipTrace(SkipEntry skip, Map<String, Object?>? flow) {
    final out = <Map<String, Object?>>[
      {'node': skip.trigger, 'port': 'out'},
    ];
    final stop = skip.stop;
    final node = stop?['node'];
    if (skip.kind == SkipKind.condition && node is String) {
      final actual = _shown(stop?['actual']);
      if (node == 'only_if') {
        final at = _onlyIfPart(stop?['rule'], flow);
        out.add({
          'node': node,
          'port': 'false',
          'seen': _onlyIfCount <= 1
              ? actual
              : [
                  for (var i = 0; i < at; i++) {'ok': true},
                  {'ok': false, 'seen': ?actual},
                ],
        });
      } else {
        if (_onlyIfCount > 0) {
          out.add({
            'node': 'only_if',
            'port': 'true',
            if (_onlyIfCount > 1)
              'seen': [
                for (var i = 0; i < _onlyIfCount; i++) {'ok': true},
              ],
          });
        }
        out.add({'node': node, 'port': 'false', 'seen': ?actual});
      }
    }
    return {
      'run': null,
      'outcome': 'dropped',
      'startedAt': skip.at.toUtc().toIso8601String(),
      'nodes': out,
    };
  }

  /// Which onlyIf condition the failing part [rule] of the compiled
  /// `only_if` node is, or the first when it cannot be told.
  int _onlyIfPart(Object? rule, Map<String, Object?>? flow) {
    if (_onlyIfCount <= 1 || rule is! Map || flow == null) return 0;
    final node = _maps(flow['nodes']).where((n) => n['id'] == 'only_if');
    final parts = node.isEmpty
        ? const []
        : (node.first['config'] as Map?)?['rules'] as List? ?? const [];
    final wanted = canonicalJson(rule);
    for (var j = 0; j < parts.length; j++) {
      if (canonicalJson(parts[j]).contains(wanted)) return j;
    }
    return 0;
  }

  /// Lights the path [trace] took: each node's `status`, each decision's
  /// `seen`, and `taken` on each edge.
  void mark(Map<String, Object?> trace, {required bool continueOnError}) {
    final byId = <String, List<Map<String, Object?>>>{};
    for (final n in _maps(trace['nodes'])) {
      byId.putIfAbsent('${n['node']}', () => []).add(n);
    }
    final ports = <String, String?>{};
    final branch = <String, String>{};
    final continued = <String>{};
    for (final n in nodes) {
      final id = n['id'] as String;
      final compiled = (n['compiled'] as List? ?? const []).cast<String>();
      final seen = [for (final c in compiled) ...?byId[c]];
      if (_parts[id] case final part?) {
        _markCheck(n, part, seen.firstOrNull, branch);
        continue;
      }
      if (compiled.isEmpty) continue;
      if (seen.isEmpty) {
        n['status'] = 'skipped';
        continue;
      }
      final failed = seen.any(
        (e) =>
            (e['error'] != null && e['error'] != 'cancelled') ||
            e['port'] == 'error',
      );
      n['status'] = failed
          ? 'failed'
          : seen.every((e) => e['port'] == null)
          ? 'skipped'
          : 'ran';
      final last = seen.last;
      ports[id] = last['port'] as String?;
      if (last['port'] == 'error' && last['error'] != null && continueOnError) {
        continued.add(id);
      }
      if (n['kind'] == 'decision') {
        final port = last['port'];
        if (port == 'true') branch[id] = 'yes';
        if (port == 'false') branch[id] = 'no';
        _markSeen(n, last);
      } else if (n['kind'] == 'ask' && last.containsKey('seen')) {
        n['seen'] = last['seen'];
      }
    }
    for (final n in nodes) {
      if (n['kind'] == 'group' && n['status'] == null) {
        final kids = (n['children'] as List? ?? const []).map(
          (c) => _byId[c]?['status'],
        );
        n['status'] = kids.any((s) => s == 'ran' || s == 'failed')
            ? 'ran'
            : 'skipped';
      }
    }
    bool reached(String id) {
      final s = _byId[id]?['status'];
      return s == 'ran' || s == 'failed' || s == 'waiting';
    }

    bool onward(String id) {
      if (!reached(id)) return false;
      final port = ports[id];
      if (port == 'timeout' || port == 'false') return false;
      return port != 'error' || continued.contains(id);
    }

    for (var i = 0; i < edges.length; i++) {
      final e = edges[i];
      final from = e['from'] as String;
      final to = e['to'] as String;
      final target = _byId[to];
      final joins = target?['kind'] == 'merge' || target?['kind'] == 'end';
      final label = e['label'] as String?;
      bool taken;
      if (_ports[i] case final port?) {
        taken =
            (byId[from] ?? const []).any((t) => t['port'] == port) &&
            reached(to);
      } else if (label == 'yes' || label == 'no') {
        taken = branch[from] == label;
      } else if (label == 'fails') {
        taken = [
          for (final c in _failing[from] ?? const <String>{}) ...?byId[c],
        ].any((t) => t['port'] == 'error');
      } else if (label == 'otherwise' && _byId[from]?['kind'] == 'wait') {
        taken = ports[from] == 'timeout';
      } else if (_answers[from] case final answers? when label != null) {
        final own = answers[label];
        taken = own != null
            ? (byId[own] ?? const []).any((t) => t['port'] == 'true')
            : reached(from) &&
                  !answers.values.any(
                    (c) =>
                        c != null &&
                        (byId[c] ?? const []).any((t) => t['port'] == 'true'),
                  );
      } else {
        taken = onward(from) && (joins || reached(to));
      }
      e['taken'] = taken;
      if (taken && joins) target!['status'] = 'ran';
    }
    for (final n in nodes) {
      n['status'] ??= 'skipped';
    }
  }

  /// One onlyIf check from the compiled `only_if` node's trace [e]: each
  /// part up to the one that said no, from its `seen`.
  void _markCheck(
    Map<String, Object?> n,
    int part,
    Map<String, Object?>? e,
    Map<String, String> branch,
  ) {
    final id = n['id'] as String;
    if (e == null) {
      n['status'] = 'skipped';
      return;
    }
    final seen = e['seen'];
    if (_onlyIfCount <= 1) {
      n['status'] = 'ran';
      branch[id] = e['port'] == 'true' ? 'yes' : 'no';
      if (e.containsKey('seen')) n['seen'] = seen;
      return;
    }
    if (seen is List) {
      if (part >= seen.length) {
        n['status'] = 'skipped';
        return;
      }
      final p = Map<String, Object?>.from(seen[part] as Map);
      n['status'] = 'ran';
      branch[id] = p['ok'] == true ? 'yes' : 'no';
      if (p.containsKey('seen')) n['seen'] = p['seen'];
      return;
    }
    // A run logged before parts were kept: all yes, or one of them no.
    n['status'] = 'ran';
    if (e['port'] == 'true') branch[id] = 'yes';
  }

  /// A decision's `seen`, and each of its checks' when it has several.
  static void _markSeen(Map<String, Object?> n, Map<String, Object?> e) {
    if (!e.containsKey('seen')) return;
    final seen = e['seen'];
    final checks = n['checks'];
    if (seen is! List || checks is! List) {
      n['seen'] = seen;
      return;
    }
    for (var i = 0; i < seen.length && i < checks.length; i++) {
      final p = Map<String, Object?>.from(seen[i] as Map);
      if (p.containsKey('seen')) (checks[i] as Map)['seen'] = p['seen'];
    }
    final deciding = Map<String, Object?>.from(seen.last as Map);
    if (deciding.containsKey('seen')) n['seen'] = deciding['seen'];
  }

  static Object? _shown(Object? v) =>
      v == null || v is bool || v is num || (v is String && v.length <= 200)
      ? v
      : null;
}

/// Lays a rule into a [Diagram]: triggers, onlyIf checks, then the steps,
/// with keep steps in their own lane.
class _RuleProjector {
  _RuleProjector(this.d, this.w);

  final Diagram d;
  final SentenceContext w;

  void rule(Map<String, Object?> rule) {
    final when = _maps(rule['when']);
    var open = <_Open>[];
    for (var i = 0; i < when.length; i++) {
      final t = when[i];
      open.add(
        _Open(
          d._node(
            '/when/$i',
            'trigger',
            '/when/$i',
            w.trigger(t),
            compiled: [compiledNodeId('when[$i]')],
            extra: {'thing': ?Diagram._thingOf(t['on'])},
          ),
        ),
      );
    }
    final onlyIf = _maps(rule['onlyIf']);
    d._onlyIfCount = onlyIf.length;
    for (var j = 0; j < onlyIf.length; j++) {
      final check = d._node(
        '/onlyIf/$j',
        'check',
        '/onlyIf/$j',
        w.condition(onlyIf[j]),
        compiled: const ['only_if'],
      );
      d._parts[check] = j;
      d._connect([
        for (final o in open) o.at(_insert('/onlyIf/$j', 'check')),
      ], check);
      final end = d._node('/onlyIf/$j#end', 'end', null, 'Stops here');
      d._edge(
        check,
        end,
        label: 'no',
        insert: _insert('/onlyIf/${j + 1}', 'check'),
      );
      open = [_Open(check, label: 'yes')];
    }
    if (onlyIf.isEmpty) {
      open = [
        for (final o in open)
          _Open(o.from, alsoInsert: _insert('/onlyIf/0', 'check')),
      ];
    }
    final then = _maps(rule['then']);
    final firstKeep = then.indexWhere((s) => s.containsKey('keep'));
    final plain = firstKeep < 0 ? then.length : firstKeep;
    var ends = steps(then.sublist(0, plain), '/then', 'then', open);
    if (firstKeep < 0) {
      d._connect(ends, d._node('#end', 'end', null, 'Done'));
      return;
    }
    for (var n = firstKeep; n < then.length; n++) {
      keep(then[n], n, ends);
      ends = const [];
    }
  }

  /// A keep step as its own lane: its while, then what it keeps.
  void keep(Map<String, Object?> s, int n, List<_Open> open) {
    final ptr = '/then/$n';
    final id = compiledNodeId('then[$n]');
    final chips = w.rule({
      'then': [s],
    });
    final k = Map<String, Object?>.from(s['keep'] as Map);
    final more = _insert(
      '$ptr/keep/while/${(k['while'] as List? ?? const []).length}',
      'check',
    );
    final check = d._node(
      '$ptr/keep/while',
      'check',
      '$ptr/keep/while',
      '${chips.lastWhere((c) => c['kind'] == 'if')['text']}',
      compiled: [id],
      extra: const {'lane': 'keep'},
    );
    d._connect(open, check);
    final kept = d._node(
      ptr,
      'step',
      ptr,
      '${chips.firstWhere((c) => c['kind'] == 'then')['text']}',
      compiled: ['${id}_hold', '${id}_apply'],
      extra: {'lane': 'keep', 'thing': ?Diagram._thingOf(k['target'])},
    );
    d._edge(check, kept, label: 'yes', insert: more);
    final end = d._node('$ptr#end', 'end', null, 'Stops here');
    d._byId[end]!['lane'] = 'keep';
    d._edge(check, end, label: 'no', insert: more);
  }

  /// [list] at [base] (its compiled path [dot]) after [open]: the open
  /// ends after it, each adding at the end of the list.
  List<_Open> steps(
    List<Map<String, Object?>> list,
    String base,
    String dot,
    List<_Open> open,
  ) {
    var ends = open;
    var k = 0;
    while (k < list.length) {
      final entering = [
        for (final o in ends) o.at(_insert('$base/$k', 'step')),
      ];
      (ends, k) = block(list, k, base, dot, entering);
    }
    return [
      for (final o in ends) o.at(_insert('$base/${list.length}', 'step')),
    ];
  }

  /// The step [k] of [list] and what it holds, and the index after it.
  (List<_Open>, int) block(
    List<Map<String, Object?>> list,
    int k,
    String base,
    String dot,
    List<_Open> open,
  ) {
    final s = list[k];
    final ptr = '$base/$k';
    final dp = '$dot[$k]';
    final cid = compiledNodeId(dp);
    String merge() => d._node('$ptr#merge', 'merge', null, '');
    List<String> since(int start) => [
      for (final n in d.nodes.skip(start)) n['id'] as String,
    ];

    if (s['if'] is List) {
      final conds = _maps(s['if']);
      final decision = d._node(
        ptr,
        'decision',
        ptr,
        w.step(s).replaceFirst(RegExp('…\$'), ''),
        compiled: [cid],
        extra: {
          'checks': [
            for (var i = 0; i < conds.length; i++)
              {'path': '$ptr/if/$i', 'words': w.condition(conds[i])},
          ],
        },
      );
      d._connect(open, decision);
      final yes = steps(_maps(s['then']), '$ptr/then', '$dp.then', [
        _Open(decision, label: 'yes'),
      ]);
      final elseSteps = _maps(s['else']);
      final no = elseSteps.isEmpty
          ? [
              _Open(
                decision,
                label: 'no',
                insert: _insert('$ptr/else/0', 'step'),
              ),
            ]
          : steps(elseSteps, '$ptr/else', '$dp.else', [
              _Open(decision, label: 'no'),
            ]);
      final m = merge();
      d._connect([...yes, ...no], m);
      return ([_Open(m)], k + 1);
    }
    if (s['together'] is List) {
      final group = d._node(
        ptr,
        'group',
        ptr,
        w.step(s),
        compiled: [cid],
        extra: const {'group': 'together'},
      );
      d._connect(open, group);
      final start = d.nodes.length;
      final groups = s['together'] as List;
      final ends = <_Open>[];
      for (var g = 0; g < groups.length; g++) {
        ends.addAll(
          steps(_maps(groups[g]), '$ptr/together/$g', '$dp.together[$g]', [
            _Open(group),
          ]),
        );
      }
      d._byId[group]!['children'] = since(start);
      final m = merge();
      d._connect(ends, m);
      return ([_Open(m)], k + 1);
    }
    if (s['try'] is List) {
      final group = d._node(
        ptr,
        'group',
        ptr,
        w.step(s),
        extra: const {'group': 'try'},
      );
      d._connect(open, group);
      final start = d.nodes.length;
      final tried = steps(_maps(s['try']), '$ptr/try', '$dp.try', [
        _Open(group),
      ]);
      final children = since(start);
      d._byId[group]!['children'] = children;
      d._failing[group] = {
        for (final c in children)
          ...(d._byId[c]!['compiled'] as List? ?? const []).cast<String>(),
      };
      final otherwise = _maps(s['otherwise']);
      final failed = otherwise.isEmpty
          ? [
              _Open(
                group,
                label: 'fails',
                insert: _insert('$ptr/otherwise/0', 'step'),
              ),
            ]
          : steps(otherwise, '$ptr/otherwise', '$dp.otherwise', [
              _Open(group, label: 'fails'),
            ]);
      final m = merge();
      d._connect([...tried, ...failed], m);
      return ([_Open(m)], k + 1);
    }
    for (final key in const ['repeat', 'forEach']) {
      if (s[key] is! Map) continue;
      final inner = Map<String, Object?>.from(s[key] as Map);
      final header = w
          .step({
            key: {...inner, 'do': const <Object?>[]},
          })
          .replaceFirst(RegExp(r':\s*$'), '');
      final group = d._node(
        ptr,
        'group',
        ptr,
        header,
        compiled: [cid],
        extra: {'group': key},
      );
      d._connect(open, group);
      final start = d.nodes.length;
      final body = steps(_maps(inner['do']), '$ptr/$key/do', '$dp.$key.do', [
        _Open(group, label: 'each'),
      ]);
      d._byId[group]!['children'] = since(start);
      final m = merge();
      d._connect(body, m);
      return ([_Open(m)], k + 1);
    }
    if (s['ask'] is Map) return ask(list, k, base, dot, open);
    if (s['waitFor'] is Map) {
      final wait = d._node(ptr, 'wait', ptr, w.step(s), compiled: [cid]);
      d._connect(open, wait);
      final w8 = Map<String, Object?>.from(s['waitFor'] as Map);
      final late = steps(
        _maps(w8['onTimeout']),
        '$ptr/waitFor/onTimeout',
        '$dp.waitFor.onTimeout',
        [_Open(wait, label: 'otherwise')],
      );
      d._connect(late, d._node('$ptr#end', 'end', null, 'Stops here'));
      return ([_Open(wait)], k + 1);
    }
    final step = d._node(
      ptr,
      'step',
      ptr,
      w.step(s),
      compiled: [cid],
      extra: {'thing': ?Diagram._thingOf(s['do'] ?? s['toggle'])},
    );
    d._connect(open, step);
    return ([_Open(step)], k + 1);
  }

  /// An ask, with one way out per answer when the if steps right after it
  /// branch on the answer, each holding that if's steps.
  (List<_Open>, int) ask(
    List<Map<String, Object?>> list,
    int k,
    String base,
    String dot,
    List<_Open> open,
  ) {
    final s = list[k];
    final a = Map<String, Object?>.from(s['ask'] as Map);
    final ptr = '$base/$k';
    final node = d._node(
      ptr,
      'ask',
      ptr,
      w.step(s),
      compiled: [compiledNodeId('$dot[$k]')],
    );
    d._connect(open, node);
    final choices = [
      for (final c in a['choices'] as List? ?? const [])
        if (c is String) c,
    ];
    final answer = a['as'] is String ? a['as'] as String : '%answer';
    final branches = <String, int>{};
    var next = k + 1;
    while (next < list.length) {
      final value = _answerOf(list[next], answer);
      if (value == null ||
          !choices.contains(value) ||
          branches.containsKey(value)) {
        break;
      }
      branches[value] = next++;
    }
    if (branches.isEmpty) return ([_Open(node)], k + 1);
    d._answers[node] = {
      for (final c in choices)
        c: branches[c] == null ? null : compiledNodeId('$dot[${branches[c]}]'),
    };
    final ends = <_Open>[];
    for (final c in choices) {
      final at = branches[c];
      ends.addAll(
        at == null
            ? [_Open(node, label: c, insert: _insert('$base/$next', 'step'))]
            : steps(
                _maps(list[at]['then']),
                '$base/$at/then',
                '$dot[$at].then',
                [_Open(node, label: c)],
              ),
      );
    }
    final m = d._node('$ptr#merge', 'merge', null, '');
    d._connect(ends, m);
    return ([_Open(m)], next);
  }

  /// The answer an if step with one `{var: answer, op: ==, value}` check
  /// and no otherwise branches on, else null.
  static String? _answerOf(Map<String, Object?> s, String answer) {
    final conds = s['if'];
    if (conds is! List || conds.length != 1 || _maps(s['else']).isNotEmpty) {
      return null;
    }
    final c = conds.single;
    if (c is! Map || c['var'] != answer || c['op'] != '==') return null;
    final value = c['value'];
    return value is String ? value : null;
  }
}
