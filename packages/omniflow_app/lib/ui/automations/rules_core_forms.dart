import 'package:flutter/material.dart';

import '../../rules/rule_spec.dart';
import '../design/design.dart';
import 'form_parts.dart';
import 'rules_core_words.dart';

/// The editor's forms for the household triggers and conditions, held
/// state triggers and intervals lined up on the clock. Each builds the rule
/// shape the engine checks and words.

/// "The first person gets home" or "The last person leaves".
Future<PeopleTrigger?> peopleTriggerForm(
  BuildContext context, [
  PeopleTrigger? current,
]) {
  var kind = current?.kind ?? PeopleTrigger.firstArrives;
  return showFormSheet<PeopleTrigger>(
    context,
    title: 'When everyone…',
    subtitle: 'Counts every person, each by their own phone.',
    result: () => PeopleTrigger(kind),
    build: (context, setState) => [
      for (final k in const [
        PeopleTrigger.firstArrives,
        PeopleTrigger.lastLeaves,
      ])
        ChoiceRow(
          key: ValueKey('people-$k'),
          title: peopleTriggerText(PeopleTrigger(k)),
          icon: OmniIcons.home,
          selected: kind == k,
          onTap: () => setState(() => kind = k),
        ),
    ],
  );
}

/// "Everyone is away" or "Anyone is home".
Future<PeopleCondition?> peopleConditionForm(
  BuildContext context, [
  PeopleCondition? current,
]) {
  var kind = current?.kind ?? PeopleCondition.allAway;
  return showFormSheet<PeopleCondition>(
    context,
    title: 'Only if…',
    result: () => PeopleCondition(kind),
    build: (context, setState) => [
      for (final k in const [
        PeopleCondition.allAway,
        PeopleCondition.anyoneHome,
      ])
        ChoiceRow(
          key: ValueKey('people-$k'),
          title: peopleConditionText(PeopleCondition(k)),
          icon: OmniIcons.person,
          selected: kind == k,
          onTap: () => setState(() => kind = k),
        ),
    ],
  );
}

/// How long a state must hold before the trigger fires: right away, or
/// once it has stayed that way for a time. [ms] null is right away.
class HoldField extends StatelessWidget {
  const HoldField({super.key, required this.ms, required this.onChanged});

  final int? ms;
  final ValueChanged<int?> onChanged;

  /// Where "for a time" starts.
  static const defaultMs = 5 * 60000;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: OmniSpace.md),
      OmniSegmented<bool>(
        key: const ValueKey('hold-when'),
        segments: const [
          OmniSegment(false, 'Right away'),
          OmniSegment(true, 'Once it stays'),
        ],
        selected: ms != null,
        onChanged: (held) => onChanged(held ? defaultMs : null),
      ),
      if (ms != null) ...[
        const SizedBox(height: OmniSpace.sm),
        DurationInput(
          key: const ValueKey('hold-for'),
          label: 'For',
          ms: ms!,
          onChanged: onChanged,
        ),
        const Text(
          'It runs only if it stays that way the whole time, and not when '
          'it changes back first.',
          style: OmniText.caption,
        ),
      ],
    ],
  );
}

/// The parts of an interval that line it up on the clock: minutes past
/// each hour, and a window of the day.
class AlignedFields extends StatelessWidget {
  const AlignedFields({
    super.key,
    required this.offsetMinutes,
    required this.between,
    required this.onOffset,
    required this.onBetween,
  });

  final TextEditingController offsetMinutes;
  final List<String>? between;
  final VoidCallback onOffset;
  final ValueChanged<List<String>?> onBetween;

  @override
  Widget build(BuildContext context) {
    final window = between;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: OmniSpace.md),
        LabelledField(
          key: const ValueKey('interval-offset'),
          label: 'Minutes in (0 to start on the hour)',
          hint: '5 for :05',
          controller: offsetMinutes,
          number: true,
          onChanged: (_) => onOffset(),
        ),
        const SizedBox(height: OmniSpace.sm),
        OmniSegmented<bool>(
          key: const ValueKey('interval-window'),
          segments: const [
            OmniSegment(false, 'All day'),
            OmniSegment(true, 'Between two times'),
          ],
          selected: window != null,
          onChanged: (on) => onBetween(on ? const ['09:00', '18:00'] : null),
        ),
        if (window != null) ...[
          const SizedBox(height: OmniSpace.sm),
          TimeRow(
            key: const ValueKey('interval-from'),
            label: 'From',
            value: window[0],
            onChanged: (v) => onBetween([v, window[1]]),
          ),
          TimeRow(
            key: const ValueKey('interval-to'),
            label: 'To',
            value: window[1],
            onChanged: (v) => onBetween([window[0], v]),
          ),
        ],
      ],
    );
  }
}
