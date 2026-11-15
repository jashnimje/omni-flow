import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/house_calls.dart';
import '../../rules/rule_spec.dart';
import '../../state/house_providers.dart';
import '../design/design.dart';
import '../home/mode_picker.dart' show modeIcon;
import 'form_parts.dart';

export '../../rules/house_words.dart';

/// The editor's forms for the house mode and the timers: "When the mode
/// changes to Night", "Only if the mode is Away", "Set the mode to Night",
/// "When timer Pasta ends" and the timer steps. Each builds the same rule
/// shape the engine words and checks.

const _built = [
  HouseMode('home', 'Home'),
  HouseMode('away', 'Away'),
  HouseMode('night', 'Night'),
  HouseMode('vacation', 'Vacation'),
];

/// The modes to choose from: the engine's, or the four built in when it
/// does not answer.
Future<List<HouseMode>> _modes(BuildContext context) async {
  final r = await ProviderScope.containerOf(
    context,
    listen: false,
  ).read(houseApiProvider).modes();
  final modes = r['ok'] == true ? HouseModes.fromJson(r)?.modes : null;
  return modes == null || modes.isEmpty ? _built : modes;
}

List<Widget> _modeRows(
  List<HouseMode> modes,
  String? selected,
  void Function(String) pick,
) => [
  for (final m in modes)
    ChoiceRow(
      key: ValueKey('house-mode-${m.id}'),
      title: m.name,
      icon: modeIcon(m.id),
      selected: m.id == selected,
      onTap: () => pick(m.id),
    ),
];

/// "When the mode changes to …", or to any mode.
Future<OnTrigger?> modeTriggerForm(
  BuildContext context, [
  OnTrigger? current,
]) async {
  final modes = await _modes(context);
  if (!context.mounted) return null;
  var mode = current?.match?['mode'] as String?;
  return showFormSheet<OnTrigger>(
    context,
    title: 'When the mode changes',
    subtitle: 'Pick the mode it changes to, or Any mode.',
    result: () => OnTrigger(
      thing: HouseCalls.modeThing,
      key: 'changed',
      mode: OnMode.event,
      match: mode == null ? null : {'mode': mode},
    ),
    build: (context, setState) => [
      ChoiceRow(
        key: const ValueKey('house-mode-any'),
        title: 'Any mode',
        selected: mode == null,
        onTap: () => setState(() => mode = null),
      ),
      ..._modeRows(modes, mode, (m) => setState(() => mode = m)),
    ],
  );
}

