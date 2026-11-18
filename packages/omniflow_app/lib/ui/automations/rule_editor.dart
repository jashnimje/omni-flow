import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show ruleIdFor;

import '../../api/engine_calls.dart';
import '../../api/rule_calls.dart';
import '../../rules/rule_spec.dart';
import '../../state/clock.dart' show hour12Provider;
import '../../state/providers.dart';
import '../design/automation_look.dart';
import '../design/design.dart';
import 'automation_insights.dart';
import 'automations_state.dart';
import 'card_look.dart';
import 'diagram/diagram.dart';
import 'dialogs.dart';
import 'review_page.dart';
import 'look_picker.dart';
import 'rule_blocks.dart';
import 'rule_words.dart';
import 'test_run.dart';

/// Opens the rule editor: a new rule, one started from [spec] (a filled
/// template), or the stored rule [id].
Future<void> openRuleEditor(BuildContext context, {String? id, Json? spec}) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RuleEditorPage(id: id, initial: spec),
      ),
    );

/// The spec a duplicate starts from: the same rule named "Evening copy",
/// without the original's id, so saving it makes a new rule from its own
/// name instead of colliding with the one it was copied from.
Json duplicateSpec(Json spec) {
  final name = '${spec['name'] ?? ''}'.trim();
  return {
    for (final e in spec.entries)
      if (e.key != 'id') e.key: e.value,
    'name': name.isEmpty ? 'New automation copy' : '$name copy',
  };
}

/// 2.2: WHEN any of these, ONLY IF all of these, THEN in order. The engine
/// compiles and checks the rule; the editor edits its JSON, shows the
/// engine's errors on the rows their rule paths name, dry-runs it and
/// saves it.
class RuleEditorPage extends ConsumerStatefulWidget {
  const RuleEditorPage({
    super.key,
    this.id,
    this.initial,
    this.name,
    this.startOff = false,
  });

  /// The rule to reopen, or null for a new one.
  final String? id;

  /// The name the list already has for [id], shown while the rule loads.
  final String? name;

  /// Where a new rule starts.
  final Json? initial;

  /// A copy saves switched off, so it never fires beside its original.
  final bool startOff;

  @override
  ConsumerState<RuleEditorPage> createState() => _RuleEditorPageState();
}

enum _Menu { rename, duplicate, history, remove }

class _RuleEditorPageState extends ConsumerState<RuleEditorPage> {
  RuleDraft? _draft;
  ApiFailure? _loadFailure;
  String? _notARule;
  var _busy = false;

  /// Whether the reopened rule is approved. An agent's rule waits, and
  /// saving it here keeps it waiting instead of approving it on the way.
  var _approved = true;

  @override
  void initState() {
    super.initState();
    if (widget.id == null) {
      _draft = RuleDraft(
        RuleSpec.fromJson(widget.initial ?? const {}),
        words: RuleWords(const []),
      );
      // A template's rule is new work the user has not kept yet.
      if (widget.initial != null) _draft!.dirty = true;
      _loadLabels();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    if (_draft case final draft?) {
      dropUndoFor(draft);
      dropDiagramUndoFor(draft);
    }
    _draft?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadFailure = null);
    final reply = await ref.read(engineApiProvider).automation(widget.id!);
    if (!mounted) return;
    final automation = reply.value;
    if (automation == null) {
      setState(() => _loadFailure = reply.failure);
      return;
    }
    final form = EngineCalls.formOf(automation);
    if (form != null && form != 'rule') {
      setState(() => _notARule = form);
      return;
    }
    setState(() {
      _approved = automation['approved'] != false;
      _draft = RuleDraft(
        RuleSpec.fromJson(
          Map<String, Object?>.from(automation['spec'] as Map? ?? const {}),
        ),
        words: RuleWords(const []),
        id: widget.id,
      );
    });
    _loadLabels();
  }

  /// Asks the engine for the labels of the tokens the rule's fields use,
  /// so its rows read "Web reply · body" instead of the template.
  Future<void> _loadLabels() async {
    final draft = _draft;
    if (draft == null) return;
    final rule = draft.spec.toJson();
    if (!jsonEncode(rule).contains('{{')) return;
    final tokens = await RuleCalls.fetch(
      ref.read(engineClientProvider),
      rule,
      'then[${draft.spec.then.length}]',
    );
    if (!mounted || tokens.isEmpty) return;
    setState(() {
      for (final t in tokens) {
        draft.tokenLabels[t.token] = t.label;
      }
    });
  }

