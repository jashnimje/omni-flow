import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../api/engine_calls.dart' show ApiFailure, AutomationSummary;
import '../../rules/rule_spec.dart';
import '../../state/providers.dart' show showMessage;
import '../design/design.dart';
import 'pickers.dart';
import 'rule_words.dart';

/// The rule being edited, shared by the editor and the pages its groups
/// open, so an edit anywhere rebuilds every page and clears the errors the
/// last save or test run named (their rule paths no longer line up).
class RuleDraft extends ChangeNotifier {
  RuleDraft(this.spec, {required this.words, this.automations = const []});

  final RuleSpec spec;
  RuleWords words;

  /// What a run step can start: every other automation.
  List<AutomationSummary> automations;
  ApiFailure? failure;
  var dirty = false;

  void changed() {
    failure = null;
    dirty = true;
    notifyListeners();
  }

  void fail(ApiFailure f) {
    failure = f;
    notifyListeners();
  }

  /// The first issue the engine named at [path] or under it.
  String? errorAt(String path) => failure?.issuesAt(path).firstOrNull;

  /// The issue to show on a group's row at [path]: one at the group itself,
  /// or a pointer to the step inside that has one.
  String? groupErrorAt(String path) {
    final issues = failure?.issues ?? const [];
    final own = issues
        .where(
          (i) => const [
            '',
            '.if',
            '.together',
            '.then',
            '.else',
            '.keep',
            '.keep.while',
            '.waitFor',
            '.waitFor.on',
            '.waitFor.timeoutMs',
          ].any((s) => i.path == '$path$s'),
        )
        .firstOrNull;
    if (own != null) return own.message;
    return errorAt(path) == null ? null : 'Something inside needs fixing';
  }

  /// Issues no row shows: about the rule as a whole, or a list itself.
  List<String> get looseIssues => [
    for (final i
        in failure?.issues ?? const <({String path, String message})>[])
      if (!RegExp(r'^(when|onlyIf|then)\[').hasMatch(i.path))
        '${_listName(i.path)}${i.message}',
  ];

  static String _listName(String path) => switch (path) {
    'when' => 'When: ',
    'onlyIf' => 'Only if: ',
    'then' => 'Then: ',
    'name' => 'Name: ',
    _ => '',
  };
}

/// Semantics actions that move a row without dragging it.
Widget _movable({
  required Widget child,
  required int index,
  required int count,
  required void Function(int from, int to) onMove,
}) => Semantics(
  customSemanticsActions: {
    if (index > 0)
      const CustomSemanticsAction(label: 'Move up'): () =>
          onMove(index, index - 1),
    if (index < count - 1)
      const CustomSemanticsAction(label: 'Move down'): () =>
          onMove(index, index + 1),
  },
  child: child,
);

/// The rows of one list, draggable by their handles.
Widget _reorderable({
  required int count,
  required Widget Function(int i) row,
  required void Function(int from, int to) onMove,
}) => ReorderableListView(
  shrinkWrap: true,
  physics: const NeverScrollableScrollPhysics(),
  buildDefaultDragHandles: false,
  padding: EdgeInsets.zero,
  onReorderItem: onMove,
  children: [
    for (var i = 0; i < count; i++)
      KeyedSubtree(
        key: ValueKey(i),
        child: _movable(index: i, count: count, onMove: onMove, child: row(i)),
      ),
  ],
);

void _move<T>(List<T> list, int from, int to) {
  if (from == to || to < 0 || to >= list.length) return;
  list.insert(to, list.removeAt(from));
}

/// WHEN: any of these.
class TriggerBlock extends StatelessWidget {
  const TriggerBlock({super.key, required this.draft});

  final RuleDraft draft;