/// "Only if the mode is …" or "is not …".
Future<CompareCondition?> modeConditionForm(
  BuildContext context, [
  CompareCondition? current,
]) async {
  final modes = await _modes(context);
  if (!context.mounted) return null;
  var mode = current?.value is String
      ? current!.value as String
      : modes.first.id;
  var isNot = current?.op == '!=';
  return showFormSheet<CompareCondition>(
    context,
    title: 'Only if the mode…',
    result: () => CompareCondition(
      'state',
      '${HouseCalls.modeThing}.mode',
      isNot ? '!=' : '==',
      mode,
    ),
    build: (context, setState) => [
      OmniSegmented<bool>(
        segments: const [OmniSegment(false, 'Is'), OmniSegment(true, 'Is not')],
        selected: isNot,
        onChanged: (v) => setState(() => isNot = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      ..._modeRows(modes, mode, (m) => setState(() => mode = m)),
    ],
  );
}

/// "Set the mode to …".
Future<DoStep?> modeStepForm(BuildContext context, [DoStep? current]) async {
  final modes = await _modes(context);
  if (!context.mounted) return null;
  var mode = current?.params['mode'] as String? ?? modes.first.id;
  return showFormSheet<DoStep>(
    context,
    title: 'Set the house mode',
    result: () => DoStep(HouseCalls.modeThing, 'set', params: {'mode': mode}),
    build: (context, setState) =>
        _modeRows(modes, mode, (m) => setState(() => mode = m)),
  );
}

/// "When timer … ends": a timer's name, or any timer.
Future<OnTrigger?> timerTriggerForm(
  BuildContext context, [
  OnTrigger? current,
]) {
  final timer = current?.match?['timer'];
  final name = TextEditingController(
    text: timer is String ? modeName(timer) : '',
  );
  return showFormSheet<OnTrigger>(
    context,
    owns: [name],
    title: 'When a timer ends',
    subtitle: 'Leave the name empty for any timer.',
    result: () {
      final id = houseIdOf(name.text);
      return OnTrigger(
        thing: HouseCalls.timersThing,
        key: 'ended',
        mode: OnMode.event,
        match: id.isEmpty ? null : {'timer': id},
      );
    },
    build: (context, setState) => [
      TextField(
        key: const ValueKey('timer-trigger-name'),
        controller: name,
        decoration: const InputDecoration(labelText: 'Timer name, like Pasta'),
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// The timer actions a step takes, with their words.
const timerActions = {
  'start': 'Start',
  'pause': 'Pause',
  'resume': 'Resume',
  'cancel': 'Cancel',
};

/// "Start a 20 min timer called Pasta", or pause, resume or cancel one.
Future<DoStep?> timerStepForm(BuildContext context, [DoStep? current]) {
  var action = current?.capability ?? 'start';
  final name = TextEditingController(text: '${current?.params['name'] ?? ''}');
  final ms = (current?.params['ms'] as num?)?.toInt() ?? 20 * 60000;
  final minutes = TextEditingController(
    text: ms % 60000 == 0 ? '${ms ~/ 60000}' : (ms / 60000).toStringAsFixed(1),
  );
  int? length() {
    final m = num.tryParse(minutes.text.trim());
    if (m == null || m <= 0 || m > 1440) return null;
    return (m * 60000).round();
  }

  return showFormSheet<DoStep>(
    context,
    owns: [name, minutes],
    title: 'A timer',
    result: () {
      final n = name.text.trim();
      if (houseIdOf(n).isEmpty || n.length > 40) return null;
      if (action != 'start') {
        return DoStep(HouseCalls.timersThing, action, params: {'name': n});
      }
      final l = length();
      return l == null || l < 1000
          ? null
          : DoStep(
              HouseCalls.timersThing,
              'start',
              params: {'name': n, 'ms': l},
            );
    },
    whyNot: () => houseIdOf(name.text).isEmpty
        ? 'Give the timer a name'
        : action == 'start' && length() == null
        ? 'Minutes are more than 0, up to 1440'
        : null,
    build: (context, setState) => [
      OmniSegmented<String>(
        segments: [
          for (final e in timerActions.entries) OmniSegment(e.key, e.value),
        ],
        selected: action,
        onChanged: (v) => setState(() => action = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      TextField(
        key: const ValueKey('timer-step-name'),
        controller: name,
        decoration: const InputDecoration(labelText: 'Timer name, like Pasta'),
        onChanged: (_) => setState(() {}),
      ),
      if (action == 'start')
        TextField(
          key: const ValueKey('timer-step-minutes'),
          controller: minutes,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Minutes'),
          onChanged: (_) => setState(() {}),
        ),
    ],
  );
}

/// Opens the form for a trigger on a built-in thing, or null for another.
Future<RuleTrigger?>? editHouseTrigger(BuildContext context, OnTrigger t) =>
    switch (t.thing) {
      HouseCalls.modeThing => modeTriggerForm(context, t),
      HouseCalls.timersThing => timerTriggerForm(context, t),
      _ => null,
    };

/// Opens the form for a step on a built-in thing, or null for another.
Future<RuleStep?>? editHouseStep(BuildContext context, DoStep s) =>
    switch (s.thing) {
      HouseCalls.modeThing => modeStepForm(context, s),
      HouseCalls.timersThing => timerStepForm(context, s),
      _ => null,
    };
