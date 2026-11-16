import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show ruleIdFor;

import '../../api/engine_calls.dart';
import '../../api/rule_calls.dart';
import '../../rules/rule_spec.dart';
import '../../state/providers.dart';
import '../design/automation_look.dart';
import '../design/design.dart';
import 'automation_insights.dart';
import 'automations_state.dart';
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

/// 2.2: WHEN any of these, ONLY IF all of these, THEN in order. The engine
/// compiles and checks the rule; the editor edits its JSON, shows the
/// engine's errors on the rows their rule paths name, dry-runs it and
/// saves it.
class RuleEditorPage extends ConsumerStatefulWidget {
  const RuleEditorPage({super.key, this.id, this.initial, this.name});

  /// The rule to reopen, or null for a new one.
  final String? id;

  /// The name the list already has for [id], shown while the rule loads.
  final String? name;

  /// Where a new rule starts.
  final Json? initial;

  @override
  ConsumerState<RuleEditorPage> createState() => _RuleEditorPageState();
}

enum _Menu { rename, stopOnError, duplicate, history, remove }

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
    final name = await askName(
      context,
      title: 'Name this automation',
      initial: _name,
    );
    if (name == null || _draft == null) return;
    _draft!.spec.name = name;
    _draft!.changed();
  }

  /// What still keeps Save off, in plain words, or null when it can save.
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
    showMessage('Saved $_name');
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
      body:
          'It stops running and is removed. You can undo it for a moment '
          'after.',
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

  Future<void> _onMenu(_Menu choice) async {
    final draft = _draft!;
    switch (choice) {
      case _Menu.rename:
        await _rename();
      case _Menu.stopOnError:
        draft.spec.stopOnError = !draft.spec.stopOnError;
        draft.changed();
      case _Menu.duplicate:
        // A copy of what is on screen, as a new rule that is not saved yet.
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => RuleEditorPage(
              initial: {
                ...draft.spec.toJson(),
                'name': _name.isEmpty ? 'New automation copy' : '$_name copy',
              },
            ),
          ),
        );
      case _Menu.history:
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => TestRunPage(name: _name, id: widget.id),
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
          onDiscard: () => draft.dirty = false,
          actions: [
            PopupMenuButton<_Menu>(
              key: const ValueKey('rule-menu'),
              tooltip: 'More',
              icon: const Icon(OmniIcons.more, color: OmniColors.muted),
              onSelected: _onMenu,
              itemBuilder: (_) => [
                const PopupMenuItem(value: _Menu.rename, child: Text('Rename')),
                CheckedPopupMenuItem(
                  value: _Menu.stopOnError,
                  checked: spec.stopOnError,
                  child: const Text('Stop at the first failed step'),
                ),
                if (widget.id != null) ...[
                  const PopupMenuItem(
                    key: ValueKey('rule-duplicate'),
                    value: _Menu.duplicate,
                    child: Text('Duplicate'),
                  ),
                  const PopupMenuItem(
                    value: _Menu.history,
                    child: Text('Runs and test'),
                  ),
                  PopupMenuItem(
                    value: _Menu.remove,
                    child: Text(
                      'Remove',
                      style: OmniText.body.copyWith(color: OmniColors.bad),
                    ),
                  ),
                ],
              ],
            ),
          ],
          // Both views edit [draft], so a change in one shows in the other.
          views: OmniSegmented<RuleView>(
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
                    child: _LookAndAsk(draft: draft),
                  ),
                  TriggerBlock(draft: draft),
                  ConditionBlock(
                    draft: draft,
                    conditions: spec.onlyIf,
                    path: 'onlyIf',
                  ),
                  StepBlock(
                    draft: draft,
                    steps: spec.then,
                    path: 'then',
                    allowKeep: true,
                  ),
                  if (spec.stopOnError)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: OmniSpace.xs),
                      child: Text(
                        'Stops at the first step that fails.',
                        style: OmniText.caption,
                      ),
                    ),
                  // A saved rule: its last run, clashes, why it did not
                  // run, and History.
                  if (widget.id != null) LastRunSection(id: widget.id!),
                  if (widget.id != null)
                    AutomationInsights(id: widget.id!, onRestored: _load),
                ],
        );
      },
    );
  }
}

/// The top of the editor: how the automation looks (its colour and icon)
/// and how it runs (ask before running, notify when it runs). Each is a
/// field of the rule spec the engine acts on.
class _LookAndAsk extends StatelessWidget {
  const _LookAndAsk({required this.draft});

  final RuleDraft draft;

  @override
  Widget build(BuildContext context) {
    final spec = draft.spec;
    final color = automationColor(spec.color);
    final keeps = spec.then.any((s) => s is KeepStep);
    return Column(
      key: const ValueKey('rule-look-and-ask'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniListRow(
          key: const ValueKey('rule-look'),
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(OmniRadii.iconBox),
            ),
            child: Icon(automationIcon(spec.icon), color: color, size: 22),
          ),
          title: 'Colour and icon',
          subtitle:
              '${colorNames[spec.color] ?? 'Teal'}, '
              '${spec.icon ?? automationIconNames.first}',
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
          key: const ValueKey('rule-ask-first'),
          icon: AutomationLook.askIcon,
          title: 'Ask before running',
          subtitle:
              draft.errorAt('askFirst') ??
              (keeps && !spec.askFirst
                  ? 'Not with a keep step: a keep holds its value on its own, '
                        'so there is no run to ask about.'
                  : 'When a trigger starts it, a notification asks first. '
                        'Running it yourself never asks.'),
          subtitleLines: 3,
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
          trailing: Switch(
            value: spec.notifyOnRun,
            onChanged: (v) {
              spec.notifyOnRun = v;
              draft.changed();
            },
          ),
        ),
      ],
    );
  }
}
