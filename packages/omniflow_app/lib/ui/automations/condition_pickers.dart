part of 'pickers.dart';

// Conditions.

/// Picks a new condition from the library: Me, Time, Things and
/// Variables, with a search over all of them.
Future<RuleCondition?> pickCondition(BuildContext context, RuleWords words) {
  final things = [
    for (final t in words.things)
      if (!t.isPerson && !t.isTag && t.stateKeys.isNotEmpty) t,
  ];
  const me = 'Me', time = 'Time', inThings = 'Things';
  const variables = 'Variables';
  return showLibrary(
    context,
    title: 'Only if…',
    hint: 'Search devices, places, times',
    categories: const [me, time, inThings, variables],
    choices: [
      if (words.people.isNotEmpty)
        LibraryChoice(
          key: 'pick-presence',
          title: words.me != null
              ? 'I am home or away'
              : 'Someone is home or away',
          icon: OmniIcons.home,
          category: me,
          onTap: _then((c) => presenceConditionForm(c, words)),
        ),
      if (words.people.isNotEmpty)
        LibraryChoice(
          key: 'pick-people',
          title: 'Everyone is away, or anyone is home',
          subtitle: 'everyone in the home, each by their own phone',
          icon: OmniIcons.person,
          category: me,
          keywords: 'everyone family household',
          onTap: _then(peopleConditionForm),
        ),
      LibraryChoice(
        key: 'pick-between',
        title: 'Between two times',
        subtitle: 'across midnight when the first is later',
        icon: OmniIcons.time,
        category: time,
        onTap: _then(betweenForm),
      ),
      LibraryChoice(
        key: 'pick-days',
        title: 'On chosen days',
        icon: AutomationIcons.days,
        category: time,
        onTap: _then(daysForm),
      ),
      for (final t in things)
        LibraryChoice(
          key: 'pick-thing-${t.id}',
          title: t.name,
          subtitle: _statesText(t),
          icon: t.icon,
          category: inThings,
          keywords: t.room ?? '',
          onTap: _then((c) => thingConditionForm(c, t)),
        ),
      LibraryChoice(
        key: 'pick-house-mode',
        title: 'The house mode is',
        subtitle: 'Home, Away, Night, Vacation or your own',
        icon: OmniIcons.home,
        category: me,
        keywords: 'mode away night vacation',
        onTap: _then(modeConditionForm),
      ),
      LibraryChoice(
        key: 'pick-variable',
        title: 'A variable has a value',
        subtitle: 'one an automation set',
        icon: AutomationIcons.variable,
        category: variables,
        onTap: _then(variableForm),
      ),
    ],
  );
}

String _statesText(Thing t) => andList([
  if (t.stateKeys.any((k) => t.isOnOff(k.key))) 'is on or off',
  if (t.numberLabels case final numbers when numbers.isNotEmpty)
    '${orList(numbers)} above or below a number',
  for (final k in t.stateKeys)
    if (!t.isOnOff(k.key) && !t.isNumber(k.key)) k.label.toLowerCase(),
]);

Future<RuleCondition?> editCondition(
  BuildContext context,
  RuleWords words,
  RuleCondition c,
) async {
  switch (c) {
    case CompareCondition(source: 'state'):
      if (isHouseThing(splitRef(c.ref).$1)) {
        return modeConditionForm(context, c);
      }
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
    case PeopleCondition():
      return peopleConditionForm(context, c);
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
        Padding(
          padding: const EdgeInsets.only(top: OmniSpace.sm),
          child: Text(
            'This runs across midnight.',
            style: OmniText.captionOf(context),
          ),
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
      // A days check with none picked checks nothing, so no Every day.
      DayChips(days: days, everyDay: false, onChanged: () => setState(() {})),
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
  // "At least" and "at most" (from an agent or the JSON) have no option of
  // their own, so editing one keeps it instead of making it strict.
  String op(String key, String strict) {
    final kept = current?.op;
    return current != null &&
            splitRef(current.ref).$2 == key &&
            kept == '$strict='
        ? kept!
        : strict;
  }

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
          (v) => CompareCondition(
            'state',
            '${thing.id}.${k.key}',
            op(k.key, '>'),
            v,
          ),
          input: _Input.number,
        ),
        _Option(
          'below-${k.key}',
          '${cap(k.label)} is below',
          (v) => CompareCondition(
            'state',
            '${thing.id}.${k.key}',
            op(k.key, '<'),
            v,
          ),
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
  final sigil = current?.ref.startsWith('%') == true ? '%' : '\$';
  final name = TextEditingController(
    text: current?.ref.replaceFirst(RegExp(r'^[$%]'), '') ?? '',
  );
  final value = TextEditingController(
    text: current == null || current.value is Map
        ? ''
        : valueText(current.value),
  );
  var op = current?.op ?? '==';
  const ops = {
    '==': 'is',
    '!=': 'is not',
    '>': 'above',
    '<': 'below',
    '>=': 'at least',
    '<=': 'at most',
  };
  return showFormSheet(
    context,
    owns: [name, value],
    title: 'A variable has a value',
    result: () =>
        _variable.hasMatch(name.text.trim()) && value.text.trim().isNotEmpty
        ? CompareCondition(
            'var',
            '$sigil${name.text.trim()}',
            op,
            wordValue(value.text),
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
      _KnownVariables(controller: name, onPicked: () => setState(() {})),
      OmniSegmented<String>(
        key: const ValueKey('var-op'),
        segments: [
          for (final MapEntry(key: o, value: label) in ops.entries)
            if (!o.endsWith('=') || o == '==' || o == '!=' || o == op)
              OmniSegment(o, label),
        ],
        selected: op,
        onChanged: (v) => setState(() => op = v),
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
