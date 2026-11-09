import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show ruleIdFor;

import '../api/engine_calls.dart';
import '../rules/rule_spec.dart';
import '../rules/things.dart';
import '../state/providers.dart';
import 'dashboard.dart' show ParamsForm;
import 'device_sheets.dart' show confirm;
import 'flows_screen.dart' show ApprovalPage;

Future<void> openRuleBuilder(BuildContext context, {String? id}) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => RuleBuilderPage(id: id)));

/// Builds a rule: WHEN any trigger, ONLY IF every condition, THEN the steps
/// in order. The engine compiles and checks it. The builder only edits the
/// rule's JSON, tests it with a dry run and saves it.
class RuleBuilderPage extends ConsumerStatefulWidget {
  const RuleBuilderPage({super.key, this.id});

  /// The automation to reopen, or null for a new rule.
  final String? id;

  @override
  ConsumerState<RuleBuilderPage> createState() => _RuleBuilderPageState();
}

class _RuleBuilderPageState extends ConsumerState<RuleBuilderPage> {
  RuleSpec? _spec;
  String? _loadError;
  final _name = TextEditingController();
  var _busy = false;

  /// Whether the reopened rule was approved. One an agent wrote waits for
  /// approval, and saving it from here must not approve it on the way.
  var _approved = true;
  var _highRisk = false;

