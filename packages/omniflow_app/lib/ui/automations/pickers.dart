import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show AutomationSummary, Json;
import '../../api/tv_calls.dart';
import '../../rules/rule_spec.dart';
import '../../rules/things.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'form_parts.dart';
import 'rule_words.dart';

/// 2.3: the trigger, condition and step pickers. Each is a page grouped the
/// way a person thinks of it first, and each choice opens a short form in
/// plain words. The page pops with what was built, or null.

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final _variable = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// A searchable picker page: the field, then [sections] of rows whose
/// title or subtitle matches what was typed.
class _PickerPage extends StatefulWidget {
  const _PickerPage({
    required this.title,
    required this.hint,
    required this.sections,
  });

  final String title;
  final String hint;
  final List<(String, List<_Choice>)> sections;

  @override
  State<_PickerPage> createState() => _PickerPageState();
}

class _Choice {
  const _Choice({
    required this.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.warning = false,
  });

  final String key;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Future<void> Function(BuildContext context)? onTap;
  final bool warning;
}

class _PickerPageState extends State<_PickerPage> {
  var _query = '';

  bool _matches(_Choice c) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ||
        c.title.toLowerCase().contains(q) ||
        (c.subtitle?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final (title, choices) in widget.sections)
        (title, choices.where(_matches).toList()),
    ].where((s) => s.$2.isNotEmpty).toList();
    return OmniPage(
      title: widget.title,
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: OmniSpace.gap),
            child: TextField(
              key: const ValueKey('picker-search'),
              decoration: InputDecoration(
                hintText: widget.hint,
                prefixIcon: const Icon(OmniIcons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (shown.isEmpty)
            const OmniEmptyState(
              icon: OmniIcons.search,
              title: 'Nothing matches',
              message: 'Try another word, or clear the search.',
            ),
          for (final (title, choices) in shown) ...[
            OmniSectionHeader(title),
            for (final c in choices)
              OmniListRow(
                key: ValueKey(c.key),
                icon: c.icon,
                title: c.title,
                subtitle: c.subtitle,
                subtitleLines: 2,
                chevron: c.onTap != null,
                iconForeground: c.warning ? OmniColors.warn : null,
                trailing: c.warning
                    ? const Icon(
                        OmniIcons.warning,
                        color: OmniColors.warn,
                        size: 20,
                        semanticLabel: 'High risk',
                      )
                    : null,
                onTap: c.onTap == null ? null : () => c.onTap!(context),
              ),
          ],
          const SizedBox(height: OmniSpace.xl),
        ],
      ),
    );
  }
}

Future<T?> _push<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

/// Runs [form]; when it gives a value, the picker page closes with it.
Future<void> Function(BuildContext) _then<T>(
  Future<T?> Function(BuildContext context) form,
) => (context) async {
  final value = await form(context);
  if (value != null && context.mounted) Navigator.of(context).pop(value);
};

// Triggers.

/// Picks a new trigger. [thingsOnly] leaves out the time triggers, for a
/// wait until.
Future<RuleTrigger?> pickTrigger(
  BuildContext context,
  RuleWords words, {
  bool thingsOnly = false,
}) {
  final things = [
    for (final t in words.things)
      if (!t.isPerson && !t.isPlace && !t.isTag && _reports(t)) t,
  ];
  return _push(
    context,
    _PickerPage(
      title: thingsOnly ? 'Wait until…' : 'When…',
      hint: 'Search devices, places, tags',
      sections: [
        (
          'Me',
          [
            if (words.people.isNotEmpty)
              _Choice(
                key: 'pick-home',
                title: words.me != null
                    ? 'I get home or leave'
                    : 'Someone gets home or leaves',
                subtitle: 'Wi-Fi, Bluetooth or a hub that sees my phone',
                icon: OmniIcons.home,
                onTap: _then((c) => presenceTriggerForm(c, words)),
              ),
            _Choice(
              key: 'pick-tag',
              title: 'An NFC tag is scanned',
              subtitle: words.tags.isEmpty
                  ? 'No tags yet. Add one with Add, then come back'
                  : andList([for (final t in words.tags) t.name]),
              icon: OmniIcons.tag,
              onTap: words.tags.isEmpty
                  ? null
                  : _then((c) => tagTriggerForm(c, words)),
            ),
          ],
        ),
        (
          'Things',
          [
            for (final t in things)
              _Choice(
                key: 'pick-thing-${t.id}',
                title: t.name,
                subtitle: t.reportsText,
                icon: t.icon,
                onTap: _then((c) => thingTriggerForm(c, words, t)),
              ),
          ],
        ),
        if (!thingsOnly)
          (
            'Time',
            [
              _Choice(
                key: 'pick-time',
                title: 'At a time',
                subtitle: 'on chosen days',
                icon: OmniIcons.time,
                onTap: _then((c) => timeTriggerForm(c)),
              ),
              _Choice(
                key: 'pick-interval',
                title: 'Every few minutes',
                icon: OmniIcons.repeat,
                onTap: _then((c) => intervalTriggerForm(c)),
              ),
              _Choice(
                key: 'pick-manual',
                title: 'Only when I run it',
                subtitle: 'from the list, a scene button or another rule',
                icon: OmniIcons.action,
                onTap: (c) async => Navigator.of(c).pop(const ManualTrigger()),
              ),
            ],
          ),
      ],
    ),
  );
}

bool _reports(Thing t) => t.events.isNotEmpty || t.stateKeys.isNotEmpty;

