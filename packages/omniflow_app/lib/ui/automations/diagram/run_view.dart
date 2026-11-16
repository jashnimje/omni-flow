import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/diagram_calls.dart';
import '../../../api/engine_calls.dart';
import '../../../state/clock.dart' show hour12Provider;
import '../../../state/providers.dart';
import '../../design/design.dart';
import '../automations_state.dart' show ruleThingsProvider;
import '../dialogs.dart' show whenInline;
import '../../../rules/rule_spec.dart';
import '../rule_words.dart' show AutomationIcons, RuleWords, ThingWords;
import 'diagram_view.dart';
import 'rule_paths.dart' show partAt;

/// How long each node of a live run stays the newest before the next
/// one lights, so a quick run can be followed.
const liveStep = Duration(milliseconds: 350);

/// A run drawn on its diagram, sized to the page, with a button that
/// opens it full screen to pan and zoom.
class DiagramRunView extends ConsumerWidget {
  const DiagramRunView({
    super.key,
    required this.diagram,
    required this.title,
    this.spec,
  });

  final Diagram diagram;
  final String title;

  /// The rule the diagram draws, for each part's icon.
  final RuleSpec? spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DiagramPicture(
        diagram: diagram,
        handlers: runHandlers(ref, diagram, spec: spec),
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton.icon(
          key: const ValueKey('diagram-open'),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  DiagramRunPage(diagram: diagram, title: title, spec: spec),
            ),
          ),
          icon: const Icon(OmniIcons.search, size: 18),
          label: const Text('Open to zoom'),
          style: TextButton.styleFrom(
            minimumSize: const Size(OmniSpace.target, OmniSpace.target),
          ),
        ),
      ),
    ],
  );
}

/// A run's diagram on its own page, to pan and zoom.
class DiagramRunPage extends ConsumerWidget {
  const DiagramRunPage({
    super.key,
    required this.diagram,
    required this.title,
    this.spec,
  });

  final Diagram diagram;
  final String title;
  final RuleSpec? spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OmniPage(
    title: title,
    large: false,
    // The canvas runs edge to edge. The viewer pads its own toolbar.
    padded: false,
    body: DiagramViewer(
      diagram: diagram,
      handlers: runHandlers(ref, diagram, spec: spec),
    ),
  );
}

/// A read-only diagram's icons, the same the editor's diagram shows: each
/// device step and trigger its device's, and every other part its own (a
/// bell for a notify, a timer for a wait) from [spec], the rule the
/// diagram draws. Without the rule a part falls back to its kind's icon.
///
/// It rebuilds only when a device the diagram names changes its icon,
/// not on every device's state report.
DiagramHandlers runHandlers(WidgetRef ref, Diagram diagram, {RuleSpec? spec}) {
  final named = {for (final n in diagram.nodes) ?n.thing};
  ref.watch(
    ruleThingsProvider.select(
      (things) => [
        for (final t in things)
          if (named.contains(t.id) || spec != null)
            '${t.id}:${t.icon.codePoint}',
      ].join(','),
    ),
  );
  final words = RuleWords(ref.read(ruleThingsProvider));
  return DiagramHandlers(
    iconOf: (n) => switch (n.thing) {
      final id? => words.thing(id)?.icon,
      null => _partIcon(n, spec, words) ?? _kindIcon(n),
    },
  );
}

IconData? _partIcon(DiagramNode n, RuleSpec? spec, RuleWords words) {
  final path = n.path;
  if (spec == null || path == null) return null;
  return switch (partAt(spec, path)) {
    final RuleTrigger t => words.triggerIcon(t),
    final RuleCondition c => words.conditionIcon(c),
    final RuleStep s => words.stepIcon(s),
    _ => null,
  };
}

/// The icon for [n]'s kind, for a run of a rule the app does not have.
IconData? _kindIcon(DiagramNode n) => switch (n.kind) {
  NodeKind.wait => OmniIcons.wait,
  NodeKind.ask => AutomationIcons.ask,
  NodeKind.group => switch (n.group) {
    'together' => AutomationIcons.together,
    'try' => AutomationIcons.fallback,
    'repeat' => AutomationIcons.repeat,
    'forEach' => AutomationIcons.forEach,
    'scene' => OmniIcons.scene,
    _ => null,
  },
  _ => null,
};

/// The rule of the stored automation [id], for its run's icons, or null
/// when it is a graph or did not load.
Future<RuleSpec?> storedRule(WidgetRef ref, String id) async {
  try {
    final r = await ref.read(engineClientProvider).call(
      EngineCalls.automationGet,
      {'id': id},
    );
    if (r['ok'] != true) return null;
    final a = EngineCalls.automationOf(r);
    final spec = a['spec'];
    if (EngineCalls.formOf(a) != 'rule' || spec is! Map) return null;
    return RuleSpec.fromJson(Map<String, Object?>.from(spec));
  } on Object {
    return null;
  }
}

/// A dry run (a test run, or Try as if) on the diagram of the rule it
/// tested: [rule] when it is not saved, else the stored [id]. Nothing
/// shows when the engine gives no diagram.
class DryRunDiagram extends ConsumerStatefulWidget {
  const DryRunDiagram({super.key, required this.run, this.rule, this.id});

  final RunRecord run;
  final Json? rule;
  final String? id;

  @override
  ConsumerState<DryRunDiagram> createState() => _DryRunDiagramState();
}

