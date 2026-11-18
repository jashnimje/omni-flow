import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart'
    show NodeCategory, builtInNodeTypes;

import '../../api/engine_calls.dart';
import '../../api/plain_error.dart';
import '../../state/clock.dart' show hour12Provider, timeOfDayText;
import '../../state/providers.dart';
import '../design/design.dart';
import 'diagram/run_view.dart' show DryRunDiagram;
import 'dialogs.dart';
import 'rule_words.dart';
import 'run_words.dart';

/// 2.4: what a dry run would do now, node by node, then the last real
/// runs, each opening the same view for that run.

NodeCategory? _category(String type) => builtInNodeTypes[type]?.category;

Color _color(OmniPalette palette, NodeCategory? c) => switch (c) {
  NodeCategory.trigger => palette.trigger,
  NodeCategory.condition => palette.condition,
  NodeCategory.gate || NodeCategory.flowControl => palette.flowControl,
  NodeCategory.action => palette.action,
  _ => palette.muted,
};

/// The node ids of [flow] (an automation.get `flow`) with their labels,
/// which are the steps as the rule wrote them.
Map<String, String> labelsOf(Json? flow) => {
  for (final n in (flow?['nodes'] as List? ?? const []))
    if (n is Map && n['label'] is String) '${n['id']}': n['label'] as String,
};

/// The steps a run took that do something: not its trigger or checks.
int stepsOf(RunRecord run) => run.steps.where((n) {
  final c = _category(n.type);
  return c != NodeCategory.trigger && c != NodeCategory.condition;
}).length;

/// The node types that act on a device, whose output's `result` is their
/// own. Every later step passes the same message on, so a notify after a
/// device step still carries that step's result and must not show it.
const _deviceSteps = {'device_capability', 'device_toggle'};

/// The node types that announce, whose `announced` is their own.
const _announces = {'notify', 'speak'};

/// [raw] as a failure reads in a run: plain words, no address or port.
String _failureText(String raw) =>
    plainWords(plainError('device_error', raw)).text;

/// What a node did, or in a dry run would do, in plain words.
/// [goesOn] is whether the run went past [n]: a check that does not hold
/// stops a rule, but in an if it takes the otherwise way instead.
/// [now] is whether a dry run was judged at the time it was made, not at
/// its trigger's own time (a test run against Try as if).
String? _detail(
  RunNode n, {
  required bool dry,
  bool goesOn = false,
  bool now = false,
}) {
  if (n.error case final e?) {
    final plain = _failureText(e);
    return dry ? 'would fail: $plain' : plain;
  }
  final c = _category(n.type);
  final own = _deviceSteps.contains(n.type) || n.type == 'http_request';
  final result = own ? (n.output?['result']) : null;
  switch (c) {
    case NodeCategory.trigger:
      return !dry
          ? 'started this run'
          : now
          ? 'pretended it happened now'
          : 'pretended it happened';
    case NodeCategory.condition:
      return switch (n.port) {
        'true' => 'holds',
        'false' when goesOn => 'does not hold, so it goes the other way',
        'false' => 'does not hold, so it stops here',
        _ => null,
      };
    case NodeCategory.action:
      if (_announces.contains(n.type)) {
        final a = n.output?['announced'];
        final words = a is Map ? a['title'] ?? a['text'] : null;
        final verb = n.type == 'speak'
            ? (dry ? 'would say' : 'said')
            : (dry ? 'would show' : 'showed');
        return words == null ? (dry ? null : 'done') : '$verb "$words"';
      }
      if (n.type == 'http_request' &&
          result is Map &&
          result['dryRun'] == true) {
        return 'would call ${result['url'] ?? 'the web address'}';
      }
      if (result is Map && result['dryRun'] == true) {
        final params = result['params'] is Map ? result['params'] as Map : {};
        return result['toggle'] == true
            ? 'would toggle ${result['capabilityId']}'
            : 'would send ${result['capabilityId']}'
                  '${params.isEmpty ? '' : ' ${params.entries.map((e) => e.key == 'value' ? valueText(e.value) : '${e.key} ${valueText(e.value)}').join(', ')}'}';
      }
      return dry ? null : 'done';
    default:
      return null;
  }
}