  @override
  void initState() {
    super.initState();
    if (widget.id == null) {
      _spec = RuleSpec();
    } else {
      _load(widget.id!);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load(String id) async {
    final result = await ref.read(engineClientProvider).call(
      EngineCalls.automationGet,
      {'id': id},
    );
    if (!mounted) return;
    if (result['ok'] != true) {
      setState(() => _loadError = errorMessage(result));
      return;
    }
    final automation = EngineCalls.automationOf(result);
    final form = EngineCalls.formOf(automation);
    if (form != null && form != 'rule') {
      setState(() => _loadError = 'This automation is a $form, not a rule.');
      return;
    }
    final spec = RuleSpec.fromJson(
      Map<String, Object?>.from(automation['spec'] as Map? ?? const {}),
    );
    _name.text = spec.name;
    setState(() {
      _spec = spec;
      _approved = automation['approved'] == true;
      _highRisk = automation['highRisk'] == true;
    });
  }

  Json get _specJson => (_spec!..name = _name.text.trim()).toJson();

  void _changed() => setState(() {});

  Future<void> _testRun() async {
    setState(() => _busy = true);
    final result = await ref
        .read(engineClientProvider)
        .call(
          EngineCalls.automationDryRun,
          EngineCalls.dryRunRuleArgs(_specJson, id: widget.id),
        );
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Test run'),
        content: SingleChildScrollView(
          child: Text(
            dryRunText(result),
            key: const ValueKey('dry-run-result'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// A rule the user wrote here is trusted. An unapproved one an agent
  /// wrote is saved untrusted, so it keeps waiting, and the review page
  /// then shows exactly what the saved revision does before approving it.
  Future<void> _save() async {
    final flows = ref.read(flowsProvider.notifier);
    final navigator = Navigator.of(context);
    final name = _name.text.trim();
    final replace = widget.id != null ? true : await _replaceOk(name);
    if (replace == null || !mounted) return;
    setState(() => _busy = true);
    final result = await callEngine(
      ref,
      EngineCalls.automationSave,
      EngineCalls.saveRuleArgs(
        _specJson,
        id: widget.id,
        trusted: widget.id == null || _approved,
        replace: replace,
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result['ok'] != true) return;
    await flows.refresh();
    if (!mounted) return;
    if (result['approved'] == false) {
      showMessage('Saved $name. It runs once you approve it');
      await navigator.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              ApprovalPage(flowId: '${result['id'] ?? widget.id}', name: name),
        ),
      );
      return;
    }
    showMessage('Saved $name');
    navigator.pop();
  }

  /// A new rule takes the id its name gives, so a name another rule has is
  /// asked about first: true to replace that rule, false when no rule has
  /// it, and null when the user keeps the other rule.
  Future<bool?> _replaceOk(String name) async {
    final id = ruleIdFor(name);
    final existing = (ref.read(flowsProvider).value ?? const <Json>[])
        .where((f) => f['id'] == id && EngineCalls.formOf(f) == 'rule')
        .firstOrNull;
    if (existing == null) return false;
    final replace = await confirm(
      context,
      title: 'Replace ${existing['name']}?',
      body:
          'There is a rule called ${existing['name']} already. Saving '
          'this one replaces it. Give this rule another name to keep both.',
      action: 'Replace',
    );
    return replace ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    final things = thingsOf(ref.watch(devicesProvider).value ?? const []);
    final automations = [
      for (final f in ref.watch(flowsProvider).value ?? const <Json>[])
        if (f['id'] != widget.id) f,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(widget.id == null ? 'New rule' : 'Edit rule')),
      body: switch ((spec, _loadError)) {
        (_, final String error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error, key: const ValueKey('rule-load-error')),
          ),
        ),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final RuleSpec spec, _) => _RuleScope(
          things: things,
          automations: automations,
          onChanged: _changed,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              TextField(
                key: const ValueKey('rule-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              if (!_approved)
                Card(
                  key: const ValueKey('rule-needs-approval'),
                  child: ListTile(
                    leading: Icon(
                      _highRisk ? Icons.warning_amber : Icons.gpp_maybe,
                    ),
                    title: const Text('Waiting for your approval'),
                    subtitle: Text(
                      [
                        'An agent wrote this rule, so it does not run yet.',
                        if (_highRisk) 'It drives a device that runs commands on a computer.',
                        'Saving keeps it waiting and opens its review.',
                      ].join(' '),
                    ),
                  ),
                ),
              const _Heading('WHEN', help: 'any of these happens'),
              for (final (i, t) in spec.when.indexed)
                _ItemCard(
                  itemKey: 'when-$i',
                  title: describeTrigger(things, t),
                  onEdit: () async {
                    final edited = await editTrigger(context, things, t);
                    if (edited != null) {
                      setState(() => spec.when[i] = edited);
                    }
                  },
                  onRemove: () => setState(() => spec.when.removeAt(i)),
                ),
              _AddButton(
                buttonKey: 'add-when',
                label: 'Add a trigger',
                onPressed: () async {
                  final t = await editTrigger(context, things);
                  if (t != null) setState(() => spec.when.add(t));
                },
              ),
              const _Heading('ONLY IF', help: 'all of these hold'),
              _ConditionList(conditions: spec.onlyIf, path: 'only-if'),
              const _Heading('THEN', help: 'do these in order'),
              StepList(steps: spec.then, path: 'then'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('rule-test'),
                      onPressed: _busy || spec.when.isEmpty ? null : _testRun,
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Test run'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('rule-save'),
                      onPressed:
                          _busy || !spec.complete || _name.text.trim().isEmpty
                          ? null
                          : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      },
    );
  }
}

/// What the dry run did: each run's outcome, then each step it reached
/// and the first error. A step shows the engine's label for it when the
/// trace carries one, and the compiled node id otherwise. A refused rule
/// shows why.
String dryRunText(Json result) {
  if (result['ok'] != true) return errorMessage(result);
  final runs = EngineCalls.dryRuns(result);
  if (runs.isEmpty) return 'Nothing ran.';
  return [
    for (final r in runs) ...[
      'Outcome: ${r['outcome'] ?? 'done'}${r['reason'] != null ? ' (${r['reason']})' : ''}',
      for (final n in (r['nodes'] as List? ?? const []).cast<Map>())
        '${n['label'] ?? n['node']}'
            '${n['port'] != null ? ' -> ${n['port']}' : ''}'
            '${n['error'] != null ? ': ${n['error']}' : ''}',
    ],
  ].join('\n');
}

/// The things and automations a nested editor picks from, and the page's
/// rebuild after an in-place edit.
class _RuleScope extends InheritedWidget {
  const _RuleScope({
    required this.things,
    required this.automations,
    required this.onChanged,
    required super.child,
  });

  final List<Thing> things;
  final List<Json> automations;
  final VoidCallback onChanged;

  static _RuleScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RuleScope>()!;

  @override
  bool updateShouldNotify(_RuleScope old) =>
      things != old.things || automations != old.automations;
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.help});

  final String text;
  final String? help;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        if (help != null)
          Text(help!, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

/// Marks a list the rule cannot be saved without.
class _Missing extends StatelessWidget {
  const _Missing(this.itemKey, this.text);

  final String itemKey;
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    key: ValueKey(itemKey),
    style: TextStyle(color: Theme.of(context).colorScheme.error),
  );
}

class _AddButton extends StatelessWidget {
  const _AddButton({
    required this.buttonKey,
    required this.label,
    required this.onPressed,
  });

  final String buttonKey;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: ValueKey(buttonKey),
      onPressed: onPressed,
      icon: const Icon(Icons.add),
      label: Text(label),
    ),
  );
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.itemKey,
    required this.title,
    this.onEdit,
    required this.onRemove,
    this.leading = const [],
    this.child,
  });

  final String itemKey;
  final String title;
  final VoidCallback? onEdit;
  final VoidCallback onRemove;
  final List<Widget> leading;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey(itemKey),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title)),
              ...leading,
              if (onEdit != null)
                IconButton(
                  key: ValueKey('edit-$itemKey'),
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
              IconButton(
                key: ValueKey('remove-$itemKey'),
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: onRemove,
              ),
            ],
          ),
          ?child,
        ],
      ),
    ),
  );
}

class _ConditionList extends StatelessWidget {
  const _ConditionList({required this.conditions, required this.path});

  final List<RuleCondition> conditions;
  final String path;