/// Opens the form for [t], to change it in place. A manual trigger has
/// nothing to change.
Future<RuleTrigger?> editTrigger(
  BuildContext context,
  RuleWords words,
  RuleTrigger t,
) async {
  if (t is OnTrigger) {
    final thing = words.thing(t.thing);
    if (thing == null) return null;
    if (thing.isPerson) return presenceTriggerForm(context, words, t);
    if (thing.isTag) return tagTriggerForm(context, words, t);
    return thingTriggerForm(context, words, thing, t);
  }
  return switch (t) {
    TimeTrigger() => timeTriggerForm(context, t),
    IntervalTrigger() => intervalTriggerForm(context, t),
    _ => null,
  };
}

Future<OnTrigger?> presenceTriggerForm(
  BuildContext context,
  RuleWords words, [
  OnTrigger? current,
]) {
  var person = current?.thing ?? words.me ?? words.people.firstOrNull?.id;
  var arriving = !(current?.hasTo == true && current?.to == false);
  return showFormSheet(
    context,
    title: 'When…',
    result: () => person == null
        ? null
        : OnTrigger(thing: person!, key: 'home', to: arriving, hasTo: true),
    build: (context, setState) => [
      if (words.people.length > 1)
        for (final p in words.people)
          ChoiceRow(
            key: ValueKey('person-${p.id}'),
            title: p.name,
            icon: OmniIcons.person,
            selected: p.id == person,
            onTap: () => setState(() => person = p.id),
          ),
      const SizedBox(height: OmniSpace.sm),
      OmniSegmented<bool>(
        segments: [
          OmniSegment(true, person == words.me ? 'I get home' : 'Gets home'),
          OmniSegment(false, person == words.me ? 'I leave' : 'Leaves'),
        ],
        selected: arriving,
        onChanged: (v) => setState(() => arriving = v),
      ),
      const Text(
        'Home is decided by your home Wi-Fi, a Bluetooth beacon, or a hub '
        'that sees your phone.',
        style: OmniText.caption,
      ),
    ],
  );
}

Future<OnTrigger?> tagTriggerForm(
  BuildContext context,
  RuleWords words, [
  OnTrigger? current,
]) {
  var tag = current?.thing ?? words.tags.firstOrNull?.id;
  return showFormSheet(
    context,
    title: 'When this tag is scanned',
    result: () => tag == null
        ? null
        : OnTrigger(thing: tag!, key: 'scanned', mode: OnMode.event),
    build: (context, setState) => [
      for (final t in words.tags)
        ChoiceRow(
          key: ValueKey('tag-${t.id}'),
          title: t.name,
          icon: OmniIcons.tag,
          selected: t.id == tag,
          onTap: () => setState(() => tag = t.id),
        ),
    ],
  );
}

enum _Input { none, number, text }

/// One thing a form can pick: its words, the field it needs, and what it
/// builds from the field's value.
class _Option<T> {
  const _Option(
    this.id,
    this.title,
    this.make, {
    this.input = _Input.none,
    this.choices = const [],
    this.load,
  });

  final String id;
  final String title;
  final _Input input;
  final T Function(Object? input) make;

  /// The values a text input can take, shown as chips instead of a field.
  final List<Object> choices;

  /// A longer list, such as a TV's apps, opened from a row above the field.
  final Future<List<ParamChoice>> Function()? load;
}

/// The options of a thing, the one picked and the field under it.
Future<T?> _optionsForm<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<_Option<T>> options,
  String? selected,
  Object? initialInput,
  String? unit,
  String doneLabel = 'Done',
}) {
  var picked = selected ?? (options.length == 1 ? options.single.id : null);
  final field = TextEditingController(
    text: initialInput == null ? '' : valueText(initialInput),
  );
  Object? input() {
    final option = options.where((o) => o.id == picked).firstOrNull;
    return switch (option?.input) {
      _Input.number => num.tryParse(field.text.trim()),
      _Input.text =>
        field.text.trim().isEmpty ? null : literalFromText(field.text),
      _ => true,
    };
  }

  return showFormSheet<T>(
    context,
    title: title,
    subtitle: subtitle,
    doneLabel: doneLabel,
    whyNot: () {
      final option = options.where((o) => o.id == picked).firstOrNull;
      if (option == null) return options.isEmpty ? null : 'Pick one above';
      return switch (option.input) {
        _Input.number => 'Enter a number',
        _Input.text when option.choices.isNotEmpty => 'Choose a value',
        _Input.text => 'Enter a value',
        _ => null,
      };
    },
    result: () {
      final option = options.where((o) => o.id == picked).firstOrNull;
      final value = input();
      if (option == null || value == null) return null;
      return option.make(value);
    },
    build: (context, setState) {
      final option = options.where((o) => o.id == picked).firstOrNull;
      return [
        if (options.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: OmniSpace.md),
            child: Text(
              'It reports nothing an automation can use yet.',
              style: OmniText.caption,
            ),
          ),
        for (final o in options)
          ChoiceRow(
            key: ValueKey('opt-${o.id}'),
            title: o.input == _Input.none ? o.title : '${o.title}…',
            selected: o.id == picked,
            onTap: () => setState(() => picked = o.id),
          ),
        if (option != null && option.choices.isNotEmpty) ...[
          const SizedBox(height: OmniSpace.md),
          Wrap(
            key: const ValueKey('opt-choices'),
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final v in option.choices)
                OmniFilterChip(
                  key: ValueKey('opt-choice-$v'),
                  label: valueText(v),
                  selected: field.text == valueText(v),
                  onTap: () => setState(() => field.text = valueText(v)),
                ),
            ],
          ),
        ] else if (option != null && option.input != _Input.none) ...[
          if (option.load case final load?) ...[
            const SizedBox(height: OmniSpace.md),
            OmniListRow(
              key: const ValueKey('opt-pick'),
              icon: OmniIcons.search,
              title: 'Choose from the list',
              subtitle: field.text.isEmpty ? null : field.text,
              chevron: true,
              onTap: () async {
                final choice = await showOmniSheet<ParamChoice>(
                  context,
                  builder: (_) => ChoiceSheet(title: option.title, load: load),
                );
                if (choice != null) setState(() => field.text = choice.value);
              },
            ),
          ],
          const SizedBox(height: OmniSpace.md),
          LabelledField(
            key: const ValueKey('opt-input'),
            label: option.title,
            controller: field,
            number: option.input == _Input.number,
            suffix: option.input == _Input.number ? unit : null,
            hint: option.input == _Input.number
                ? '28'
                : 'on, off, 30 or a word',
            autofocus: true,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ];
    },
  );
}

