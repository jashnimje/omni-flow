import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show ruleIdFor;

import '../../api/engine_calls.dart';
import '../../rules/rule_spec.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'dialogs.dart';
import 'review_page.dart';
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
  const RuleEditorPage({super.key, this.id, this.initial});

  /// The rule to reopen, or null for a new one.
  final String? id;

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
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    if (_draft case final draft?) dropUndoFor(draft);
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
  String? _missing(RuleSpec spec) {
    if (spec.when.isEmpty && !spec.onlyKeeps) {
      return spec.then.isEmpty
          ? 'Add a trigger and a step to save.'
          : 'Add a trigger to save.';
    }
    if (spec.then.isEmpty) return 'Add a step to save.';
    if (!stepsComplete(spec.then)) {
      return 'A group needs filling in: each If needs a check and a step, '
          'each branch a step and each keep a while.';
    }
    return null;
  }

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
          name: _name.isEmpty ? 'New rule' : _name,
          id: widget.id,
          dryRun: reply.value!.firstOrNull,
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
                '${existing.name}. Give this rule another name',
          ),
        ]),
      );
      return null;
    }
    final replace = await confirm(
      context,
      title: 'Replace ${existing.name}?',
      body:
          'There is a rule called ${existing.name} already. Saving this one '
          'replaces it. Rename this rule to keep both.',
      action: 'Replace',
      destructive: true,
    );
    return replace ? true : null;
  }

  Future<void> _remove() async {
    final ok = await confirm(
      context,
      title: 'Remove $_name?',
      body: 'It stops running and is deleted. This cannot be undone.',
      action: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final reply = await ref
        .read(engineApiProvider)
        .removeAutomation(widget.id!);
    if (!reply.ok || !mounted) return;
    _draft!.dirty = false;
    await ref.read(automationsProvider.notifier).refresh();
    showMessage('Removed $_name');
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
                'name': _name.isEmpty ? 'New rule copy' : '$_name copy',
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

  Future<void> _leave() async {
    final ok = await confirm(
      context,
      title: 'Discard changes?',
      body:
          'What you changed in ${_name.isEmpty ? 'this rule' : _name} is not '
          'saved and will be lost.',
      action: 'Discard',
      destructive: true,
    );
    if (!ok || !mounted) return;
    _draft?.dirty = false;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final things = ref.watch(ruleThingsProvider);
    final automations = ref.watch(automationsProvider).value ?? const [];
    final draft = _draft;
    if (draft != null) {
      draft
        ..words = RuleWords(things, {for (final a in automations) a.id: a.name})
        ..automations = [
          for (final a in automations)
            if (a.id != widget.id) a,
        ];
    }
    if (draft == null) {
      return OmniPage(
        title: widget.id ?? 'New rule',
        body: switch ((_loadFailure, _notARule)) {
          (final ApiFailure f, _) => OmniEmptyState(
            key: const ValueKey('rule-load-error'),
            icon: OmniIcons.error,
            title: 'Could not open this automation',
            message: f.message,
            action: OmniButton.ghost(label: 'Try again', onPressed: _load),
          ),
          (_, final String form) => OmniEmptyState(
            key: const ValueKey('rule-not-a-rule'),
            icon: OmniIcons.info,
            title: 'This is a $form, not a rule',
            message: 'Open it from the Automations list to see its runs.',
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      );
    }
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) {
        final spec = draft.spec;
        final missing = _missing(spec);
        final loose = draft.looseIssues;
        return PopScope(
          canPop: !draft.dirty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _leave();
          },
          child: OmniPage(
            title: _name.isEmpty ? 'New rule' : _name,
            actions: [
              PopupMenuButton<_Menu>(
                key: const ValueKey('rule-menu'),
                tooltip: 'More',
                icon: const Icon(OmniIcons.more, color: OmniColors.muted),
                onSelected: _onMenu,
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _Menu.rename,
                    child: Text('Rename'),
                  ),
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
                    const PopupMenuItem(
                      value: _Menu.remove,
                      child: Text(
                        'Remove',
                        style: TextStyle(color: OmniColors.bad),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            body: ListView(
              key: const ValueKey('rule-editor'),
              children: [
                if (!_approved)
                  OmniBanner.warning(
                    'Made by Claude. It runs only after you approve this '
                    'exact version.',
                    key: const ValueKey('rule-needs-approval'),
                    actionLabel: 'Review',
                    onAction: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => ReviewPage(id: widget.id!),
                      ),
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
                    padding: EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      'Stops at the first step that fails.',
                      style: OmniText.caption,
                    ),
                  ),
                const SizedBox(height: OmniSpace.lg),
              ],
            ),
            bottom: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (missing != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OmniSpace.sm),
                    child: Text(
                      missing,
                      key: const ValueKey('rule-missing'),
                      style: OmniText.caption,
                      textAlign: TextAlign.center,
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: OmniButton.ghost(
                        key: const ValueKey('rule-test'),
                        label: 'Test run',
                        icon: OmniIcons.test,
                        onPressed: _busy || missing != null ? null : _test,
                      ),
                    ),
                    const SizedBox(width: OmniSpace.sm),
                    Expanded(
                      child: OmniButton(
                        key: const ValueKey('rule-save'),
                        label: 'Save',
                        onPressed: _busy || missing != null ? null : _save,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