  @override
  Widget build(BuildContext context) {
    final scope = _RuleScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, c) in conditions.indexed)
          _ItemCard(
            itemKey: '$path-$i',
            title: describeCondition(scope.things, c),
            onEdit: c is UnknownCondition
                ? null
                : () async {
                    final edited = await editCondition(
                      context,
                      scope.things,
                      c,
                    );
                    if (edited == null) return;
                    conditions[i] = edited;
                    scope.onChanged();
                  },
            onRemove: () {
              conditions.removeAt(i);
              scope.onChanged();
            },
          ),
        _AddButton(
          buttonKey: 'add-$path',
          label: 'Add a condition',
          onPressed: () async {
            final c = await editCondition(context, scope.things);
            if (c == null) return;
            conditions.add(c);
            scope.onChanged();
          },
        ),
      ],
    );
  }
}

/// A list of steps with reorder, edit and remove, and the add-step picker.
/// If/else and together steps hold their own lists, shown nested.
class StepList extends StatelessWidget {
  const StepList({super.key, required this.steps, required this.path});

  final List<RuleStep> steps;

  /// Where the list sits in the rule, for widget keys: `then`, `then.0.else`.
  final String path;

  @override
  Widget build(BuildContext context) {
    final scope = _RuleScope.of(context);
    void changed() => scope.onChanged();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in steps.indexed)
          _ItemCard(
            itemKey: 'step-$path.$i',
            title: describeStep(scope.things, scope.automations, step),
            leading: [
              IconButton(
                key: ValueKey('step-up-$path.$i'),
                tooltip: 'Move up',
                icon: const Icon(Icons.arrow_upward),
                onPressed: i == 0
                    ? null
                    : () {
                        steps.insert(i - 1, steps.removeAt(i));
                        changed();
                      },
              ),
              IconButton(
                key: ValueKey('step-down-$path.$i'),
                tooltip: 'Move down',
                icon: const Icon(Icons.arrow_downward),
                onPressed: i == steps.length - 1
                    ? null
                    : () {
                        steps.insert(i + 1, steps.removeAt(i));
                        changed();
                      },
              ),
            ],
            onEdit: switch (step) {
              IfStep() || TogetherStep() || UnknownStep() => null,
              _ => () async {
                final edited = await editStep(
                  context,
                  scope.things,
                  scope.automations,
                  step,
                );
                if (edited == null) return;
                steps[i] = edited;
                changed();
              },
            },
            onRemove: () {
              steps.removeAt(i);
              changed();
            },
            child: switch (step) {
              IfStep() => Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading('IF', help: 'all of these hold'),
                    if (step.conditions.isEmpty)
                      _Missing('missing-cond-$path.$i', 'Add a condition'),
                    _ConditionList(
                      conditions: step.conditions,
                      path: 'cond-$path.$i',
                    ),
                    const _Heading('THEN'),
                    if (step.then.isEmpty)
                      _Missing('missing-then-$path.$i', 'Add a step'),
                    StepList(steps: step.then, path: '$path.$i.then'),
                    const _Heading('OTHERWISE'),
                    StepList(steps: step.otherwise, path: '$path.$i.else'),
                  ],
                ),
              ),
              WaitForStep() => Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Heading(
                      'IF THE TIME RUNS OUT',
                      help: 'do these, then stop',
                    ),
                    StepList(steps: step.onTimeout, path: '$path.$i.timeout'),
                  ],
                ),
              ),
              TogetherStep() => Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (b, branch) in step.branches.indexed) ...[
                      Row(
                        children: [
                          Expanded(child: _Heading('BRANCH ${b + 1}')),
                          if (step.branches.length > 2)
                            IconButton(
                              key: ValueKey('remove-branch-$path.$i.$b'),
                              tooltip: 'Remove branch ${b + 1}',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                step.branches.removeAt(b);
                                changed();
                              },
                            ),
                        ],
                      ),
                      if (branch.isEmpty)
                        _Missing('missing-branch-$path.$i.$b', 'Add a step'),
                      StepList(steps: branch, path: '$path.$i.b$b'),
                    ],
                    _AddButton(
                      buttonKey: 'add-branch-$path.$i',
                      label: 'Add a branch',
                      onPressed: () {
                        step.branches.add([]);
                        changed();
                      },
                    ),
                  ],
                ),
              ),
              _ => null,
            },
          ),
        _AddButton(
          buttonKey: 'add-step-$path',
          label: 'Add a step',
          onPressed: () async {
            final step = await addStep(
              context,
              scope.things,
              scope.automations,
            );
            if (step == null) return;
            steps.add(step);
            changed();
          },
        ),
      ],
    );
  }
}

/// Every kind of step, in the add-step picker's order.
enum StepKind {
  action('Do something', Icons.bolt),
  toggle('Toggle on or off', Icons.toggle_on_outlined),
  wait('Wait', Icons.hourglass_empty),
  waitFor('Wait until', Icons.hourglass_bottom),
  ifElse('If / otherwise', Icons.call_split),
  together('Do together', Icons.alt_route),
  setVariable('Set a variable', Icons.data_object),
  notify('Notify', Icons.notifications_outlined),
  run('Run an automation', Icons.account_tree_outlined);

