import 'engine_calls.dart';
import 'engine_client.dart';

/// The calls behind the automation diagram: `automation.diagram` and the
/// live `run.node` event, with their argument shapes and the fields read
/// back. When the engine's shape changes, the change is made here.
///
/// `automation.diagram {id | spec, run? | last? | dryRun?, skipsToo?}`
/// gives `{nodes, edges, source, readOnly?, run?, skip?, issues?}`:
///
/// - a node `{id, kind, path?, words, compiled?, children?, group?,
///   checks?, lane?, thing?, status?, seen?}`. A rule node's id is its
///   path, a JSON pointer into the rule (`/then/2`); merges and ends have
///   no path.
/// - an edge `{from, to, label?, insert?, alsoInsert?, taken?}`
///
/// `status`, `seen` and `taken` come only for a run.
abstract final class DiagramCalls {
  static const diagram = 'automation.diagram';
  static const runNodeEvent = 'run.node';
  static const runFinishedEvent = 'run.finished';

  /// The diagram of the rule [spec] as it stands, saved or not.
  static Json specArgs(Json spec, {String? id}) => {'spec': spec, 'id': ?id};

  /// The diagram of the stored automation [id], lit by its run [run].
  static Json idArgs(String id, {String? run}) => {'id': id, 'run': ?run};

  /// The diagram of [id] lit by its newest run, or by the newest trigger
  /// that was stopped when that came later.
  static Json lastArgs(String id) => {'id': id, 'last': true, 'skipsToo': true};

  /// The diagram of [id] lit by its newest stopped trigger only, for an
  /// automation that has not run yet.
  static Json skipArgs(String id) => {'id': id, 'skipsToo': true};

  /// [args] lit by the dry run [run] (a test run or Try as if).
  static Json dryRunArgs(Json args, RunRecord run) => {
    ...args,
    'dryRun': traceOf(run),
  };

  /// [run] in the shape the engine logs a run, for `dryRun`.
  static Json traceOf(RunRecord run) => {
    'run': run.id,
    'flow': run.automationId,
    'outcome': run.outcome,
    'startedAt': run.startedAt.toUtc().toIso8601String(),
    'dryRun': run.dryRun,
    'nodes': [
      for (final n in run.steps)
        {
          'node': n.node,
          'type': n.type,
          'port': ?n.port,
          'error': ?n.error,
          'output': ?n.output,
          'seen': ?n.seen,
        },
    ],
  };

  /// Asks for a diagram. A failed or unknown command gives null, never a
  /// throw, so a view without one falls back to its words.
  static Future<Diagram?> fetch(EngineClient client, Json args) async {
    try {
      final result = await client.call(diagram, args);
      if (result['ok'] != true) return null;
      final d = Diagram.fromJson(result);
      return d.nodes.isEmpty ? null : d;
    } on Object {
      return null;
    }
  }

  /// The `run.node` event as a live mark, or null for any other event.
  static LiveMark? liveOf(Json event) {
    if (event['event'] != runNodeEvent) return null;
    final node = event['node'];
    if (node is! String) return null;
    return LiveMark(
      run: '${event['run'] ?? ''}',
      flow: '${event['flow'] ?? ''}',
      node: node,
      path: event['path'] as String?,
      status: '${event['status'] ?? NodeStatus.ran}',
      port: event['port'] as String?,
      seen: seenText(event['seen']),
    );
  }

  /// What a check saw, as words: the value, or for a check of several
  /// parts the part that decided.
  static String? seenText(Object? v) => switch (v) {
    null => null,
    final String s => s.isEmpty ? null : s,
    final bool b => b ? 'on' : 'off',
    final List parts when parts.isNotEmpty && parts.last is Map => seenText(
      (parts.last as Map)['seen'],
    ),
    final List _ => null,
    final Map m => seenText(m['seen'] ?? m['text']),
    _ => '$v',
  };
}

/// What a node did in a run.
abstract final class NodeStatus {
  static const ran = 'ran';
  static const failed = 'failed';
  static const skipped = 'skipped';
  static const waiting = 'waiting';
}

/// The kinds of node a diagram has.
abstract final class NodeKind {
  static const trigger = 'trigger';
  static const check = 'check';
  static const decision = 'decision';
  static const step = 'step';
  static const ask = 'ask';
  static const wait = 'wait';
  static const group = 'group';
  static const merge = 'merge';
  static const end = 'end';

  static bool isDecision(String kind) => kind == check || kind == decision;

  /// Merges and ends join lines; they are not parts of the rule.
  static bool isJoin(String kind) => kind == merge || kind == end;
}

/// One live `run.node` event.
class LiveMark {
  const LiveMark({
    required this.run,
    required this.flow,
    required this.node,
    required this.status,
    this.path,
    this.port,
    this.seen,
  });