  String get _name => _draft?.spec.name.trim() ?? '';

  Future<void> _rename() async {
    final draft = _draft;
    final name = await askName(
      context,
      title: 'Name this automation',
      // A new name starts from what the rule does, never a template's.
      initial: _name.isEmpty && draft != null
          ? draft.words.suggestedName(
              draft.spec,
              hour12: ref.read(hour12Provider),
            )
          : _name,
    );
    if (name == null || _draft == null) return;
    _draft!.spec.name = name;
    _draft!.changed();
  }

  /// What still keeps Save off, in the WHEN and THEN words of the blocks,
  /// or null when it can save.
  String? _missing(RuleSpec spec) => spec.missing;

  Future<void> _test() async {
    final draft = _draft!;
    setState(() => _busy = true);
    final reply = await ref
        .read(engineApiProvider)
        .dryRun(rule: draft.spec.toJson(), id: widget.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (reply.failure case final f?) {
      draft.fail(f);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TestRunPage(
          name: _name.isEmpty ? 'New automation' : _name,
          id: widget.id,
          dryRun: reply.value!.firstOrNull,
          rule: draft.spec.toJson(),
          unsaved: _draft?.dirty ?? false,
          kind: TestRunKind.test,
        ),
      ),
    );
  }

  Future<void> _save() async {
    final draft = _draft!;
    if (_name.isEmpty) {
      await _rename();
      if (_name.isEmpty || !mounted) return;
    }
    final replace = widget.id != null ? true : await _replaceOk(_name);
    if (replace == null || !mounted) return;
    setState(() => _busy = true);
    final reply = await ref
        .read(engineApiProvider)
        .saveRule(
          draft.spec.toJson(),
          id: widget.id,
          trusted: widget.id == null || _approved,
          replace: replace,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (reply.failure case final f?) {
      draft.fail(f);
      return;
    }
    draft.dirty = false;
    await ref.read(automationsProvider.notifier).refresh();
    if (!mounted) return;
    final saved = reply.value!;
    final navigator = Navigator.of(context);
    if (saved['approved'] == false) {
      showMessage('Saved $_name. It runs once you approve it');
      await navigator.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ReviewPage(id: '${saved['id'] ?? widget.id}'),
        ),
      );
      return;
    }
    if (widget.startOff && widget.id == null && saved['id'] is String) {
      await ref
          .read(engineApiProvider)
          .enableAutomation(saved['id'] as String, false);
      await ref.read(automationsProvider.notifier).refresh();
      showMessage('Saved $_name. It stays off until you turn it on');
    } else {
      showMessage('Saved $_name');
    }
    navigator.pop();
  }

  /// A new rule takes the id its name gives, so a name another automation
  /// has is asked about first: true to replace that rule, false when the
  /// id is free, and null to go back and rename.
  Future<bool?> _replaceOk(String name) async {
    final id = ruleIdFor(name);
    final existing = (ref.read(automationsProvider).value ?? const [])
        .where((a) => a.id == id)
        .firstOrNull;
    if (existing == null) return false;
    if (existing.source != 'rule') {
      _draft!.fail(
        ApiFailure('exists', 'name taken', [
          (
            path: 'name',
            message:
                'there is a ${existing.source ?? 'automation'} called '
                '${existing.name}. Give this automation another name',
          ),
        ]),
      );
      return null;
    }
    final replace = await confirm(
      context,
      title: 'Replace ${existing.name}?',
      body:
          'There is an automation called ${existing.name} already. Saving this one '
          'replaces it. Rename this one to keep both.',
      action: 'Replace',
      destructive: true,
    );
    return replace ? true : null;
  }

  Future<void> _remove() async {
    final ok = await confirm(
      context,
      title: 'Remove $_name?',
      body: 'It stops running. You can put it back from Recently removed.',
      action: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final api = ref.read(engineApiProvider);
    final client = ref.read(engineClientProvider);
    final automations = ref.read(automationsProvider.notifier);
    final id = widget.id!;
    final name = _name;
    // The saved record, so Undo puts back what was there, as the list does.
    final saved = await api.automation(id);
    final record = saved.value == null
        ? null
        : EngineCalls.automationOf(saved.value!);
    final reply = await api.removeAutomation(id);
    if (!reply.ok || !mounted) return;
    _draft!.dirty = false;
    await automations.refresh();
    showMessage(
      'Removed $name',
      action: record == null ? null : 'Undo',
      onAction: record == null
          ? null
          : () async {
              if (await RuleCalls.restore(client, record)) {
                if (record['enabled'] == false) {
                  await api.enableAutomation(id, false);
                }
              } else {
                showMessage('$name could not be put back');
              }
              await automations.refresh();
            },
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// The kinds "Add a step" offers. A WHEN or THEN still empty shows its
  /// own target in its block, which is the one way to fill it, so it is
  /// left out here until that block has something.
  static List<SentenceKind> _addable(RuleSpec spec) => [
    if (spec.when.isNotEmpty) SentenceKind.when,
    SentenceKind.onlyIf,
    if (spec.then.isNotEmpty) SentenceKind.then,
  ];

  /// What the end block says for [kinds]: "Add a step" once it can add
  /// one, else the checks it offers.
  static String _addLabel(List<SentenceKind> kinds) =>
      kinds.contains(SentenceKind.then)
      ? 'Add a step'
      : kinds.contains(SentenceKind.when)
      ? 'Add another WHEN or an ONLY IF'
      : 'Add an ONLY IF';

  /// The one "Add a step": asks which kind, then opens that kind's picker.
  /// With one kind to offer it goes straight to that picker.
  Future<void> _addAStep(RuleDraft draft) async {
    final kinds = _addable(draft.spec);
    final kind = kinds.length == 1
        ? kinds.single
        : await showPickerSheet<SentenceKind>(
            context,
            title: _addLabel(kinds),
            sections: [
              PickerSection([
                if (kinds.contains(SentenceKind.when))
                  PickerItem(
                    key: const ValueKey('add-part-when'),
                    value: SentenceKind.when,
                    title: 'When',
                    subtitle: 'Something that starts it',
                    icon: SentenceColors.iconOf(SentenceKind.when),
                  ),
                PickerItem(
                  key: const ValueKey('add-part-onlyIf'),
                  value: SentenceKind.onlyIf,
                  title: 'Only if',
                  subtitle: 'A check that has to be true',
                  icon: SentenceColors.iconOf(SentenceKind.onlyIf),
                ),
                if (kinds.contains(SentenceKind.then))
                  PickerItem(
                    key: const ValueKey('add-part-then'),
                    value: SentenceKind.then,
                    title: 'Then',
                    subtitle: 'Something it does',
                    icon: SentenceColors.iconOf(SentenceKind.then),
                  ),
              ]),
            ],
          );
    if (kind == null || !mounted) return;
    final spec = draft.spec;
    switch (kind) {
      case SentenceKind.when:
        await addTrigger(context, draft);
      case SentenceKind.onlyIf:
        await addCondition(context, draft, spec.onlyIf);
      default:
        await StepBlock(
          draft: draft,
          steps: spec.then,
          path: 'then',
          allowKeep: true,
        ).add(context);
    }
  }

  Future<void> _onMenu(_Menu choice) async {
    final draft = _draft!;
    switch (choice) {
      case _Menu.rename:
        await _rename();
      case _Menu.duplicate:
        // A copy of what is on screen, as a new rule that is not saved yet.
        // It takes this page's place unless this page has unsaved edits,
        // so saving the copy goes back to the list.
        final copy = MaterialPageRoute<void>(
          builder: (_) => RuleEditorPage(
            initial: duplicateSpec(draft.spec.toJson()),
            startOff: true,
          ),
        );
        final navigator = Navigator.of(context);
        await (draft.dirty
            ? navigator.push<void>(copy)
            : navigator.pushReplacement<void, void>(copy));
      case _Menu.history:
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                TestRunPage(name: _name, id: widget.id, kind: TestRunKind.runs),
          ),
        );
      case _Menu.remove:
        await _remove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final things = ref.watch(ruleThingsProvider);
    final automations = ref.watch(automationsProvider).value ?? const [];
    final view = ref.watch(ruleViewProvider);
    final draft = _draft;
    if (draft != null) {
      draft
        ..words = RuleWords(
          things,
          {for (final a in automations) a.id: a.name},
          draft.tokenLabels,
          draft.served,
        )
        ..automations = [
          for (final a in automations)
            if (a.id != widget.id) a,
        ]
        ..wordsFrom = ref.read(engineClientProvider);
      unawaited(draft.fetchWords());
    }
    if (draft == null) {
      return EditorPage(
        // The list's name for it, never its id, until the rule is read.
        title: widget.name ?? 'Automation',
        onPrimary: null,
        state: switch ((_loadFailure, _notARule)) {
          (final ApiFailure f, _) => OmniLoad.error(f.message, _load),
          (_, String _) => const OmniLoad.empty(),
          _ => const OmniLoad.loading(),
        },
        empty: OmniEmptyState(
          key: const ValueKey('rule-not-a-rule'),
          icon: OmniIcons.info,
          title: 'This is a ${_notARule ?? 'link'}, not a rule',
          message: 'Open it from the Automations list to see its runs.',
        ),
        children: (_) => const [],
      );
    }
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) {
        final spec = draft.spec;
        final missing = _missing(spec);
        final loose = draft.looseIssues;
        final ready = !_busy && missing == null;
        return EditorPage(
          title: _name.isEmpty ? 'New automation' : _name,
          dirty: draft.dirty,
          discardWhat: widget.id == null
              ? 'this new automation'
              : _name.isEmpty
              ? 'this automation'
              : _name,
          discardNew: widget.id == null,
          onDiscard: () => draft.dirty = false,
          actions: [
            PopupMenuButton<_Menu>(
              key: const ValueKey('rule-menu'),
              tooltip: 'More',
              icon: Icon(OmniIcons.more, color: OmniPalette.of(context).muted),
              onSelected: _onMenu,
              itemBuilder: (_) => [
                const PopupMenuItem(value: _Menu.rename, child: Text('Rename')),
                if (widget.id != null) ...[
                  const PopupMenuItem(
                    key: ValueKey('rule-duplicate'),
                    value: _Menu.duplicate,
                    child: Text('Duplicate'),
                  ),
                  const PopupMenuItem(
                    value: _Menu.history,
                    child: Text('Runs'),
                  ),
                  PopupMenuItem(
                    value: _Menu.remove,
                    child: Text(
                      'Remove',
                      style: OmniText.body.copyWith(
                        color: OmniPalette.of(context).bad,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          // Both views edit [draft], so a change in one shows in the other.
          // The blocks reach the diagram from Options, so the switch shows
          // only on the diagram, to come back.
          views: view != RuleView.diagram
              ? null
              : OmniSegmented<RuleView>(
                  key: const ValueKey('rule-view'),
                  segments: const [
                    OmniSegment(RuleView.sentence, 'Sentence'),
                    OmniSegment(RuleView.diagram, 'Diagram'),
                  ],
                  selected: view,
                  onChanged: (v) => ref.read(ruleViewProvider.notifier).set(v),
                ),
          banners: [
            if (!_approved)
              OmniBanner.warning(
                'Made by an agent. It runs only after you approve this '
                'exact version.',
                key: const ValueKey('rule-needs-approval'),
                actionLabel: 'Review',
                onAction: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(builder: (_) => ReviewPage(id: widget.id!)),
                ),
              ),
            if (draft.failure != null)
              OmniBanner.error(
                [
                  if (loose.isNotEmpty) ...loose,
                  if (loose.length < draft.failure!.issues.length)
                    'Fix the rows marked in red.',
                  if (draft.failure!.issues.isEmpty) draft.failure!.message,
                ].join('\n'),
                key: const ValueKey('rule-errors'),
              ),
          ],
          secondaryLabel: 'Test run',
          secondaryKey: const ValueKey('rule-test'),
          onSecondary: ready ? _test : null,
          primaryKey: const ValueKey('rule-save'),
          onPrimary: ready ? _save : null,
          missing: missing,
          canvas: view == RuleView.diagram
              ? (context) => KeyedSubtree(
                  key: const ValueKey('rule-diagram'),
                  child: DiagramEditor(draft: draft, id: widget.id),
                )
              : null,
          children: view == RuleView.diagram
              ? null
              : (context) => [
                  KeyedSubtree(
                    key: const ValueKey('rule-editor'),
                    child: _Header(draft: draft, onRename: _rename),
                  ),
                  TriggerBlock(draft: draft, addable: false),
                  // An empty Only if is not shown. Add a step offers it.
                  if (spec.onlyIf.isNotEmpty ||
                      draft.errorAt('onlyIf') != null) ...[
                    const _Joint(),
                    ConditionBlock(
                      draft: draft,
                      conditions: spec.onlyIf,
                      path: 'onlyIf',
                      addable: false,
                    ),
                  ],
                  const _Joint(),
                  StepBlock(
                    draft: draft,
                    steps: spec.then,
                    path: 'then',
                    allowKeep: true,
                    addable: false,
                  ),
                  if (spec.stopOnError)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OmniSpace.xs,
                      ),
                      child: Text(
                        'Stops at the first step that fails.',
                        style: OmniText.captionOf(context),
                      ),
                    ),
                  _AddAStep(
                    label: _addLabel(_addable(spec)),
                    onTap: () => _addAStep(draft),
                  ),
                  const SizedBox(height: OmniSpace.md),
                  _Options(
                    draft: draft,
                    onDiagram: () => ref
                        .read(ruleViewProvider.notifier)
                        .set(RuleView.diagram),
                  ),
                  // A saved rule: its last run, clashes, why it did not
                  // run, and its versions.
                  if (widget.id != null)
                    OmniDisclosure(
                      key: const ValueKey('rule-activity'),
                      icon: OmniIcons.time,
                      title: 'Activity',
                      summary: 'Last runs and why one was skipped',
                      storageId: 'rule-activity',
                      children: [
                        LastRunSection(id: widget.id!),
                        AutomationInsights(id: widget.id!, onRestored: _load),
                      ],
                    ),
                ],
        );
      },
    );
  }
}

/// The top of the editor: the automation's icon on its colour and how
/// to change it. A tap renames it.
class _Header extends StatelessWidget {
  const _Header({required this.draft, required this.onRename});

  final RuleDraft draft;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final spec = draft.spec;
    final name = spec.name.trim();
    final color = automationCardColor(spec.color);
    // "Tap a word" means nothing until a block has words in it.
    final hasWords =
        spec.when.isNotEmpty || spec.onlyIf.isNotEmpty || spec.then.isNotEmpty;
    final nameHint = name.isEmpty
        ? 'Tap here to give it a name'
        : 'Tap here to rename it';
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpace.lg),
      child: Semantics(
        button: true,
        label: name.isEmpty ? 'Name this automation' : 'Rename $name',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('rule-name'),
          borderRadius: BorderRadius.circular(OmniRadii.card),
          onTap: onRename,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OmniSpace.targetLarge),
            child: Row(
              children: [
                Container(
                  width: OmniSpace.targetLarge,
                  height: OmniSpace.targetLarge,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(OmniRadii.card / 1.5),
                  ),
                  child: Icon(
                    automationIcon(spec.icon),
                    color: OmniCardColors.onCard,
                    fill: 1,
                    size: 30,
                  ),
                ),
                const SizedBox(width: OmniSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The name is the page's title, so it is not said
                      // twice here.
                      if (hasWords) ...[
                        const Text(
                          'Tap a word to change it',
                          key: ValueKey('rule-words-hint'),
                          style: OmniText.bodyStrong,
                        ),
                        Text(nameHint, style: OmniText.captionOf(context)),
                      ] else
                        Text(nameHint, style: OmniText.bodyStrong),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The thin line joining two blocks, so they read as one sequence.
class _Joint extends StatelessWidget {
  const _Joint();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsets.only(left: OmniSpace.xl + 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 2,
          height: OmniSpace.sm,
          margin: const EdgeInsets.only(bottom: OmniSpace.sm),
          color: OmniPalette.of(context).line,
        ),
      ),
    ),
  );
}

/// The dashed "+ Add a step" block at the end of the steps, worded for
/// what it can add while a block is still empty.
class _AddAStep extends StatelessWidget {
  const _AddAStep({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OmniRadii.step),
          side: BorderSide(color: palette.line, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('rule-add-a-step'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OmniSpace.targetLarge),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(OmniIcons.add, color: palette.accent),
                const SizedBox(width: OmniSpace.sm),
                Flexible(
                  child: Text(
                    label,
                    key: const ValueKey('rule-add-a-step-label'),
                    style: OmniText.button.copyWith(color: palette.accent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Options, collapsed: how the automation runs (ask first, notify, stop
/// at the first failure), how it looks, and the diagram. Each is a field
/// of the rule spec the engine acts on.
class _Options extends StatelessWidget {
  const _Options({required this.draft, required this.onDiagram});

  final RuleDraft draft;
  final VoidCallback onDiagram;

  /// What is set, so most people never need to open it.
  static String _summary(RuleSpec spec) {
    final set = [
      if (spec.askFirst) 'Asks first',
      if (spec.notifyOnRun) 'Notifies',
      if (spec.stopOnError) 'Stops on a failure',
    ];
    return set.isEmpty ? 'Ask first, notify, colour and icon' : set.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final spec = draft.spec;
    final color = automationCardColor(spec.color);
    final keeps = spec.then.any((s) => s is KeepStep);
    final askError = draft.errorAt('askFirst');
    return OmniDisclosure(
      key: const ValueKey('rule-options'),
      icon: OmniIcons.edit,
      title: 'Options',
      summary: askError ?? _summary(spec),
      storageId: 'rule-options',
      // An error on Ask first opens it, so the reason is in view.
      initiallyOpen: askError != null,
      children: [
        OmniListRow(
          key: const ValueKey('rule-ask-first'),
          icon: AutomationLook.askIcon,
          title: 'Ask before running',
          subtitle:
              askError ??
              (keeps && !spec.askFirst
                  ? 'Not with a keep step: a keep holds its value on its own, '
                        'so there is no run to ask about.'
                  : 'When its WHEN happens, a notification asks first. '
                        'Running it yourself never asks.'),
          subtitleLines: 3,
          onTap: keeps && !spec.askFirst
              ? null
              : () {
                  spec.askFirst = !spec.askFirst;
                  draft.changed();
                },
          trailing: Switch(
            value: spec.askFirst,
            // One set before a keep was added can still be turned off.
            onChanged: keeps && !spec.askFirst
                ? null
                : (v) {
                    spec.askFirst = v;
                    draft.changed();
                  },
          ),
        ),
        OmniListRow(
          key: const ValueKey('rule-notify-on-run'),
          icon: OmniIcons.notifications,
          title: 'Notify when it runs',
          subtitle: 'A notification each time it finishes.',
          onTap: () {
            spec.notifyOnRun = !spec.notifyOnRun;
            draft.changed();
          },
          trailing: Switch(
            value: spec.notifyOnRun,
            onChanged: (v) {
              spec.notifyOnRun = v;
              draft.changed();
            },
          ),
        ),
        OmniListRow(
          key: const ValueKey('rule-look'),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(OmniRadii.iconBox),
            ),
            child: Icon(
              automationIcon(spec.icon),
              color: OmniCardColors.onCard,
              size: 22,
            ),
          ),
          title: 'Colour and icon',
          subtitle: lookWords((color: spec.color, icon: spec.icon)),
          chevron: true,
          onTap: () async {
            final look = await pickLook(context, (
              color: spec.color,
              icon: spec.icon,
            ));
            if (look == null) return;
            spec
              ..color = look.color
              ..icon = look.icon;
            draft.changed();
          },
        ),
        OmniListRow(
          key: const ValueKey('rule-stop-on-error'),
          icon: OmniIcons.error,
          title: 'Stop at the first failed step',
          subtitle: 'Otherwise every step runs, and failures are noted.',
          subtitleLines: 2,
          onTap: () {
            spec.stopOnError = !spec.stopOnError;
            draft.changed();
          },
          trailing: Switch(
            value: spec.stopOnError,
            onChanged: (v) {
              spec.stopOnError = v;
              draft.changed();
            },
          ),
        ),
        OmniListRow(
          key: const ValueKey('rule-diagram-view'),
          icon: OmniIcons.branch,
          title: 'See it as a diagram',
          subtitle: 'Every step as a box, joined in order.',
          chevron: true,
          divider: false,
          onTap: onDiagram,
        ),
      ],
    );
  }
}