  const StepKind(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Picks a step kind, then sets it up. If/else and together start empty
/// and are filled in place.
Future<RuleStep?> addStep(
  BuildContext context,
  List<Thing> things,
  List<Json> automations,
) async {
  final kind = await showModalBottomSheet<StepKind>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final k in StepKind.values)
              ListTile(
                key: ValueKey('step-kind-${k.name}'),
                leading: Icon(k.icon),
                title: Text(k.label),
                onTap: () => Navigator.of(context).pop(k),
              ),
          ],
        ),
      ),
    ),
  );
  if (kind == null || !context.mounted) return null;
  return switch (kind) {
    StepKind.ifElse => IfStep(),
    StepKind.together => TogetherStep(),
    _ => editStep(context, things, automations, _blank(kind)),
  };
}

RuleStep _blank(StepKind kind) => switch (kind) {
  StepKind.action => DoStep('', ''),
  StepKind.toggle => ToggleStep('', ''),
  StepKind.wait => WaitStep(5000),
  StepKind.waitFor => WaitForStep(OnTrigger(thing: '', key: '')),
  StepKind.setVariable => SetStep('', null),
  StepKind.notify => NotifyStep(''),
  StepKind.run => RunStep(''),
  StepKind.ifElse => IfStep(),
  StepKind.together => TogetherStep(),
};

// Descriptions.

String describeTrigger(List<Thing> things, RuleTrigger t) => switch (t) {
  OnTrigger(mode: OnMode.event) =>
    '${describeRef(things, t.thing, t.key)} happens'
        '${t.match == null || t.match!.isEmpty ? '' : ' with ${t.match}'}',
  OnTrigger(mode: OnMode.crosses) =>
    '${describeRef(things, t.thing, t.key)} goes '
        '${t.above != null ? 'above ${t.above}' : 'below ${t.below}'}',
  OnTrigger() =>
    '${describeRef(things, t.thing, t.key)} changes'
        '${t.hasTo ? ' to ${t.to}' : ''}',
  TimeTrigger() =>
    'At ${t.at}${t.days.isEmpty ? '' : ' on ${t.days.join(', ')}'}',
  IntervalTrigger() => 'Every ${durationText(t.seconds * 1000)}',
  ManualTrigger() => 'When run by hand',
};

/// A compare side: a literal, or `{"state" | "var" | "msg": ref}`.
String describeValue(List<Thing> things, Object? v) => switch (v) {
  {'state': final String ref} => () {
    final (thing, key) = splitRef(ref);
    return describeRef(things, thing, key);
  }(),
  {'var': final name} => '$name',
  {'msg': final key} => 'the trigger\'s $key',
  _ => '$v',
};

String describeCondition(List<Thing> things, RuleCondition c) => switch (c) {
  CompareCondition() =>
    '${describeValue(things, {c.source: c.ref})} ${c.op} '
        '${describeValue(things, c.value)}',
  BetweenCondition() => 'Between ${c.start} and ${c.end}',
  DaysCondition() => 'On ${c.days.join(', ')}',
  UnknownCondition() =>
    'A condition this app cannot edit: ${c.json.keys.join(', ')}',
};

String describeStep(
  List<Thing> things,
  List<Json> automations,
  RuleStep s,
) => switch (s) {
  DoStep() =>
    '${describeRef(things, s.thing, s.capability)}'
        '${s.params.isEmpty ? '' : ' ${s.params.entries.map((e) => '${e.key} ${e.value}').join(', ')}'}',
  ToggleStep() => 'Toggle ${describeRef(things, s.thing, s.capability)}',
  WaitStep() => 'Wait ${durationText(s.ms)}',
  WaitForStep() =>
    'Wait until ${describeTrigger(things, s.until)}, at most '
        '${durationText(s.timeoutMs)}',
  IfStep() => 'If / otherwise',
  TogetherStep() => 'Do together',
  SetStep() => 'Set ${s.name} to ${s.value}',
  NotifyStep() => 'Notify: ${s.title}',
  RunStep() =>
    'Run ${automations.where((a) => a['id'] == s.automationId).firstOrNull?['name'] ?? s.automationId}',
  UnknownStep() => 'A step this app cannot edit: ${s.json.keys.join(', ')}',
};

// Editors.

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final _variable = RegExp(r'^\$[A-Za-z_][A-Za-z0-9_]*$');

/// A dialog with an OK button that is enabled only while [build] says the
/// form is complete, returning what [result] makes of it.
Future<T?> _editDialog<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext, StateSetter) build,
  required T? Function() result,
}) => showDialog<T>(
  context: context,
  builder: (context) => StatefulBuilder(
    builder: (context, setState) {
      final value = result();
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(child: build(context, setState)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('editor-ok'),
            onPressed: value == null
                ? null
                : () => Navigator.of(context).pop(value),
            child: const Text('OK'),
          ),
        ],
      );
    },
  ),
);

/// Picks a thing, then one of its state keys or events.
class ThingKeyPicker extends StatelessWidget {
  const ThingKeyPicker({
    super.key,
    required this.things,
    required this.thing,
    required this.keyName,
    required this.events,
    required this.onChanged,
    this.prefix = 'pick',
  });