/// "Turns on", "Goes above 28 °C", "Button pressed": what [thing] can report.
Future<OnTrigger?> thingTriggerForm(
  BuildContext context,
  RuleWords words,
  Thing thing, [
  OnTrigger? current,
]) {
  final onOff = [
    for (final k in thing.stateKeys)
      if (thing.isOnOff(k.key)) k,
  ];
  final numbers = [
    for (final k in thing.stateKeys)
      if (!thing.isOnOff(k.key) && thing.isNumber(k.key)) k,
  ];
  final others = [
    for (final k in thing.stateKeys)
      if (!thing.isOnOff(k.key) && !thing.isNumber(k.key)) k,
  ];
  String named(String label, String rest) =>
      '${label[0].toUpperCase()}${label.substring(1)} $rest';
  final options = <_Option<OnTrigger>>[
    for (final e in thing.events)
      _Option(
        'event-${e.key}',
        named(e.label.toLowerCase(), '').trim(),
        (_) => OnTrigger(thing: thing.id, key: e.key, mode: OnMode.event),
      ),
    for (final k in onOff) ...[
      _Option(
        'on-${k.key}',
        onOff.length > 1 ? named(k.label, 'turns on') : 'Turns on',
        (_) => OnTrigger(thing: thing.id, key: k.key, to: true, hasTo: true),
      ),
      _Option(
        'off-${k.key}',
        onOff.length > 1 ? named(k.label, 'turns off') : 'Turns off',
        (_) => OnTrigger(thing: thing.id, key: k.key, to: false, hasTo: true),
      ),
      _Option(
        'onoff-${k.key}',
        onOff.length > 1
            ? named(k.label, 'turns on or off')
            : 'Turns on or off',
        (_) => OnTrigger(thing: thing.id, key: k.key),
      ),
    ],
    for (final k in numbers) ...[
      _Option(
        'above-${k.key}',
        named(k.label, 'goes above'),
        (v) => OnTrigger(
          thing: thing.id,
          key: k.key,
          mode: OnMode.crosses,
          above: v as num,
        ),
        input: _Input.number,
      ),
      _Option(
        'below-${k.key}',
        named(k.label, 'goes below'),
        (v) => OnTrigger(
          thing: thing.id,
          key: k.key,
          mode: OnMode.crosses,
          below: v as num,
        ),
        input: _Input.number,
      ),
    ],
    for (final k in others) ...[
      _Option(
        'change-${k.key}',
        named(k.label, 'changes'),
        (_) => OnTrigger(thing: thing.id, key: k.key),
      ),
      _Option(
        'changeto-${k.key}',
        named(k.label, 'changes to'),
        (v) => OnTrigger(thing: thing.id, key: k.key, to: v, hasTo: true),
        input: _Input.text,
        choices: thing.valuesOf(k.key),
        load: _appsOf(context, thing, k.key),
      ),
    ],
  ];
  final (selected, input) = switch (current) {
    null => (null, null),
    OnTrigger(mode: OnMode.event) => ('event-${current.key}', null),
    OnTrigger(mode: OnMode.crosses, above: final num above) => (
      'above-${current.key}',
      above,
    ),
    OnTrigger(mode: OnMode.crosses) => ('below-${current.key}', current.below),
    _ when onOff.any((k) => k.key == current.key) => (
      current.hasTo
          ? '${current.to == true ? 'on' : 'off'}-${current.key}'
          : 'onoff-${current.key}',
      null,
    ),
    _ => (
      current.hasTo ? 'changeto-${current.key}' : 'change-${current.key}',
      current.hasTo ? current.to : null,
    ),
  };
  final unit = [for (final k in numbers) ?thing.unitOf(k.key)].firstOrNull;
  return _optionsForm(
    context,
    title: 'When ${thing.name}…',
    options: options,
    selected: selected,
    initialInput: input,
    unit: unit,
  );
}

Future<TimeTrigger?> timeTriggerForm(
  BuildContext context, [
  TimeTrigger? current,
]) {
  var at = current?.at ?? '18:00';
  final days = <String>{...?current?.days};
  return showFormSheet(
    context,
    title: 'At a time',
    result: () => _hhmm.hasMatch(at)
        ? TimeTrigger(
            at,
            days: [
              for (final d in weekDays)
                if (days.contains(d)) d,
            ],
          )
        : null,
    build: (context, setState) => [
      TimeRow(
        key: const ValueKey('time-at'),
        label: 'At',
        value: at,
        onChanged: (v) => setState(() => at = v),
      ),
      const SizedBox(height: OmniSpace.md),
      Text(
        'On ${daysText(days.toList()).replaceFirst('on ', '')}',
        style: OmniText.caption,
      ),
      const SizedBox(height: OmniSpace.xs),
      DayChips(days: days, onChanged: () => setState(() {})),
    ],
  );
}