  final String run;
  final String flow;

  /// The compiled flow node that ran.
  final String node;

  /// Its place in the rule, which is the diagram node's id, when the
  /// engine knows it.
  final String? path;
  final String status;
  final String? port;
  final String? seen;
}

/// One condition of an If's decision, editable on its own.
class DiagramCheck {
  const DiagramCheck({required this.path, required this.words, this.seen});

  final String path;
  final String words;
  final String? seen;
}

class DiagramNode {
  const DiagramNode({
    required this.id,
    required this.kind,
    this.path,
    this.words = '',
    this.compiled = const [],
    this.children = const [],
    this.group,
    this.checks = const [],
    this.lane,
    this.thing,
    this.risk,
    this.status,
    this.seen,
    this.saidNo = false,
  });

  factory DiagramNode.fromJson(Json json) => DiagramNode(
    id: '${json['id']}',
    kind: '${json['kind'] ?? NodeKind.step}',
    path: json['path'] is String && (json['path'] as String).isNotEmpty
        ? json['path'] as String
        : null,
    words: '${json['words'] ?? ''}',
    compiled: [for (final c in (json['compiled'] as List? ?? const [])) '$c'],
    children: [for (final c in (json['children'] as List? ?? const [])) '$c'],
    group: json['group'] as String?,
    checks: [
      for (final c in (json['checks'] as List? ?? const []))
        if (c is Map && c['path'] is String)
          DiagramCheck(
            path: c['path'] as String,
            words: '${c['words'] ?? ''}',
            seen: DiagramCalls.seenText(c['seen']),
          ),
    ],
    lane: json['lane'] as String?,
    thing: json['thing'] as String?,
    risk: switch (json['risk']) {
      null || false || 'none' || 'low' => null,
      true => 'high',
      final Object r => '$r',
    },
    status: json['status'] as String?,
    seen: DiagramCalls.seenText(json['seen']),
  );

  final String id;
  final String kind;

  /// A JSON pointer into the rule (`/then/2/if/0`), or null for a merge,
  /// an end, or a node of a raw graph.
  final String? path;
  final String words;

  /// The compiled flow node ids it stands for, which `run.node` names.
  final List<String> compiled;

  /// A group's nodes, for the box drawn round them.
  final List<String> children;

  /// What kind of group: `together`, `try`, `repeat`, `forEach`, `scene`.
  final String? group;

  /// An If's conditions, each editable on its own.
  final List<DiagramCheck> checks;

  /// `keep` for a keep step's own lane.
  final String? lane;

  /// The device a step or trigger uses, for its icon.
  final String? thing;

  /// Set for a step that needs approval when an agent writes it.
  final String? risk;
  final String? status;

  /// The value a check saw.
  final String? seen;

  /// The check that stopped a trigger, in a diagram lit by a skip.
  final bool saidNo;

  DiagramNode copyWith({String? status, String? seen, bool? saidNo}) =>
      DiagramNode(
        id: id,
        kind: kind,
        path: path,
        words: words,
        compiled: compiled,
        children: children,
        group: group,
        checks: checks,
        lane: lane,
        thing: thing,
        risk: risk,
        status: status ?? this.status,
        seen: seen ?? this.seen,
        saidNo: saidNo ?? this.saidNo,
      );
}

/// Where a "+" on an edge adds: a step or a check at [path], a JSON
/// pointer to the place in a list the new item takes.
class DiagramInsert {
  const DiagramInsert({required this.path, required this.as});

  static const step = 'step';
  static const check = 'check';
  static const trigger = 'trigger';

  static DiagramInsert? fromJson(Object? json) => switch (json) {
    final Map m when m['path'] is String => DiagramInsert(
      path: m['path'] as String,
      as: '${m['as'] ?? step}',
    ),
    _ => null,
  };

  final String path;
  final String as;
}

class DiagramEdge {
  const DiagramEdge({
    required this.from,
    required this.to,
    this.label,
    this.taken,
    this.insert,
    this.alsoInsert,
  });

  factory DiagramEdge.fromJson(Json json) => DiagramEdge(
    from: '${json['from']}',
    to: '${json['to']}',
    label: json['label'] as String?,
    taken: json['taken'] as bool?,
    insert: DiagramInsert.fromJson(json['insert']),
    alsoInsert: DiagramInsert.fromJson(json['alsoInsert']),
  );

  final String from;
  final String to;

  /// `yes`, `no`, `otherwise`, `fails`, `each` or an Ask answer.
  final String? label;
  final bool? taken;
  final DiagramInsert? insert;

  /// A second thing a "+" here can add: a check on a trigger's line when
  /// the rule has none yet.
  final DiagramInsert? alsoInsert;