  final List<Thing> things;
  final String thing;
  final String keyName;

  /// Events instead of state keys.
  final bool events;
  final void Function(String thing, String key) onChanged;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final picked = things.where((t) => t.id == thing).firstOrNull;
    final keys = picked == null
        ? const <({String key, String label})>[]
        : events
        ? picked.events
        : picked.stateKeys;
    return Column(
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('$prefix-thing'),
          initialValue: picked?.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Thing'),
          items: thingItems(things),
          onChanged: (id) => onChanged(id ?? '', ''),
        ),
        if (picked != null)
          DropdownButtonFormField<String>(
            key: ValueKey('$prefix-key-${picked.id}${events ? '-event' : ''}'),
            initialValue: keys.any((k) => k.key == keyName) ? keyName : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: events ? 'Event' : 'State',
              helperText: keys.isEmpty && !picked.isBoard
                  ? 'It reports nothing a rule can use yet'
                  : null,
            ),
            items: [
              for (final k in keys)
                DropdownMenuItem(value: k.key, child: Text(k.label)),
            ],
            onChanged: (k) => onChanged(picked.id, k ?? ''),
          ),
        if (picked != null && events && picked.isBoard)
          TextFormField(
            key: ValueKey('$prefix-event-text'),
            initialValue: keys.any((k) => k.key == keyName) ? '' : keyName,
            decoration: const InputDecoration(
              labelText: 'Or the event the firmware sends',
              hintText: 'button.pressed',
            ),
            onChanged: (k) => onChanged(picked.id, k.trim()),
          ),
      ],
    );
  }
}

/// The things for a dropdown, under a disabled heading per group.
List<DropdownMenuItem<String>> thingItems(
  List<Thing> things, {
  bool Function(Thing)? where,
}) {
  final out = <DropdownMenuItem<String>>[];
  String? group;
  for (final t in things) {
    if (where != null && !where(t)) continue;
    if (t.group != group) {
      group = t.group;
      out.add(
        DropdownMenuItem(
          enabled: false,
          value: '#$group',
          child: Text(
            group,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      );
    }
    out.add(DropdownMenuItem(value: t.id, child: Text('  ${t.name}')));
  }
  return out;
}

enum _TriggerKind {
  change('A thing changes'),
  event('A thing does something'),
  crosses('A number crosses a value'),
  time('At a time of day'),
  every('Every so often'),
  manual('Only when run by hand');

  const _TriggerKind(this.label);

  final String label;
}

/// Edits a trigger. [onOnly] limits it to the thing triggers, for a wait
/// until.
Future<RuleTrigger?> editTrigger(
  BuildContext context,
  List<Thing> things, [
  RuleTrigger? current,
  bool onOnly = false,
]) {
  var kind = switch (current) {
    OnTrigger(mode: OnMode.event) => _TriggerKind.event,
    OnTrigger(mode: OnMode.crosses) => _TriggerKind.crosses,
    TimeTrigger() => _TriggerKind.time,
    IntervalTrigger() => _TriggerKind.every,
    ManualTrigger() => _TriggerKind.manual,
    _ => _TriggerKind.change,
  };
  final on = current is OnTrigger ? current : null;
  var thing = on?.thing ?? '';
  var key = on?.key ?? '';
  var below = on?.below != null;
  final to = TextEditingController(text: on?.hasTo == true ? '${on!.to}' : '');
  final threshold = TextEditingController(
    text: '${on?.above ?? on?.below ?? ''}',
  );
  final at = TextEditingController(
    text: current is TimeTrigger ? current.at : '',
  );
  final days = <String>{if (current is TimeTrigger) ...current.days};
  var every = current is IntervalTrigger ? current.seconds * 1000 : 60000;
  return _editDialog(
    context,
    title: 'When',
    result: () => switch (kind) {
      _TriggerKind.change ||
      _TriggerKind.event when thing.isNotEmpty && key.isNotEmpty => OnTrigger(
        thing: thing,
        key: key,
        mode: kind == _TriggerKind.event ? OnMode.event : OnMode.change,
        hasTo: kind == _TriggerKind.change && to.text.trim().isNotEmpty,
        to: literalFromText(to.text),
        match: on?.mode == OnMode.event ? on?.match : null,
      ),
      _TriggerKind.crosses
          when thing.isNotEmpty &&
              key.isNotEmpty &&
              num.tryParse(threshold.text.trim()) != null =>
        OnTrigger(
          thing: thing,
          key: key,
          mode: OnMode.crosses,
          above: below ? null : num.parse(threshold.text.trim()),
          below: below ? num.parse(threshold.text.trim()) : null,
        ),
      _TriggerKind.time when _hhmm.hasMatch(at.text.trim()) => TimeTrigger(
        at.text.trim(),
        days: [
          for (final d in weekDays)
            if (days.contains(d)) d,
        ],
      ),
      _TriggerKind.every when every >= 1000 => IntervalTrigger(every ~/ 1000),
      _TriggerKind.manual => const ManualTrigger(),
      _ => null,
    },
    build: (context, setState) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<_TriggerKind>(
          key: const ValueKey('trigger-kind'),
          initialValue: kind,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'When'),
          items: [
            for (final k in _TriggerKind.values)
              if (!onOnly || k.index <= _TriggerKind.crosses.index)
                DropdownMenuItem(value: k, child: Text(k.label)),
          ],
          onChanged: (k) => setState(() {
            final next = k ?? kind;
            if ((next == _TriggerKind.event) != (kind == _TriggerKind.event)) {
              key = '';
            }
            kind = next;
          }),
        ),
        if (kind.index <= _TriggerKind.crosses.index)
          ThingKeyPicker(
            things: things,
            thing: thing,
            keyName: key,
            events: kind == _TriggerKind.event,
            onChanged: (t, k) => setState(() {
              thing = t;
              key = k;
            }),
          ),
        if (kind == _TriggerKind.change)
          TextField(
            key: const ValueKey('trigger-to'),
            controller: to,
            decoration: const InputDecoration(
              labelText: 'To (optional)',
              hintText: 'true, 30, or a word',
            ),
            onChanged: (_) => setState(() {}),
          ),
        if (kind == _TriggerKind.crosses) ...[
          DropdownButtonFormField<bool>(
            key: const ValueKey('trigger-direction'),
            initialValue: below,
            decoration: const InputDecoration(labelText: 'Goes'),
            items: const [
              DropdownMenuItem(value: false, child: Text('above')),
              DropdownMenuItem(value: true, child: Text('below')),
            ],
            onChanged: (v) => setState(() => below = v ?? false),
          ),
          TextField(
            key: const ValueKey('trigger-threshold'),
            controller: threshold,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Value'),
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (kind == _TriggerKind.time) ...[
          TextField(
            key: const ValueKey('trigger-time'),
            controller: at,
            decoration: const InputDecoration(
              labelText: 'Time',
              hintText: '18:30',
            ),
            onChanged: (_) => setState(() {}),
          ),
          _DayChips(days: days, onChanged: () => setState(() {})),
        ],
        if (kind == _TriggerKind.every)
          DurationField(
            fieldKey: 'trigger-every',
            ms: every,
            onChanged: (ms) => setState(() => every = ms),
          ),
      ],
    ),
  );
}

class _DayChips extends StatelessWidget {
  const _DayChips({required this.days, required this.onChanged});

  final Set<String> days;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    children: [
      for (final d in weekDays)
        FilterChip(
          key: ValueKey('day-$d'),
          label: Text(d),
          selected: days.contains(d),
          onSelected: (on) {
            on ? days.add(d) : days.remove(d);
            onChanged();
          },
        ),
    ],
  );
}