Future<IntervalTrigger?> intervalTriggerForm(
  BuildContext context, [
  IntervalTrigger? current,
]) {
  var ms = (current?.seconds ?? 600) * 1000;
  return showFormSheet(
    context,
    title: 'Every few minutes',
    result: () => ms >= 1000 ? IntervalTrigger(ms ~/ 1000) : null,
    build: (context, setState) => [
      DurationInput(
        label: 'Every',
        ms: ms,
        onChanged: (v) => setState(() => ms = v),
      ),
    ],
  );
}

// Conditions.

Future<RuleCondition?> pickCondition(BuildContext context, RuleWords words) {
  final things = [
    for (final t in words.things)
      if (!t.isPerson && !t.isTag && t.stateKeys.isNotEmpty) t,
  ];
  return _push(
    context,
    _PickerPage(
      title: 'Only if…',
      hint: 'Search devices, places, times',
      sections: [
        if (words.people.isNotEmpty)
          (
            'Me',
            [
              _Choice(
                key: 'pick-presence',
                title: words.me != null
                    ? 'I am home or away'
                    : 'Someone is home or away',
                icon: OmniIcons.home,
                onTap: _then((c) => presenceConditionForm(c, words)),
              ),
            ],
          ),
        (
          'Time',
          [
            _Choice(
              key: 'pick-between',
              title: 'Between two times',
              subtitle: 'across midnight when the first is later',
              icon: OmniIcons.time,
              onTap: _then((c) => betweenForm(c)),
            ),
            _Choice(
              key: 'pick-days',
              title: 'On chosen days',
              icon: AutomationIcons.days,
              onTap: _then((c) => daysForm(c)),
            ),
          ],
        ),
        (
          'Things',
          [
            for (final t in things)
              _Choice(
                key: 'pick-thing-${t.id}',
                title: t.name,
                subtitle: _statesText(t),
                icon: t.icon,
                onTap: _then((c) => thingConditionForm(c, t)),
              ),
          ],
        ),
        (
          'Other',
          [
            _Choice(
              key: 'pick-variable',
              title: 'A variable has a value',
              subtitle: 'one an automation set',
              icon: AutomationIcons.variable,
              onTap: _then((c) => variableForm(c)),
            ),
          ],
        ),
      ],
    ),
  );
}

String _statesText(Thing t) => andList([
  if (t.stateKeys.any((k) => t.isOnOff(k.key))) 'is on or off',
  if (t.stateKeys.any((k) => t.isNumber(k.key))) 'above or below a number',
  if (t.stateKeys.any((k) => !t.isOnOff(k.key) && !t.isNumber(k.key)))
    'has a value',
]);

Future<RuleCondition?> editCondition(
  BuildContext context,
  RuleWords words,
  RuleCondition c,
) async {
  switch (c) {
    case CompareCondition(source: 'state'):
      final thing = words.thing(splitRef(c.ref).$1);
      if (thing == null) return null;
      return thing.isPerson
          ? presenceConditionForm(context, words, c)
          : thingConditionForm(context, thing, c);
    case CompareCondition(source: 'var'):
      return variableForm(context, c);
    case BetweenCondition():
      return betweenForm(context, c);
    case DaysCondition():
      return daysForm(context, c);
    default:
      return null;
  }
}

Future<CompareCondition?> presenceConditionForm(
  BuildContext context,
  RuleWords words, [
  CompareCondition? current,
]) {
  var person =
      (current == null ? null : splitRef(current.ref).$1) ??
      words.me ??
      words.people.firstOrNull?.id;
  var home = current == null || (current.op == '==') == (current.value == true);
  return showFormSheet(
    context,
    title: 'Only if…',
    result: () => person == null
        ? null
        : CompareCondition('state', '$person.home', '==', home),
    build: (context, setState) => [
      if (words.people.length > 1)
        for (final p in words.people)
          ChoiceRow(
            key: ValueKey('person-${p.id}'),
            title: p.name,
            icon: OmniIcons.person,
            selected: p.id == person,
            onTap: () => setState(() => person = p.id),
          ),
      OmniSegmented<bool>(
        segments: [
          OmniSegment(true, person == words.me ? 'I am home' : 'Is home'),
          OmniSegment(false, person == words.me ? 'I am away' : 'Is away'),
        ],
        selected: home,
        onChanged: (v) => setState(() => home = v),
      ),
    ],
  );
}

Future<BetweenCondition?> betweenForm(
  BuildContext context, [
  BetweenCondition? current,
]) {
  var start = current?.start ?? '18:00';
  var end = current?.end ?? '23:30';
  return showFormSheet(
    context,
    title: 'Between two times',
    result: () => _hhmm.hasMatch(start) && _hhmm.hasMatch(end) && start != end
        ? BetweenCondition(start, end)
        : null,
    build: (context, setState) => [
      TimeRow(
        key: const ValueKey('time-from'),
        label: 'From',
        value: start,
        onChanged: (v) => setState(() => start = v),
      ),
      TimeRow(
        key: const ValueKey('time-to'),
        label: 'To',
        value: end,
        onChanged: (v) => setState(() => end = v),
      ),
      if (start.compareTo(end) > 0)
        const Padding(
          padding: EdgeInsets.only(top: OmniSpace.sm),
          child: Text('This runs across midnight.', style: OmniText.caption),
        ),
    ],
  );
}

Future<DaysCondition?> daysForm(
  BuildContext context, [
  DaysCondition? current,
]) {
  final days = <String>{...?current?.days};
  return showFormSheet(
    context,
    title: 'On chosen days',
    result: () => days.isEmpty
        ? null
        : DaysCondition([
            for (final d in weekDays)
              if (days.contains(d)) d,
          ]),
    build: (context, setState) => [
      DayChips(days: days, onChanged: () => setState(() {})),
    ],
  );
}