class _DryRunDiagramState extends ConsumerState<DryRunDiagram> {
  Diagram? _diagram;
  RuleSpec? _spec;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rule = widget.rule;
    final Json args;
    if (rule != null) {
      args = DiagramCalls.specArgs(rule, id: widget.id);
      _spec = RuleSpec.fromJson(rule);
    } else if (widget.id case final id?) {
      args = {'id': id};
      unawaited(
        storedRule(ref, id).then((spec) {
          if (mounted && spec != null) setState(() => _spec = spec);
        }),
      );
    } else {
      return;
    }
    final d = await DiagramCalls.fetch(
      ref.read(engineClientProvider),
      // A real run is in the log; a dry run is handed over as it came.
      widget.run.dryRun
          ? DiagramCalls.dryRunArgs(args, widget.run)
          : {...args, 'run': widget.run.id},
    );
    if (!mounted || d == null) return;
    setState(() => _diagram = d);
  }

  @override
  Widget build(BuildContext context) {
    final d = _diagram;
    if (d == null) return const SizedBox.shrink();
    return KeyedSubtree(
      key: const ValueKey('dry-run-diagram'),
      child: DiagramRunView(diagram: d, title: 'Test run', spec: _spec),
    );
  }
}

/// The automation [id]'s last run on its diagram: the path it took lit,
/// what each check saw, and a trigger that was stopped marked on the
/// check that said no. While a run is going, its nodes light one by one
/// as the engine reports them. Nothing shows before it has run or been
/// stopped, or when the engine gives no diagram.
class LastRunSection extends ConsumerStatefulWidget {
  const LastRunSection({super.key, required this.id});

  final String id;

  @override
  ConsumerState<LastRunSection> createState() => _LastRunSectionState();
}

class _LastRunSectionState extends ConsumerState<LastRunSection> {
  RuleSpec? _spec;
  Diagram? _base;
  Diagram? _shown;
  String? _caption;
  StreamSubscription<Json>? _events;

  /// The run being animated, its marks so far, and the marks still to
  /// show.
  String? _liveRun;
  final _marks = <String, LiveMark>{};
  final _queue = Queue<LiveMark>();
  Timer? _stepper;
  var _finished = false;

  @override
  void initState() {
    super.initState();
    _events = ref.read(engineClientProvider).events.listen(_onEvent);
    _load();
    unawaited(
      storedRule(ref, widget.id).then((spec) {
        if (mounted && spec != null) setState(() => _spec = spec);
      }),
    );
  }

  @override
  void dispose() {
    _events?.cancel();
    _stepper?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(engineClientProvider);
    // Not run yet: a stopped trigger can still be shown.
    final shown =
        await DiagramCalls.fetch(client, DiagramCalls.lastArgs(widget.id)) ??
        await DiagramCalls.fetch(client, DiagramCalls.skipArgs(widget.id));
    final caption = switch (shown) {
      Diagram(skip: final skip?) =>
        'Stopped ${_when(skip['at'])}: '
            '${skip['reason'] ?? 'a check said no'}',
      Diagram(run: final run?) =>
        '${run['outcome'] == 'completed' ? 'Ran' : 'Did not finish'} '
            '${_when(run['startedAt'])}',
      _ => null,
    };
    if (!mounted || _liveRun != null) return;
    setState(() {
      // Only a diagram something lit: one never run nor stopped is quiet.
      _shown = shown != null && shown.hasRun ? shown : null;
      _caption = caption;
    });
  }

  String _when(Object? iso) => switch (DateTime.tryParse('$iso')) {
    final at? => whenInline(at.toLocal(), hour12: ref.read(hour12Provider)),
    null => 'lately',
  };

  void _onEvent(Json e) {
    if (e['flow'] != widget.id) return;
    if (e['event'] == DiagramCalls.runFinishedEvent) {
      if (_liveRun == null || e['run'] == _liveRun) {
        _finished = true;
        if (_queue.isEmpty) _endLive();
      }
      return;
    }
    final mark = DiagramCalls.liveOf(e);
    if (mark == null) return;
    if (mark.run != _liveRun) _startLive(mark.run);
    _queue.add(mark);
    if (OmniMotion.reduced(context)) {
      // No stepping under reduced motion: each mark shows as it comes.
      _drain();
      return;
    }
    _stepper ??= Timer.periodic(liveStep, (_) => _step());
  }

  void _startLive(String run) {
    _liveRun = run;
    _marks.clear();
    _queue.clear();
    _finished = false;
    if (_base == null) {
      DiagramCalls.fetch(
        ref.read(engineClientProvider),
        DiagramCalls.idArgs(widget.id),
      ).then((d) {
        if (!mounted || d == null) return;
        _base = d;
        _show();
      });
    }
    setState(() => _caption = 'Running now');
  }

  void _drain() {
    while (_queue.isNotEmpty) {
      final m = _queue.removeFirst();
      _marks[m.node] = m;
    }
    _show();
    if (_finished) _endLive();
  }

  void _step() {
    if (_queue.isEmpty) {
      _stepper?.cancel();
      _stepper = null;
      if (_finished) _endLive();
      return;
    }
    final m = _queue.removeFirst();
    _marks[m.node] = m;
    _show();
  }

  void _show() {
    final base = _base;
    if (base == null || !mounted) return;
    final byNode = <String, LiveMark>{
      for (final m in _marks.values) ?base.nodeOf(m): m,
    };
    setState(() => _shown = base.withLive(byNode));
  }

  void _endLive() {
    _stepper?.cancel();
    _stepper = null;
    _liveRun = null;
    _finished = false;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    final live = _liveRun != null;
    return Column(
      key: const ValueKey('last-run'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniSectionHeader(live ? 'Running now' : 'Last run'),
        if (_caption case final caption? when !live)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: Text(
              caption,
              key: const ValueKey('last-run-caption'),
              style: OmniText.caption,
            ),
          ),
        KeyedSubtree(
          key: const ValueKey('last-run-diagram'),
          child: DiagramRunView(
            diagram: shown,
            title: live ? 'Running now' : 'Last run',
            spec: _spec,
          ),
        ),
      ],
    );
  }
}