  @override
  Widget build(BuildContext context) {
    final when = draft.spec.when;
    return OmniRuleBlock(
      key: const ValueKey('block-when'),
      kind: SentenceKind.when,
      heading: 'When',
      caption: draft.spec.onlyKeeps && when.isEmpty
          ? 'not needed: each keep watches its own while'
          : 'any of these',
      addLabel: 'Add trigger',
      onAdd: () async {
        final t = await pickTrigger(context, draft.words);
        if (t == null) return;
        when.add(t);
        draft.changed();
      },
      children: [
        _reorderable(
          count: when.length,
          onMove: (from, to) {
            _move(when, from, to);
            draft.changed();
          },
          row: (i) {
            final t = when[i];
            return OmniStepRow(
              key: ValueKey('row-when[$i]'),
              reorderIndex: i,
              icon: draft.words.triggerIcon(t),
              text: draft.words.trigger(t),
              error: draft.errorAt('when[$i]'),
              onTap: t is ManualTrigger
                  ? null
                  : () async {
                      final edited = await editTrigger(context, draft.words, t);
                      if (edited == null) return;
                      when[i] = edited;
                      draft.changed();
                    },
              onRemove: () => _removeWithUndo(draft, when, i, 'Trigger'),
            );
          },
        ),
      ],
    );
  }
}

/// A list of conditions, all of which must hold: the rule's ONLY IF, an
/// If's check, or a keep's while.
class ConditionBlock extends StatelessWidget {
  const ConditionBlock({
    super.key,
    required this.draft,
    required this.conditions,
    required this.path,
    this.heading = 'Only if',
    this.caption = 'all of these',
  });

  final RuleDraft draft;
  final List<RuleCondition> conditions;

  /// The rule path of the list: `onlyIf`, `then[2].if`.
  final String path;
  final String heading;
  final String caption;

  @override
  Widget build(BuildContext context) => OmniRuleBlock(
    key: ValueKey('block-$path'),
    kind: SentenceKind.onlyIf,
    heading: heading,
    caption: caption,
    addLabel: 'Add condition',
    onAdd: () async {
      final c = await pickCondition(context, draft.words);
      if (c == null) return;
      conditions.add(c);
      draft.changed();
    },
    children: [
      _reorderable(
        count: conditions.length,
        onMove: (from, to) {
          _move(conditions, from, to);
          draft.changed();
        },
        row: (i) {
          final c = conditions[i];
          return OmniStepRow(
            key: ValueKey('row-$path[$i]'),
            reorderIndex: i,
            icon: draft.words.conditionIcon(c),
            text: draft.words.condition(c),
            error: draft.errorAt('$path[$i]'),
            onTap: c is UnknownCondition
                ? null
                : () async {
                    final edited = await editCondition(context, draft.words, c);
                    if (edited == null) return;
                    conditions[i] = edited;
                    draft.changed();
                  },
            onRemove: () => _removeWithUndo(draft, conditions, i, 'Condition'),
          );
        },
      ),
    ],
  );
}

/// A list of steps run in order: the rule's THEN or a list inside a group.
/// Branches and groups show as one row that opens their own page.
class StepBlock extends StatelessWidget {
  const StepBlock({
    super.key,
    required this.draft,
    required this.steps,
    required this.path,
    this.heading = 'Then',
    this.caption = 'in order',
    this.kind = SentenceKind.then,
    this.allowKeep = false,
    this.onRemoveBlock,
  });

  final RuleDraft draft;
  final List<RuleStep> steps;

  /// The rule path of the list: `then`, `then[3].else`.
  final String path;
  final String heading;
  final String caption;
  final SentenceKind kind;

  /// Only the rule's own THEN takes keep steps.
  final bool allowKeep;

  /// Shown as a remove link under the block (a together branch).
  final VoidCallback? onRemoveBlock;