  DiagramEdge withTaken(bool taken) => DiagramEdge(
    from: from,
    to: to,
    label: label,
    taken: taken,
    insert: insert,
    alsoInsert: alsoInsert,
  );
}

/// An automation as a decision graph.
class Diagram {
  const Diagram({
    required this.nodes,
    required this.edges,
    this.source,
    this.readOnly = false,
    this.run,
    this.skip,
    this.issues = const [],
  });

  factory Diagram.fromJson(Json json) {
    final nodes = [
      for (final n in (json['nodes'] as List? ?? const []))
        if (n is Map && n['id'] != null)
          DiagramNode.fromJson(Map<String, Object?>.from(n)),
    ];
    final ids = {for (final n in nodes) n.id};
    Json? map(Object? v) => v is Map ? Map<String, Object?>.from(v) : null;
    final edges = [
      for (final e in (json['edges'] as List? ?? const []))
        if (e is Map && ids.contains('${e['from']}'))
          if (ids.contains('${e['to']}'))
            DiagramEdge.fromJson(Map<String, Object?>.from(e)),
    ];
    final skip = map(json['skip']);
    // Lit by a skip, the check that took its no line is the one that
    // stopped the trigger.
    final stoppedAt = skip == null
        ? const <String>{}
        : {
            for (final e in edges)
              if (e.label == 'no' && e.taken == true) e.from,
          };
    return Diagram(
      nodes: [
        for (final n in nodes)
          stoppedAt.contains(n.id) ? n.copyWith(saidNo: true) : n,
      ],
      edges: edges,
      source: json['source'] as String?,
      readOnly: json['readOnly'] == true,
      run: map(json['run']),
      skip: skip,
      issues: [
        for (final i in (json['issues'] as List? ?? const []))
          if (i is Map) (path: '${i['path']}', message: '${i['message']}'),
      ],
    );
  }

  final List<DiagramNode> nodes;
  final List<DiagramEdge> edges;

  /// `rule`, `scene`, `link` or `graph`.
  final String? source;

  /// A link or a raw graph: shown, never edited, and no "+".
  final bool readOnly;

  /// The run it is lit by: `{run, outcome, startedAt, dryRun}`.
  final Json? run;

  /// The stopped trigger it is lit by: `{at, trigger, kind, reason, ...}`.
  final Json? skip;

  /// Why an unsaved rule does not save yet, by rule path.
  final List<({String path, String message})> issues;

  bool get editable => !readOnly;

  /// Whether any node carries what a run did.
  bool get hasRun => nodes.any((n) => n.status != null);

  DiagramNode? node(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// The diagram node a live mark is about: by its rule path, else by the
  /// compiled node it names.
  String? nodeOf(LiveMark mark) {
    if (mark.path case final p? when node(p) != null) return p;
    for (final n in nodes) {
      if (n.compiled.contains(mark.node)) return n.id;
    }
    return null;
  }

  /// This diagram with the live marks of one run so far, by diagram node
  /// id: the nodes they name take their status, an edge is taken once
  /// its start was reached and its end was too (or is a merge or end the
  /// way its start left leads to), and a merge or end reached is lit.
  Diagram withLive(Map<String, LiveMark> marks) {
    bool reachedMark(String id) {
      final s = marks[id]?.status;
      return s == NodeStatus.ran ||
          s == NodeStatus.failed ||
          s == NodeStatus.waiting;
    }

    bool leaves(DiagramEdge e) => switch ((e.label, marks[e.from]?.port)) {
      ('yes', final p) => p == null || p == 'true',
      ('no', final p) => p == 'false',
      ('otherwise', final p) => p == 'timeout' || p == 'false',
      ('fails', final p) => p == 'error',
      (_, final p) => p != 'false' && p != 'error' && p != 'timeout',
    };

    final joined = <String>{};
    final taken = List<bool>.filled(edges.length, false);
    var changed = true;
    while (changed) {
      changed = false;
      for (final (i, e) in edges.indexed) {
        if (taken[i]) continue;
        final from = reachedMark(e.from) || joined.contains(e.from);
        if (!from) continue;
        final joins = NodeKind.isJoin(node(e.to)?.kind ?? '');
        final to = reachedMark(e.to) || (joins && leaves(e));
        if (!to) continue;
        taken[i] = true;
        changed = true;
        if (joins) joined.add(e.to);
      }
    }
    return Diagram(
      nodes: [
        for (final n in nodes)
          switch (marks[n.id]) {
            final m? => n.copyWith(status: m.status, seen: m.seen),
            null when joined.contains(n.id) => n.copyWith(
              status: NodeStatus.ran,
            ),
            null => n,
          },
      ],
      edges: [for (final (i, e) in edges.indexed) e.withTaken(taken[i])],
      source: source,
      readOnly: readOnly,
    );
  }
}