/// Each node of a run as a row: a dot in its category colour, the step,
/// what it did, and a check, an arrow or a cross.
class RunNodeRows extends StatelessWidget {
  const RunNodeRows({
    super.key,
    required this.run,
    this.labels = const {},
    this.now = false,
  });

  final RunRecord run;
  final Map<String, String> labels;

  /// A dry run judged at the time it was made (a test run), so its
  /// trigger reads "pretended it happened now".
  final bool now;

  @override
  Widget build(BuildContext context) {
    final dry = run.dryRun;
    final hour12 = ProviderScope.containerOf(context).read(hour12Provider);
    return Column(
      children: [
        for (final (i, n) in run.steps.indexed)
          OmniListRow(
            key: ValueKey('node-$i'),
            leading: _Dot(_color(OmniPalette.of(context), _category(n.type))),
            title: stepWords(
              n.label ?? labels[n.node] ?? n.type.replaceAll('_', ' '),
              hour12: hour12,
            ),
            subtitle: _detail(
              n,
              dry: dry,
              goesOn: i < run.steps.length - 1,
              now: now,
            ),
            subtitleLines: 3,
            trailing: _verdict(
              context,
              n,
              dry: dry,
              goesOn: i < run.steps.length - 1,
            ),
          ),
      ],
    );
  }

  static Widget _verdict(
    BuildContext context,
    RunNode n, {
    required bool dry,
    bool goesOn = false,
  }) {
    final accent = OmniPalette.of(context).accent;
    final c = _category(n.type);
    if (n.error != null) {
      return Icon(
        AutomationIcons.fail,
        color: OmniPalette.of(context).bad,
        semanticLabel: 'Fails',
      );
    }
    if (c == NodeCategory.condition) {
      final pass = n.port == 'true';
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pass
                ? OmniIcons.check
                : goesOn
                ? OmniIcons.branch
                : AutomationIcons.stop,
            size: 18,
            color: pass ? accent : OmniPalette.of(context).warn,
          ),
          const SizedBox(width: OmniSpace.xs),
          Text(
            pass
                ? 'pass'
                : goesOn
                ? 'other way'
                : 'stops',
            style: OmniText.number.copyWith(
              color: pass ? accent : OmniPalette.of(context).warn,
            ),
          ),
        ],
      );
    }
    if (c == NodeCategory.trigger || !dry) {
      return Icon(OmniIcons.check, color: accent, semanticLabel: 'Done');
    }
    return Icon(
      AutomationIcons.send,
      color: accent,
      semanticLabel: 'Would run',
    );
  }
}

/// The filled category dot of a node, in an icon box's place.
class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: OmniPalette.of(context).raised,
      borderRadius: BorderRadius.circular(OmniRadii.iconBox),
    ),
    child: Icon(AutomationIcons.dot, size: 12, color: color, fill: 1),
  );
}

/// A run in the "Last runs" list: when, how many steps and how long, or
/// why it failed.
class RunRow extends StatelessWidget {
  const RunRow({super.key, required this.run, this.onTap});

  final RunRecord run;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final raw =
        run.steps.where((n) => n.error != null).firstOrNull?.error ??
        run.reason;
    final failed = raw == null ? null : _failureText(raw);
    final steps = stepsOf(run);
    return OmniListRow(
      title: whenText(
        run.startedAt,
        hour12: ProviderScope.containerOf(context).read(hour12Provider),
      ),
      subtitle: run.ok
          ? [
              '$steps ${steps == 1 ? 'step' : 'steps'}',
              if (run.duration case final d?) tookText(d),
            ].join(' · ')
          : failed ?? run.outcome,
      trailing: Icon(
        run.ok ? OmniIcons.check : AutomationIcons.fail,
        color: run.ok
            ? OmniPalette.of(context).accent
            : OmniPalette.of(context).bad,
        semanticLabel: run.ok ? 'Worked' : 'Failed',
      ),
      onTap: onTap,
    );
  }
}