enum DurationUnit {
  seconds('s', 1000),
  minutes('min', 60000),
  hours('h', 3600000);

  const DurationUnit(this.label, this.ms);

  final String label;
  final int ms;
}

/// A duration as a whole number and a unit.
class DurationField extends StatefulWidget {
  const DurationField({
    super.key,
    required this.fieldKey,
    required this.ms,
    required this.onChanged,
    this.label = 'How long',
  });

  final String fieldKey;
  final int ms;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  State<DurationField> createState() => _DurationFieldState();
}

class _DurationFieldState extends State<DurationField> {
  late var _unit = DurationUnit.values.lastWhere(
    (u) => widget.ms % u.ms == 0 && widget.ms >= u.ms,
    orElse: () => DurationUnit.seconds,
  );
  late final _amount = TextEditingController(text: '${widget.ms ~/ _unit.ms}');

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _send() {
    final n = int.tryParse(_amount.text.trim());
    widget.onChanged(n == null || n < 0 ? -1 : n * _unit.ms);
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          key: ValueKey(widget.fieldKey),
          controller: _amount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: widget.label),
          onChanged: (_) => _send(),
        ),
      ),
      const SizedBox(width: 8),
      DropdownButton<DurationUnit>(
        key: ValueKey('${widget.fieldKey}-unit'),
        value: _unit,
        items: [
          for (final u in DurationUnit.values)
            DropdownMenuItem(value: u, child: Text(u.label)),
        ],
        onChanged: (u) {
          setState(() => _unit = u ?? _unit);
          _send();
        },
      ),
    ],
  );
}

enum _ConditionKind {
  compare('A thing or variable has a value'),
  window('Between two times'),
  days('On some days');

  const _ConditionKind(this.label);

  final String label;
}