/// "Is on", "Temperature is above 28", "App is Netflix".
Future<CompareCondition?> thingConditionForm(
  BuildContext context,
  Thing thing, [
  CompareCondition? current,
]) {
  String cap(String s) => '${s[0].toUpperCase()}${s.substring(1)}';
  final keys = thing.stateKeys;
  final many = keys.length > 1;
  final options = <_Option<CompareCondition>>[
    for (final k in keys)
      if (thing.isOnOff(k.key)) ...[
        _Option(
          'on-${k.key}',
          many ? '${cap(k.label)} is on' : 'Is on',
          (_) => CompareCondition('state', '${thing.id}.${k.key}', '==', true),
        ),
        _Option(
          'off-${k.key}',
          many ? '${cap(k.label)} is off' : 'Is off',
          (_) => CompareCondition('state', '${thing.id}.${k.key}', '==', false),
        ),
      ] else if (thing.isNumber(k.key)) ...[
        _Option(
          'above-${k.key}',
          '${cap(k.label)} is above',
          (v) => CompareCondition('state', '${thing.id}.${k.key}', '>', v),
          input: _Input.number,
        ),
        _Option(
          'below-${k.key}',
          '${cap(k.label)} is below',
          (v) => CompareCondition('state', '${thing.id}.${k.key}', '<', v),
          input: _Input.number,
        ),
      ] else ...[
        _Option(
          'is-${k.key}',
          '${cap(k.label)} is',
          (v) => CompareCondition('state', '${thing.id}.${k.key}', '==', v),
          input: _Input.text,
          choices: thing.valuesOf(k.key),
          load: _appsOf(context, thing, k.key),
        ),
        _Option(
          'isnot-${k.key}',
          '${cap(k.label)} is not',
          (v) => CompareCondition('state', '${thing.id}.${k.key}', '!=', v),
          input: _Input.text,
          choices: thing.valuesOf(k.key),
          load: _appsOf(context, thing, k.key),
        ),
      ],
  ];
  String? selected;
  Object? input;
  if (current != null) {
    final key = splitRef(current.ref).$2;
    if (thing.isOnOff(key) && current.value is bool) {
      selected =
          '${(current.op == '==') == (current.value == true) ? 'on' : 'off'}-$key';
    } else if (current.op == '>' || current.op == '>=') {
      (selected, input) = ('above-$key', current.value);
    } else if (current.op == '<' || current.op == '<=') {
      (selected, input) = ('below-$key', current.value);
    } else if (current.op == '!=') {
      (selected, input) = ('isnot-$key', current.value);
    } else {
      (selected, input) = ('is-$key', current.value);
    }
  }
  return _optionsForm(
    context,
    title: 'Only if ${thing.name}…',
    options: options,
    selected: selected,
    initialInput: input,
    unit: [for (final k in keys) ?thing.unitOf(k.key)].firstOrNull,
  );
}