/// What a [TestRunPage] is for. Each entry to it has its own purpose and
/// title, so two of them never answer the same question two ways.
enum TestRunKind {
  /// A link's page: a test of it now, then its real runs.
  testAndRuns,

  /// The editor's Test run: what the rule would do if it started now,
  /// judged at the time of the test.
  test,

  /// Pretend this just happened: what the rule would do if one trigger
  /// happened, judged at that trigger's own time.
  tryAsIf,

  /// Runs: the real runs only, newest first.
  runs,
}

/// The test of an automation: the dry run, then its real runs. [dryRun] is
/// the dry run the editor already made of the rule as it stands; without
/// it the page dry-runs the stored automation [id]. [kind] picks which of
/// those it shows.
class TestRunPage extends ConsumerStatefulWidget {
  const TestRunPage({
    super.key,
    required this.name,
    this.id,
    this.dryRun,
    this.actions = const [],
    this.unsaved = false,
    this.rule,
    this.header,
    this.kind = TestRunKind.testAndRuns,
  });

  final TestRunKind kind;

  /// The rule the dry run tested, when it is not saved, so its diagram
  /// draws the rule as it stands.
  final Json? rule;

  /// Shown above the test (a graph's last run).
  final Widget? header;

  /// The dry run is of edits not saved yet, so a real run would run the
  /// saved version instead: it asks to save first.
  final bool unsaved;

  final String name;

  /// Header actions (a link's Remove).
  final List<Widget> actions;

  /// Null for a rule not saved yet, which has no runs.
  final String? id;
  final RunRecord? dryRun;

  @override
  ConsumerState<TestRunPage> createState() => _TestRunPageState();
}

class _TestRunPageState extends ConsumerState<TestRunPage> {
  RunRecord? _dry;
  var _dryDone = false;
  ApiFailure? _dryFailure;
  List<RunRecord>? _runs;
  ApiFailure? _runsFailure;
  var _labels = <String, String>{};

  bool get _tests => widget.kind != TestRunKind.runs;

  bool get _lists =>
      widget.kind == TestRunKind.testAndRuns || widget.kind == TestRunKind.runs;

  @override
  void initState() {
    super.initState();
    _dry = widget.dryRun;
    _dryDone = widget.dryRun != null || widget.id == null || !_tests;
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(engineApiProvider);
    final id = widget.id;
    if (_dry == null && id != null && _tests) {
      final dry = await api.dryRun(id: id);
      if (!mounted) return;
      setState(() {
        _dry = dry.value?.firstOrNull;
        _dryDone = true;
        _dryFailure = dry.failure;
      });
    }
    if (id == null) return;
    final got = await api.automation(id);
    // A test alone lists no runs, so it reads none.
    final runs = _lists ? await api.runLog(id: id, limit: 20) : null;
    if (!mounted) return;
    setState(() {
      _labels = labelsOf(got.value?['flow'] as Json?);
      _runs = [
        for (final r in runs?.or(const []) ?? const <RunRecord>[])
          if (!r.dryRun) r,
      ];
      _runsFailure = runs?.failure;
    });
  }

  var _running = false;

  /// Runs it now, sending every step, then opens what that run did.
  Future<void> _runNow() async {
    setState(() => _running = true);
    final started = await ref.read(engineApiProvider).runAutomation(widget.id!);
    if (!mounted) return;
    setState(() => _running = false);
    await _load();
    if (!mounted) return;
    if (started.value?.firstOrNull case final run?) _openRun(run);
  }