Future<RuleCondition?> editCondition(
  BuildContext context,
  List<Thing> things, [
  RuleCondition? current,
]) {
  var kind = switch (current) {
    BetweenCondition() => _ConditionKind.window,
    DaysCondition() => _ConditionKind.days,
    _ => _ConditionKind.compare,
  };
  final compare = current is CompareCondition ? current : null;
  final (stateThing, stateKey) = compare?.source == 'state'
      ? splitRef(compare!.ref)
      : ('', '');
  var thing = stateThing;
  var key = stateKey;
  var useVariable = compare?.source == 'var';
  final variable = TextEditingController(text: useVariable ? compare!.ref : '');
  var op = compare?.op ?? '==';
  // A value that reads another state or variable is kept unless retyped.
  final reference = compare?.value is Map ? compare!.value : null;
  final value = TextEditingController(
    text: compare == null || reference != null ? '' : '${compare.value}',
  );
  final start = TextEditingController(
    text: current is BetweenCondition ? current.start : '',
  );
  final end = TextEditingController(
    text: current is BetweenCondition ? current.end : '',
  );
  final days = <String>{if (current is DaysCondition) ...current.days};
  return _editDialog(
    context,
    title: 'Only if',
    result: () {
      switch (kind) {
        case _ConditionKind.compare:
          final String ref;
          if (useVariable) {
            if (!_variable.hasMatch(variable.text.trim())) return null;
            ref = variable.text.trim();
          } else {
            if (thing.isEmpty || key.isEmpty) return null;
            ref = '$thing.$key';
          }
          final typed = value.text.trim();
          if (typed.isEmpty && reference == null) return null;
          return CompareCondition(
            useVariable ? 'var' : 'state',
            ref,
            op,
            typed.isEmpty ? reference : literalFromText(typed),
          );
        case _ConditionKind.window:
          if (!_hhmm.hasMatch(start.text.trim()) ||
              !_hhmm.hasMatch(end.text.trim())) {
            return null;
          }
          return BetweenCondition(start.text.trim(), end.text.trim());
        case _ConditionKind.days:
          if (days.isEmpty) return null;
          return DaysCondition([
            for (final d in weekDays)
              if (days.contains(d)) d,
          ]);
      }
    },
    build: (context, setState) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<_ConditionKind>(
          key: const ValueKey('condition-kind'),
          initialValue: kind,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Only if'),
          items: [
            for (final k in _ConditionKind.values)
              DropdownMenuItem(value: k, child: Text(k.label)),
          ],
          onChanged: (k) => setState(() => kind = k ?? kind),
        ),
        if (kind == _ConditionKind.compare) ...[
          SwitchListTile(
            key: const ValueKey('condition-variable'),
            contentPadding: EdgeInsets.zero,
            title: const Text('A variable instead of a thing'),
            value: useVariable,
            onChanged: (v) => setState(() => useVariable = v),
          ),
          if (useVariable)
            TextField(
              key: const ValueKey('condition-var'),
              controller: variable,
              decoration: const InputDecoration(
                labelText: 'Variable',
                hintText: r'$HomeWifiConnected',
              ),
              onChanged: (_) => setState(() {}),
            )
          else
            ThingKeyPicker(
              things: things,
              thing: thing,
              keyName: key,
              events: false,
              onChanged: (t, k) => setState(() {
                thing = t;
                key = k;
              }),
            ),
          DropdownButtonFormField<String>(
            key: const ValueKey('condition-op'),
            initialValue: op,
            decoration: const InputDecoration(labelText: 'Is'),
            items: [
              for (final o in const ['==', '!=', '<', '<=', '>', '>='])
                DropdownMenuItem(value: o, child: Text(o)),
            ],
            onChanged: (o) => setState(() => op = o ?? op),
          ),
          TextField(
            key: const ValueKey('condition-value'),
            controller: value,
            decoration: const InputDecoration(
              labelText: 'Value',
              hintText: 'true, 30, or a word',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (kind == _ConditionKind.window) ...[
          TextField(
            key: const ValueKey('condition-start'),
            controller: start,
            decoration: const InputDecoration(
              labelText: 'From',
              hintText: '18:00',
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const ValueKey('condition-end'),
            controller: end,
            decoration: const InputDecoration(
              labelText: 'To',
              hintText: '05:00',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (kind == _ConditionKind.days)
          _DayChips(days: days, onChanged: () => setState(() {})),
      ],
    ),
  );
}

/// Edits one step of any kind except if/else and together, which are
/// edited in place.
Future<RuleStep?> editStep(
  BuildContext context,
  List<Thing> things,
  List<Json> automations,
  RuleStep step,
) async {
  switch (step) {
    case DoStep():
      return _editAction(context, things, step);
    case ToggleStep():
      var thing = step.thing;
      var capability = step.capability;
      return _editDialog(
        context,
        title: 'Toggle',
        result: () => thing.isEmpty || capability.isEmpty
            ? null
            : ToggleStep(thing, capability),
        build: (context, setState) {
          final picked = things.where((t) => t.id == thing).firstOrNull;
          final toggles = picked?.toggles ?? const <Json>[];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('toggle-thing'),
                initialValue: picked?.id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Thing'),
                items: thingItems(things, where: (t) => t.toggles.isNotEmpty),
                onChanged: (id) => setState(() {
                  thing = id ?? '';
                  capability = '';
                }),
              ),
              if (picked != null)
                DropdownButtonFormField<String>(
                  key: ValueKey('toggle-capability-${picked.id}'),
                  initialValue: toggles.any((c) => c['id'] == capability)
                      ? capability
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Switch'),
                  items: [
                    for (final c in toggles)
                      DropdownMenuItem(
                        value: '${c['id']}',
                        child: Text('${c['label']}'),
                      ),
                  ],
                  onChanged: (c) => setState(() => capability = c ?? ''),
                ),
            ],
          );
        },
      );
    case WaitStep():
      var ms = step.ms;
      return _editDialog(
        context,
        title: 'Wait',
        result: () => ms < 0 ? null : WaitStep(ms),
        build: (context, setState) => DurationField(
          fieldKey: 'wait-duration',
          ms: ms,
          onChanged: (v) => setState(() => ms = v),
        ),
      );
    case WaitForStep():
      final until = await editTrigger(context, things, step.until, true);
      if (until is! OnTrigger || !context.mounted) return null;
      var timeout = step.timeoutMs;
      return _editDialog(
        context,
        title: 'Wait at most',
        result: () => timeout < 1000
            ? null
            : WaitForStep(until, timeoutMs: timeout, onTimeout: step.onTimeout),
        build: (context, setState) => DurationField(
          fieldKey: 'wait-for-timeout',
          label: 'At most',
          ms: timeout,
          onChanged: (v) => setState(() => timeout = v),
        ),
      );
    case SetStep():
      final name = TextEditingController(text: step.name);
      final value = TextEditingController(
        text: step.value == null ? '' : '${step.value}',
      );
      return _editDialog(
        context,
        title: 'Set a variable',
        result: () => _variable.hasMatch(name.text.trim())
            ? SetStep(name.text.trim(), literalFromText(value.text))
            : null,
        build: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('set-name'),
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Variable',
                hintText: r'$Away',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('set-value'),
              controller: value,
              decoration: const InputDecoration(labelText: 'Value'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      );
    case NotifyStep():
      final title = TextEditingController(text: step.title);
      final body = TextEditingController(text: step.body ?? '');
      return _editDialog(
        context,
        title: 'Notify',
        result: () => title.text.trim().isEmpty
            ? null
            : NotifyStep(
                title.text.trim(),
                body: body.text.trim().isEmpty ? null : body.text.trim(),
                extra: step.extra,
              ),
        build: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('notify-title'),
              controller: title,
              decoration: const InputDecoration(labelText: 'Title'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('notify-body'),
              controller: body,
              decoration: const InputDecoration(labelText: 'Text (optional)'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Shows at the bottom of this screen while OmniFlow is open. '
                'Phone notifications are not built yet.',
                key: ValueKey('notify-where'),
              ),
            ),
          ],
        ),
      );
    case RunStep():
      var id = step.automationId;
      return _editDialog(
        context,
        title: 'Run an automation',
        result: () => id.isEmpty ? null : RunStep(id),
        build: (context, setState) => DropdownButtonFormField<String>(
          key: const ValueKey('run-automation'),
          initialValue: automations.any((a) => a['id'] == id) ? id : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Automation',
            helperText: automations.isEmpty ? 'There is none yet' : null,
          ),
          items: [
            for (final a in automations)
              DropdownMenuItem(
                value: '${a['id']}',
                child: Text('${a['name']}'),
              ),
          ],
          onChanged: (v) => setState(() => id = v ?? ''),
        ),
      );
    case IfStep() || TogetherStep() || UnknownStep():
      return step;
  }
}