  @override
  Widget build(BuildContext context) => OmniRuleBlock(
    key: ValueKey('block-$path'),
    kind: kind,
    heading: heading,
    caption: caption,
    addLabel: 'Add step',
    onAdd: () => _add(context),
    children: [
      _reorderable(
        count: steps.length,
        onMove: (from, to) {
          _move(steps, from, to);
          _keepsLast();
          draft.changed();
        },
        row: (i) => _row(context, i),
      ),
      if (onRemoveBlock != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: onRemoveBlock,
            style: TextButton.styleFrom(
              foregroundColor: OmniColors.bad,
              minimumSize: const Size(OmniSpace.target, OmniSpace.target),
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text('Remove ${heading.toLowerCase()}'),
          ),
        ),
    ],
  );

  /// Keep steps go last in a rule's THEN, so a move or an add never puts a
  /// plain step after one.
  void _keepsLast() {
    final keeps = steps.whereType<KeepStep>().toList();
    steps
      ..removeWhere((s) => s is KeepStep)
      ..addAll(keeps);
  }

  Future<void> _add(BuildContext context) async {
    var step = await pickStep(
      context,
      draft.words,
      automations: draft.automations,
      allowKeep: allowKeep,
    );
    if (step == null || !context.mounted) return;
    if (step is KeepStep) {
      final kept = await openKeepPage(context, draft, step, null);
      if (kept == null) return;
      step = kept;
    }
    steps.add(step);
    _keepsLast();
    draft.changed();
    if (!context.mounted) return;
    final i = steps.indexOf(step);
    if (isGroupStep(step)) {
      await openGroupPage(context, draft, step, '$path[$i]');
    }
  }

  Widget _row(BuildContext context, int i) {
    final s = steps[i];
    final words = draft.words;
    final at = '$path[$i]';
    final group = isGroupStep(s);
    return OmniStepRow(
      key: ValueKey('row-$at'),
      reorderIndex: i,
      icon: words.stepIcon(s),
      text: words.step(s),
      subtitle: switch (s) {
        WaitForStep() => 'at most ${durationText(s.timeoutMs)}',
        KeepStep() when s.hasRelease => 'then ${valueText(s.release)}',
        UnknownStep() => 'It can only be removed here',
        _ => null,
      },
      style: switch (s) {
        WaitStep() => StepRowStyle.wait,
        IfStep() ||
        TogetherStep() ||
        WaitForStep() ||
        TryStep() ||
        RepeatStep() => StepRowStyle.flow,
        _ => StepRowStyle.normal,
      },
      trailingText: switch (s) {
        IfStep() => '${s.then.length + s.otherwise.length}',
        TogetherStep() => '${s.branches.fold(0, (n, b) => n + b.length)}',
        WaitForStep() => '${s.onTimeout.length}',
        TryStep() => '${s.steps.length + s.otherwise.length}',
        RepeatStep() => '${s.steps.length}',
        _ => null,
      },
      error: group || s is KeepStep
          ? draft.groupErrorAt(at)
          : draft.errorAt(at),
      onTap: switch (s) {
        UnknownStep() => null,
        IfStep() ||
        TogetherStep() ||
        WaitForStep() ||
        TryStep() ||
        RepeatStep() => () => openGroupPage(context, draft, s, at),
        KeepStep() => () async {
          final kept = await openKeepPage(context, draft, s, at);
          if (kept == null) return;
          steps[i] = kept;
          draft.changed();
        },
        _ => () async {
          final edited = await editStep(
            context,
            words,
            s,
            automations: draft.automations,
          );
          if (edited == null) return;
          steps[i] = edited;
          draft.changed();
        },
      },
      onRemove: () => _removeWithUndo(draft, steps, i, 'Step'),
    );
  }
}

/// Removes item [i] of [list] and offers to put it back.
void _removeWithUndo<T>(RuleDraft draft, List<T> list, int i, String what) {
  final removed = list.removeAt(i);
  draft.changed();
  showMessage(
    '$what removed',
    action: 'Undo',
    onAction: () {
      list.insert(i.clamp(0, list.length), removed);
      draft.changed();
    },
  );
}

/// The steps that hold their own lists of steps, edited on a page.
bool isGroupStep(RuleStep s) =>
    s is IfStep ||
    s is TogetherStep ||
    s is WaitForStep ||
    s is TryStep ||
    s is RepeatStep;