  void _openRun(RunRecord run) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => RunPage(
        name: widget.name,
        automationId: run.automationId,
        run: run,
        labels: _labels,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dry = _dry;
    final runs = _runs;
    final canRun = _dryDone && widget.id != null && !widget.unsaved;
    final hour12 = ref.watch(hour12Provider);
    final trigger = dry?.steps
        .where((n) => _category(n.type) == NodeCategory.trigger)
        .firstOrNull;
    final triggerWords = trigger == null
        ? null
        : stepWords(
            trigger.label ?? _labels[trigger.node] ?? '',
            hour12: hour12,
          );
    final told = switch (widget.kind) {
      TestRunKind.test when dry != null =>
        'Nothing was sent. This is what would happen if it started now, at '
            '${timeOfDayText(hour12, dry.startedAt)}.',
      TestRunKind.tryAsIf
          when triggerWords != null && triggerWords.isNotEmpty =>
        'Nothing was sent. This is what would happen if this happened: '
            '$triggerWords.',
      _ => 'Nothing was sent. This is what would happen.',
    };
    return DetailPage(
      title: switch (widget.kind) {
        TestRunKind.testAndRuns => '${widget.name} · test',
        TestRunKind.test => '${widget.name} · test run',
        TestRunKind.tryAsIf => '${widget.name} · pretend',
        TestRunKind.runs => '${widget.name} · runs',
      },
      actions: widget.actions,
      bottom: canRun
          ? OmniActionBar(
              primary: OmniButton(
                key: const ValueKey('run-now'),
                label: _running ? 'Running…' : 'Run it now for real',
                onPressed: _running ? null : _runNow,
              ),
            )
          : null,
      children: (context) => [
        ?widget.header,
        if (!_tests)
          const SizedBox.shrink()
        else if (_dryFailure != null)
          OmniErrorBanner(
            'The test could not run: ${_dryFailure!.message}',
            onRetry: () {
              setState(() {
                _dryFailure = null;
                _dryDone = false;
              });
              _load();
            },
          )
        else if (!_dryDone)
          const OmniListSkeleton(rows: 3, label: 'Testing it')
        else ...[
          OmniBanner.info(told, key: const ValueKey('dry-run-banner')),
          if (dry == null || dry.steps.isEmpty)
            const OmniEmptyState(
              icon: OmniIcons.info,
              title: 'Nothing would run',
              message: 'Its WHEN did not lead to any step.',
              compact: true,
            )
          else ...[
            // The same run twice: on the diagram, then step by step.
            DryRunDiagram(run: dry, rule: widget.rule, id: widget.id),
            RunNodeRows(
              key: const ValueKey('dry-run'),
              run: dry,
              labels: _labels,
              now:
                  widget.kind == TestRunKind.test ||
                  widget.kind == TestRunKind.testAndRuns,
            ),
          ],
          if (widget.id == null || widget.unsaved)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.md),
              child: Text(
                widget.id == null
                    ? 'Save it to run it for real.'
                    : 'Save your changes to run this version for real.',
                key: const ValueKey('save-to-run'),
                style: OmniText.captionOf(context),
              ),
            ),
        ],
        if (widget.id != null && _lists) ...[
          if (_tests) const OmniSectionHeader('Last runs'),
          if (_runsFailure != null)
            OmniErrorBanner(
              'The run log did not load. ${_runsFailure!.message}',
              onRetry: _load,
            )
          else if (runs == null)
            const OmniListSkeleton(rows: 3, label: 'Loading the runs')
          else if (runs.isEmpty)
            const OmniEmptyState(
              key: ValueKey('no-runs'),
              icon: OmniIcons.time,
              title: 'It has not run yet',
              message: 'Runs show here, newest first.',
              compact: true,
            )
          else
            for (final (i, r) in runs.indexed)
              RunRow(key: ValueKey('run-$i'), run: r, onTap: () => _openRun(r)),
        ],
      ],
    );
  }
}

/// One real run, step by step. Opened from the last runs, or from a
/// failed-run notification with only the ids ([run] null).
class RunPage extends ConsumerStatefulWidget {
  const RunPage({
    super.key,
    required this.automationId,
    this.runId,
    this.run,
    this.name,
    this.labels,
  });

  final String automationId;
  final String? runId;
  final RunRecord? run;
  final String? name;
  final Map<String, String>? labels;

  @override
  ConsumerState<RunPage> createState() => _RunPageState();
}