/// Picks a thing and one of its actions, then fills in its params.
Future<RuleStep?> _editAction(
  BuildContext context,
  List<Thing> things,
  DoStep step,
) {
  var thing = step.thing;
  var capability = step.capability;
  return showDialog<RuleStep>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final picked = things.where((t) => t.id == thing).firstOrNull;
        final actions = picked?.actions ?? const <Json>[];
        final cap = picked?.capability(capability);
        return AlertDialog(
          title: const Text('Do something'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    key: const ValueKey('action-thing'),
                    initialValue: picked?.id,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Thing'),
                    items: thingItems(
                      things,
                      where: (t) => t.actions.isNotEmpty,
                    ),
                    onChanged: (id) => setState(() {
                      thing = id ?? '';
                      capability = '';
                    }),
                  ),
                  if (picked != null)
                    DropdownButtonFormField<String>(
                      key: ValueKey('action-capability-${picked.id}'),
                      initialValue: cap?['id'] as String?,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Action'),
                      items: [
                        for (final c in actions)
                          DropdownMenuItem(
                            value: '${c['id']}',
                            child: Text('${c['label']}'),
                          ),
                      ],
                      onChanged: (c) => setState(() => capability = c ?? ''),
                    ),
                  if (cap != null)
                    ParamsForm(
                      key: ValueKey('action-params-${picked!.id}.$capability'),
                      label: '${cap['label']}',
                      submitLabel: 'Use',
                      initial:
                          capability == step.capability && thing == step.thing
                          ? step.params
                          : const {},
                      params: {
                        for (final e
                            in (cap['params'] as Map? ?? const {}).entries)
                          '${e.key}': Map<String, Object?>.from(e.value as Map),
                      },
                      onSubmit: (params) async {
                        Navigator.of(context)
                            .pop(DoStep(thing, capability, params: params));
                        return true;
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    ),
  );
}