Future<void> openGroupPage(
  BuildContext context,
  RuleDraft draft,
  RuleStep step,
  String path,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => GroupPage(draft: draft, step: step, path: path),
  ),
);

/// Edits [step] on its own page and returns it, or null when it was left
/// without a target or condition.
Future<KeepStep?> openKeepPage(
  BuildContext context,
  RuleDraft draft,
  KeepStep step,
  String? path,
) => Navigator.of(context).push<KeepStep>(
  MaterialPageRoute(
    builder: (_) => KeepPage(draft: draft, step: step, path: path),
  ),
);

/// The sub-list of a branch (if, otherwise), a together group or a wait
/// until, with the same blocks as the rule.
class GroupPage extends StatelessWidget {
  const GroupPage({
    super.key,
    required this.draft,
    required this.step,
    required this.path,
  });

  final RuleDraft draft;
  final RuleStep step;
  final String path;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    builder: (context, _) => OmniPage(
      title: switch (step) {
        IfStep() => 'If… otherwise',
        TogetherStep() => 'Do these together',
        TryStep() => 'Try, with a fallback',
        RepeatStep() => 'Repeat',
        _ => 'Wait until',
      },
      body: ListView(
        children: [
          ..._blocks(context),
          const SizedBox(height: OmniSpace.xl),
        ],
      ),
    ),
  );

  List<Widget> _blocks(BuildContext context) => switch (step) {
    IfStep(:final conditions, :final then, :final otherwise) => [
      ConditionBlock(
        draft: draft,
        conditions: conditions,
        path: '$path.if',
        heading: 'If',
        caption: 'all of these hold',
      ),
      StepBlock(
        draft: draft,
        steps: then,
        path: '$path.then',
        heading: 'Then',
        caption: 'in order',
      ),
      StepBlock(
        draft: draft,
        steps: otherwise,
        path: '$path.else',
        heading: 'Otherwise',
        caption: 'in order, or nothing',
        kind: SentenceKind.flow,
      ),
    ],
    TryStep(:final steps, :final otherwise) => [
      StepBlock(
        draft: draft,
        steps: steps,
        path: '$path.try',
        heading: 'Try',
        caption: 'in order',
      ),
      StepBlock(
        draft: draft,
        steps: otherwise,
        path: '$path.otherwise',
        heading: 'If one fails',
        caption: 'instead of the rest, or nothing to go on',
        kind: SentenceKind.flow,
      ),
    ],
    final RepeatStep repeat => [
      OmniListRow(
        key: const ValueKey('repeat-how'),
        icon: AutomationIcons.repeat,
        title: 'How often',
        subtitle: draft.words.repeatHow(repeat),
        chevron: true,
        onTap: () async {
          if (await repeatForm(context, repeat)) draft.changed();
        },
      ),
      ConditionBlock(
        draft: draft,
        conditions: repeat.until,
        path: '$path.repeat.until',
        heading: 'Stop when',
        caption: 'all of these hold, checked before each pass',
      ),
      StepBlock(
        draft: draft,
        steps: repeat.steps,
        path: '$path.repeat.do',
        heading: 'Each time',
        caption: 'in order',
      ),
    ],
    TogetherStep(:final branches) => [
      for (final (b, branch) in branches.indexed)
        StepBlock(
          key: ValueKey('branch-$b-${branches.length}'),
          draft: draft,
          steps: branch,
          path: '$path.together[$b]',
          heading: 'Branch ${b + 1}',
          caption: 'at the same time as the others',
          onRemoveBlock: branches.length > 2
              ? () {
                  branches.removeAt(b);
                  draft.changed();
                }
              : null,
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: OmniButton.ghost(
          key: const ValueKey('add-branch'),
          label: 'Add a branch',
          icon: OmniIcons.add,
          expand: false,
          onPressed: () {
            branches.add([]);
            draft.changed();
          },
        ),
      ),
    ],
    final WaitForStep wait => [
      OmniRuleBlock(
        kind: SentenceKind.when,
        heading: 'Wait until',
        caption: 'at most ${durationText(wait.timeoutMs)}',
        children: [
          OmniStepRow(
            key: ValueKey('row-$path.waitFor'),
            icon: draft.words.triggerIcon(wait.until),
            text: draft.words.trigger(wait.until),
            error: draft.errorAt('$path.waitFor'),
            onTap: () async {
              final edited = await waitUntilForm(context, draft.words, wait);
              if (edited == null) return;
              wait
                ..until = edited.until
                ..timeoutMs = edited.timeoutMs;
              draft.changed();
            },
          ),
        ],
      ),
      StepBlock(
        draft: draft,
        steps: wait.onTimeout,
        path: '$path.waitFor.onTimeout',
        heading: 'If the time runs out',
        caption: 'do these, then stop',
        kind: SentenceKind.flow,
      ),
    ],
    _ => const [],
  };
}