class _RunPageState extends ConsumerState<RunPage> {
  RunRecord? _run;
  String? _name;
  Map<String, String> _labels = const {};
  var _loading = false;
  var _missing = false;
  var _rerunning = false;
  ApiFailure? _failure;

  /// Runs the automation again and shows that run in place of this one.
  Future<void> _runAgain() async {
    setState(() => _rerunning = true);
    final reply = await ref
        .read(engineApiProvider)
        .runAutomation(widget.automationId);
    if (!mounted) return;
    setState(() {
      _rerunning = false;
      if (reply.value?.firstOrNull case final run?) _run = run;
    });
  }

  @override
  void initState() {
    super.initState();
    _run = widget.run;
    _name = widget.name;
    _labels = widget.labels ?? const {};
    if (_run == null || widget.labels == null) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final api = ref.read(engineApiProvider);
    final got = await api.automation(widget.automationId);
    RunRecord? run = _run;
    ApiFailure? failure = got.failure;
    if (run == null) {
      final log = await api.runLog(id: widget.automationId, limit: 50);
      failure ??= log.failure;
      run = log.or(const []).where((r) => r.id == widget.runId).firstOrNull;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _run = run;
      _failure = run == null ? failure : null;
      _missing = run == null && failure == null;
      _name ??= got.value?['name'] as String?;
      _labels = labelsOf(got.value?['flow'] as Json?);
    });
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    final raw =
        run?.steps.where((n) => n.error != null).firstOrNull?.error ??
        run?.reason;
    final failed = raw == null ? null : _failureText(raw);
    final failure = _failure;
    return DetailPage(
      // The name, never the id, until the automation is read.
      title: '${_name ?? 'Automation'} · run',
      state: failure != null
          ? OmniLoad.error('This run did not load. ${failure.message}', _load)
          : _missing
          ? const OmniLoad.empty()
          : run == null || _loading && run.steps.isEmpty
          ? const OmniLoad.loading()
          : const OmniLoad.data(),
      // A failed run can be tried again from here.
      bottom: run != null && !run.ok
          ? OmniActionBar(
              primary: OmniButton(
                key: const ValueKey('run-again'),
                label: _rerunning ? 'Running…' : 'Run it again',
                onPressed: _rerunning ? null : _runAgain,
              ),
            )
          : null,
      notFound: const OmniEmptyState(
        key: ValueKey('run-missing'),
        icon: OmniIcons.info,
        title: 'This run is no longer in the log',
        message: 'The log keeps the newest runs only.',
      ),
      children: (context) => [
        if (run!.ok)
          OmniBanner.info(
            'Ran ${whenInline(run.startedAt, hour12: ref.watch(hour12Provider))}'
            '${run.duration == null ? '' : ' in ${tookText(run.duration!)}'}. '
            'Each step and what it did.',
          )
        else
          OmniBanner.error(
            'This run failed'
            '${failed == null ? '.' : ': ${asSentence(failed)}'} '
            'Steps after a failed one still run unless the automation stops at '
            'the first failure.',
          ),
        DryRunDiagram(run: run, id: widget.automationId),
        RunNodeRows(run: run, labels: _labels),
      ],
    );
  }
}

/// One line per run of a run result (`{runs: [trace]}`): how it ended, and
/// the first node that failed with its error.
String runSummary(Object? name, Json result) {
  final runs = (result['runs'] as List? ?? const []).cast<Map>();
  if (runs.isEmpty) return '$name: nothing ran';
  return [
    for (final r in runs)
      () {
        final failed = (r['nodes'] as List? ?? const [])
            .cast<Map>()
            .where((n) => n['error'] != null)
            .firstOrNull;
        if (r['outcome'] == 'completed') return '$name ran';
        final why = failed?['error'] ?? r['reason'];
        final step = failed?['label'];
        return [
          '$name did not finish',
          if (step != null) 'at $step',
          if (why != null) '- ${_failureText('$why')}',
        ].join(' ');
      }(),
  ].join('\n');
}