Future<CompareCondition?> variableForm(
  BuildContext context, [
  CompareCondition? current,
]) {
  final name = TextEditingController(
    text: current?.ref.replaceFirst(r'$', '') ?? '',
  );
  final value = TextEditingController(
    text: current == null || current.value is Map
        ? ''
        : valueText(current.value),
  );
  var negate = current?.op == '!=';
  return showFormSheet(
    context,
    title: 'A variable has a value',
    result: () =>
        _variable.hasMatch(name.text.trim()) && value.text.trim().isNotEmpty
        ? CompareCondition(
            'var',
            '\$${name.text.trim()}',
            negate ? '!=' : '==',
            _wordValue(value.text),
          )
        : null,
    build: (context, setState) => [
      LabelledField(
        key: const ValueKey('var-name'),
        label: 'Variable',
        hint: 'Away',
        controller: name,
        onChanged: (_) => setState(() {}),
      ),
      OmniSegmented<bool>(
        segments: const [OmniSegment(false, 'is'), OmniSegment(true, 'is not')],
        selected: negate,
        onChanged: (v) => setState(() => negate = v),
      ),
      LabelledField(
        key: const ValueKey('var-value'),
        label: 'Value',
        hint: 'on, off, 30 or a word',
        controller: value,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// What a person types as a value: on/off and yes/no are booleans.
Object? _wordValue(String text) => switch (text.trim().toLowerCase()) {
  'on' || 'yes' => true,
  'off' || 'no' => false,
  _ => literalFromText(text),
};

// Steps.

/// Picks a new step. [allowKeep] offers the keep step, which only goes at
/// the end of a rule's own THEN. [automations] are what a run step can
/// start.
Future<RuleStep?> pickStep(
  BuildContext context,
  RuleWords words, {
  required List<AutomationSummary> automations,
  bool allowKeep = false,
}) {
  final devices = [
    for (final t in words.things)
      if (t.actions.isNotEmpty) t,
  ];
  return _push(
    context,
    _PickerPage(
      title: 'Then…',
      hint: 'Search devices and steps',
      sections: [
        (
          'Do something on a device',
          [
            for (final t in devices)
              _Choice(
                key: 'pick-device-${t.id}',
                title: t.name,
                subtitle: t.hasHighRisk
                    ? '${t.actionsText}. Some steps run commands on it: Claude '
                          'needs your approval to use them'
                    : t.actionsText,
                icon: t.icon,
                warning: t.hasHighRisk,
                onTap: _then((c) => actionForm(c, t)),
              ),
          ],
        ),
        (
          'Wait',
          [
            _Choice(
              key: 'pick-wait',
              title: 'Wait',
              subtitle: 'a few seconds or minutes',
              icon: OmniIcons.wait,
              onTap: _then((c) => waitForm(c)),
            ),
            _Choice(
              key: 'pick-wait-until',
              title: 'Wait until something happens',
              subtitle: 'with a time limit and what to do then',
              icon: AutomationIcons.waitUntil,
              onTap: _then((c) => waitUntilForm(c, words)),
            ),
          ],
        ),
        (
          'Choose and group',
          [
            _Choice(
              key: 'pick-if',
              title: 'If… otherwise',
              subtitle: 'do different steps depending on a check',
              icon: OmniIcons.branch,
              onTap: (c) async => Navigator.of(c).pop(IfStep()),
            ),
            _Choice(
              key: 'pick-try',
              title: 'Try, with a fallback',
              subtitle:
                  'if a step fails, like an app that is not installed, '
                  'do something else',
              icon: AutomationIcons.fallback,
              onTap: (c) async => Navigator.of(c).pop(TryStep()),
            ),
            _Choice(
              key: 'pick-repeat',
              title: 'Repeat',
              subtitle:
                  'again and again until something holds, like until '
                  'the TV is on',
              icon: AutomationIcons.repeat,
              onTap: (c) async => Navigator.of(c).pop(RepeatStep()),
            ),
            _Choice(
              key: 'pick-together',
              title: 'Do these together',
              subtitle: 'run two or more lists of steps at once',
              icon: AutomationIcons.together,
              onTap: (c) async => Navigator.of(c).pop(TogetherStep()),
            ),
            if (allowKeep)
              _Choice(
                key: 'pick-keep',
                title: 'Keep a value while something holds',
                subtitle: 'like keep the fan on while it is hot',
                icon: AutomationIcons.keep,
                onTap: (c) async => Navigator.of(c).pop(KeepStep('', '')),
              ),
          ],
        ),
        (
          'More',
          [
            _Choice(
              key: 'pick-notify',
              title: 'Notify me',
              icon: OmniIcons.notifications,
              onTap: _then((c) => notifyForm(c)),
            ),
            _Choice(
              key: 'pick-set',
              title: 'Set a variable',
              subtitle: 'for another automation to check',
              icon: AutomationIcons.variable,
              onTap: _then((c) => setVariableForm(c)),
            ),
            _Choice(
              key: 'pick-run',
              title: 'Run another automation',
              icon: OmniIcons.automations,
              onTap: automations.isEmpty
                  ? null
                  : _then((c) => runForm(c, automations)),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Opens the form of a simple step to change it. Groups and keeps open
/// their own pages instead, so they return null here.
Future<RuleStep?> editStep(
  BuildContext context,
  RuleWords words,
  RuleStep step, {
  required List<AutomationSummary> automations,
}) async => switch (step) {
  DoStep(:final thing) || ToggleStep(:final thing) => switch (words.thing(
    thing,
  )) {
    final t? => actionForm(context, t, step),
    null => null,
  },
  WaitStep() => waitForm(context, step),
  NotifyStep() => notifyForm(context, step),
  SetStep() => setVariableForm(context, step),
  RunStep() => runForm(context, automations, step),
  _ => null,
};

/// Picks one of [thing]'s actions and fills in its params. A switch offers
/// turn on, turn off and toggle.
Future<RuleStep?> actionForm(
  BuildContext context,
  Thing thing, [
  RuleStep? current,
  bool allowToggle = true,
]) {
  final toggles = thing.actions.where((c) => c['type'] == 'toggle').toList();
  final others = thing.actions.where((c) => c['type'] != 'toggle').toList();
  String low(Object? s) => '$s'.toLowerCase();
  final many = toggles.length > 1;
  var picked = switch (current) {
    DoStep(:final capability, :final params)
        when toggles.any((c) => c['id'] == capability) &&
            params.length == 1 &&
            params['value'] is bool =>
      '${params['value'] == true ? 'on' : 'off'}-$capability',
    DoStep(:final capability) => 'do-$capability',
    ToggleStep(:final capability) => 'toggle-$capability',
    _ => null,
  };
  final values = <String, Object?>{
    if (current is DoStep && picked == 'do-${current.capability}')
      ...current.params,
  };
  Json? capOf(String? choice) {
    if (choice == null || !choice.startsWith('do-')) return null;
    return thing.capability(choice.substring(3));
  }

  Map<String, Json> paramsOf(Json cap) => {
    for (final e in (cap['params'] as Map? ?? const {}).entries)
      '${e.key}': Map<String, Object?>.from(e.value as Map),
  };

  return showFormSheet<RuleStep>(
    context,
    title: thing.name,
    subtitle: 'What should it do?',
    result: () {
      final choice = picked;
      if (choice == null) return null;
      final dash = choice.indexOf('-');
      final kind = choice.substring(0, dash);
      final id = choice.substring(dash + 1);
      switch (kind) {
        case 'on' || 'off':
          return DoStep(thing.id, id, params: {'value': kind == 'on'});
        case 'toggle':
          return ToggleStep(thing.id, id);
      }
      final cap = capOf(choice);
      if (cap == null) return null;
      final params = ParamControls.complete(paramsOf(cap), values);
      return params == null ? null : DoStep(thing.id, id, params: params);
    },
    build: (context, setState) {
      final cap = capOf(picked);
      return [
        for (final c in toggles) ...[
          ChoiceRow(
            key: ValueKey('act-on-${c['id']}'),
            title: many ? 'Turn ${low(c['label'])} on' : 'Turn on',
            icon: OmniIcons.power,
            selected: picked == 'on-${c['id']}',
            onTap: () => setState(() => picked = 'on-${c['id']}'),
          ),
          ChoiceRow(
            key: ValueKey('act-off-${c['id']}'),
            title: many ? 'Turn ${low(c['label'])} off' : 'Turn off',
            icon: OmniIcons.power,
            selected: picked == 'off-${c['id']}',
            onTap: () => setState(() => picked = 'off-${c['id']}'),
          ),
          if (allowToggle && c['stateKey'] != null)
            ChoiceRow(
              key: ValueKey('act-toggle-${c['id']}'),
              title: many ? 'Toggle ${low(c['label'])}' : 'Toggle',
              subtitle: 'on when it is off, off when it is on',
              icon: OmniIcons.power,
              selected: picked == 'toggle-${c['id']}',
              onTap: () => setState(() => picked = 'toggle-${c['id']}'),
            ),
        ],
        for (final c in others)
          ChoiceRow(
            key: ValueKey('act-${c['id']}'),
            title: '${c['label'] ?? c['id']}',
            subtitle: isHighRisk(c)
                ? 'High risk: runs commands on ${thing.name}. Claude needs '
                      'your approval before an automation it makes can do this'
                : null,
            icon: OmniIcons.forCapability(c['type'] as String?),
            warning: isHighRisk(c),
            selected: picked == 'do-${c['id']}',
            onTap: () => setState(() {
              if (picked != 'do-${c['id']}') {
                values.clear();
                ParamControls.seed(paramsOf(c), values);
              }
              picked = 'do-${c['id']}';
            }),
          ),
        if (cap != null && paramsOf(cap).isNotEmpty) ...[
          const SizedBox(height: OmniSpace.md),
          ParamControls(
            key: ValueKey('params-${cap['id']}'),
            params: paramsOf(cap),
            values: values,
            onChanged: () => setState(() {}),
            choices: {
              if (thing.driver == TvCalls.driver)
                'package': () => tvAppChoices(context, thing.id),
            },
          ),
        ],
      ];
    },
  );
}

/// The TV's apps for its "app on screen" state, so it is picked by name.
Future<List<ParamChoice>> Function()? _appsOf(
  BuildContext context,
  Thing thing,
  String key,
) => thing.driver == TvCalls.driver && key == 'app'
    ? () => tvAppChoices(context, thing.id)
    : null;

/// The apps a TV can open, by name, for a launch step's package.
Future<List<ParamChoice>> tvAppChoices(BuildContext context, String tv) async {
  final client = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(engineClientProvider);
  final result = await client.call(
    TvCalls.apps,
    TvCalls.appsArgs(tv, AppFilter.all),
  );
  if (result['ok'] != true) throw errorMessage(result);
  final apps = [
    for (final a in TvCalls.appsOf(result))
      if (a.launchable && a.enabled)
        (value: a.package, label: a.label ?? a.package),
  ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return apps;
}

/// How many times [step] runs and the wait between passes. Returns
/// whether anything changed.
Future<bool> repeatForm(BuildContext context, RepeatStep step) async {
  var times = step.times;
  var every = step.everyMs;
  final count = TextEditingController(text: times == null ? '' : '$times');
  final done = await showFormSheet<bool>(
    context,
    title: 'How often',
    subtitle:
        'It stops at the first of these: the most passes, or what you put '
        'under Stop when.',
    result: () =>
        (times == null || (times! >= 1 && times! <= 1000)) && every >= 0
        ? true
        : null,
    whyNot: () => every < 0
        ? 'Wait a whole number of seconds, minutes or hours'
        : 'Use a number from 1 to 1000, or leave it empty',
    build: (context, setState) => [
      LabelledField(
        key: const ValueKey('repeat-times'),
        label: 'At most this many times (empty for no limit)',
        controller: count,
        number: true,
        onChanged: (t) => setState(
          () => times = t.trim().isEmpty ? null : int.tryParse(t.trim()) ?? 0,
        ),
      ),
      DurationInput(
        label: 'Wait between passes',
        ms: every,
        onChanged: (v) => setState(() => every = v),
      ),
    ],
  );
  if (done != true) return false;
  step
    ..times = times
    ..everyMs = every;
  return true;
}

Future<WaitStep?> waitForm(BuildContext context, [WaitStep? current]) {
  var ms = current?.ms ?? 3000;
  return showFormSheet(
    context,
    title: 'Wait',
    result: () => ms >= 0 ? WaitStep(ms) : null,
    build: (context, setState) => [
      DurationInput(
        label: 'Wait for',
        ms: ms,
        onChanged: (v) => setState(() => ms = v),
      ),
    ],
  );
}

/// Picks what to wait for, then how long at most.
Future<WaitForStep?> waitUntilForm(
  BuildContext context,
  RuleWords words, [
  WaitForStep? current,
]) async {
  final until = current == null
      ? await pickTrigger(context, words, thingsOnly: true)
      : await editTrigger(context, words, current.until) ?? current.until;
  if (until is! OnTrigger || !context.mounted) return null;
  return waitTimeoutForm(context, until, current);
}

Future<WaitForStep?> waitTimeoutForm(
  BuildContext context,
  OnTrigger until, [
  WaitForStep? current,
]) {
  var ms = current?.timeoutMs ?? 60000;
  return showFormSheet(
    context,
    title: 'Give up after',
    subtitle:
        'If it has not happened by then, the rule runs what you put '
        'under "If the time runs out", then stops.',
    result: () => ms >= 1000
        ? WaitForStep(until, timeoutMs: ms, onTimeout: current?.onTimeout)
        : null,
    build: (context, setState) => [
      DurationInput(
        label: 'At most',
        ms: ms,
        onChanged: (v) => setState(() => ms = v),
      ),
    ],
  );
}

Future<NotifyStep?> notifyForm(BuildContext context, [NotifyStep? current]) {
  final title = TextEditingController(text: current?.title ?? '');
  final body = TextEditingController(text: current?.body ?? '');
  return showFormSheet(
    context,
    title: 'Notify me',
    subtitle:
        'Shows as a notification on this phone, even with the screen off.',
    result: () => title.text.trim().isEmpty
        ? null
        : NotifyStep(
            title.text.trim(),
            body: body.text.trim().isEmpty ? null : body.text.trim(),
            extra: current?.extra,
          ),
    build: (context, setState) => [
      LabelledField(
        key: const ValueKey('notify-title'),
        label: 'Title',
        hint: 'Welcome home',
        controller: title,
        onChanged: (_) => setState(() {}),
      ),
      LabelledField(
        key: const ValueKey('notify-body'),
        label: 'Text (optional)',
        controller: body,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

Future<SetStep?> setVariableForm(BuildContext context, [SetStep? current]) {
  final name = TextEditingController(
    text: current?.name.replaceFirst(RegExp(r'^[$%]'), '') ?? '',
  );
  final value = TextEditingController(
    text: current == null ? '' : valueText(current.value),
  );
  return showFormSheet(
    context,
    title: 'Set a variable',
    result: () => _variable.hasMatch(name.text.trim())
        ? SetStep('\$${name.text.trim()}', _wordValue(value.text))
        : null,
    build: (context, setState) => [
      LabelledField(
        key: const ValueKey('set-name'),
        label: 'Variable',
        hint: 'Away',
        controller: name,
        error: name.text.trim().isEmpty || _variable.hasMatch(name.text.trim())
            ? null
            : 'Letters, numbers and _ only',
        onChanged: (_) => setState(() {}),
      ),
      LabelledField(
        key: const ValueKey('set-value'),
        label: 'Value',
        hint: 'on, off, 30 or a word',
        controller: value,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

Future<RunStep?> runForm(
  BuildContext context,
  List<AutomationSummary> automations, [
  RunStep? current,
]) {
  var id = current?.automationId;
  return showFormSheet(
    context,
    title: 'Run another automation',
    result: () => id == null ? null : RunStep(id!),
    build: (context, setState) => [
      for (final a in automations)
        ChoiceRow(
          key: ValueKey('run-${a.id}'),
          title: a.name,
          icon: OmniIcons.automations,
          selected: a.id == id,
          onTap: () => setState(() => id = a.id),
        ),
    ],
  );
}

/// What a keep step holds: [thing]'s switch on or off, or a level at a
/// number.
Future<KeepStep?> keepTargetForm(
  BuildContext context,
  Thing thing,
  KeepStep keep,
) {
  final targets = [
    for (final c in thing.actions)
      if (c['type'] == 'toggle' || (c['params'] as Map?)?['value'] is Map) c,
  ];
  final options = <_Option<KeepStep>>[
    for (final c in targets)
      if (c['type'] == 'toggle') ...[
        _Option(
          'on-${c['id']}',
          targets.length > 1
              ? 'Keep ${'${c['label']}'.toLowerCase()} on'
              : 'Keep it on',
          (_) => _keepWith(keep, thing.id, '${c['id']}', true),
        ),
        _Option(
          'off-${c['id']}',
          targets.length > 1
              ? 'Keep ${'${c['label']}'.toLowerCase()} off'
              : 'Keep it off',
          (_) => _keepWith(keep, thing.id, '${c['id']}', false),
        ),
      ] else
        _Option(
          'at-${c['id']}',
          'Keep ${'${c['label']}'.toLowerCase()} at',
          (v) => _keepWith(keep, thing.id, '${c['id']}', v),
          input: _Input.number,
        ),
  ];
  final same = keep.thing == thing.id;
  return _optionsForm(
    context,
    title: thing.name,
    subtitle: 'What should it keep?',
    options: options,
    selected: !same
        ? null
        : keep.value is bool
        ? '${keep.value == true ? 'on' : 'off'}-${keep.capability}'
        : 'at-${keep.capability}',
    initialInput: same && keep.value is num ? keep.value : null,
  );
}

KeepStep _keepWith(KeepStep keep, String thing, String capability, Object? v) =>
    KeepStep(
      thing,
      capability,
      value: v,
      whileConditions: keep.whileConditions,
      release: keep.release,
      hasRelease: keep.hasRelease && keep.value is! bool,
    );

/// Any device that takes commands, as a picker (a scene's actions).
Future<Thing?> pickDevice(
  BuildContext context,
  RuleWords words, {
  String title = 'Add an action',
}) => _push(
  context,
  _PickerPage(
    title: title,
    hint: 'Search devices',
    sections: [
      (
        'Devices',
        [
          for (final t in words.things)
            if (t.actions.isNotEmpty)
              _Choice(
                key: 'pick-device-${t.id}',
                title: t.name,
                subtitle: t.actionsText,
                icon: t.icon,
                warning: t.hasHighRisk,
                onTap: (c) async => Navigator.of(c).pop(t),
              ),
        ],
      ),
    ],
  ),
);

/// The devices a keep step can hold, as a picker.
Future<Thing?> pickKeepThing(BuildContext context, RuleWords words) => _push(
  context,
  _PickerPage(
    title: 'Keep…',
    hint: 'Search devices',
    sections: [
      (
        'Devices',
        [
          for (final t in words.things)
            if (t.actions.any(
              (c) =>
                  c['type'] == 'toggle' ||
                  (c['params'] as Map?)?['value'] is Map,
            ))
              _Choice(
                key: 'pick-keep-${t.id}',
                title: t.name,
                subtitle: t.actionsText,
                icon: t.icon,
                onTap: (c) async => Navigator.of(c).pop(t),
              ),
        ],
      ),
    ],
  ),
);