/// A keep step: what it holds, while what holds, and what happens after.
class KeepPage extends StatefulWidget {
  const KeepPage({
    super.key,
    required this.draft,
    required this.step,
    required this.path,
  });

  final RuleDraft draft;
  final KeepStep step;

  /// Null for a keep not in the rule yet.
  final String? path;

  @override
  State<KeepPage> createState() => _KeepPageState();
}

class _KeepPageState extends State<KeepPage> {
  late var _keep = widget.step;

  RuleDraft get _draft => widget.draft;

  bool get _ready => _keep.thing.isNotEmpty && _keep.whileConditions.isNotEmpty;

  Future<void> _pickTarget() async {
    final current = _draft.words.thing(_keep.thing);
    final thing = current ?? await pickKeepThing(context, _draft.words);
    if (thing == null || !mounted) return;
    final kept = await keepTargetForm(context, thing, _keep);
    if (kept != null) setState(() => _keep = kept);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _draft,
    builder: (context, _) {
      final path = widget.path;
      return OmniPage(
        title: 'Keep a value',
        body: ListView(
          children: [
            OmniRuleBlock(
              kind: SentenceKind.then,
              heading: 'Keep',
              caption: 'this value',
              addLabel: _keep.thing.isEmpty ? 'Choose what to keep' : null,
              onAdd: _pickTarget,
              children: [
                if (_keep.thing.isNotEmpty)
                  OmniStepRow(
                    key: const ValueKey('keep-target'),
                    icon: _draft.words.stepIcon(
                      DoStep(_keep.thing, _keep.capability),
                    ),
                    text: _draft.words
                        .keep(
                          KeepStep(
                            _keep.thing,
                            _keep.capability,
                            value: _keep.value,
                          ),
                        )
                        .replaceFirst(RegExp(r'…$'), ''),
                    error: path == null
                        ? null
                        : _draft.errorAt('$path.keep.target'),
                    onTap: _pickTarget,
                    onRemove: () => setState(
                      () => _keep = KeepStep(
                        '',
                        '',
                        whileConditions: _keep.whileConditions,
                      ),
                    ),
                  ),
              ],
            ),
            ConditionBlock(
              draft: _draft,
              conditions: _keep.whileConditions,
              path: '${path ?? 'keep'}.keep.while',
              heading: 'While',
              caption: 'all of these hold',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                _keep.value is bool
                    ? 'When they stop holding, it is turned '
                          '${_keep.value == true ? 'off' : 'on'} again, once. '
                          'Anything that changes it in between is put back.'
                    : 'Anything that changes it while they hold is put back. '
                          'When they stop, it is left as it is.',
                style: OmniText.caption,
              ),
            ),
            const SizedBox(height: OmniSpace.xl),
          ],
        ),
        bottom: OmniButton(
          key: const ValueKey('keep-done'),
          label: 'Done',
          onPressed: _ready ? () => Navigator.of(context).pop(_keep) : null,
        ),
      );
    },
  );
}
