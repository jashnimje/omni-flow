part of 'pickers.dart';

/// Opens the form of a simple step to change it. Groups and keeps open
/// their own pages instead, so they return null here.
Future<RuleStep?> editStep(
  BuildContext context,
  RuleWords words,
  RuleStep step, {
  required List<AutomationSummary> automations,
  TokenSource? tokens,
}) async => switch (step) {
  DoStep() when isHouseThing(step.thing) => editHouseStep(context, step),
  DoStep(:final thing) || ToggleStep(:final thing) => switch (words.thing(
    thing,
  )) {
    final t? => actionForm(context, t, step),
    null => null,
  },
  WaitStep() => waitForm(context, step),
  NotifyStep() => notifyForm(context, step, tokens),
  HttpStep() => httpForm(context, step, tokens),
  SetStep() => setVariableForm(context, step, tokens),
  RunStep() => runForm(context, automations, step),
  AskStep() => askForm(context, current: step, tokens: tokens),
  GetStep() => getValueForm(context, current: step, tokens: tokens),
  TextStep() => textForm(context, current: step, tokens: tokens),
  MathStep() => mathForm(context, current: step, tokens: tokens),
  DateStep() => dateForm(context, step),
  ForEachStep() => forEachForm(context, words, current: step, tokens: tokens),
  _ => null,
};

/// The step that edits one [blank] of [step] on its own: the device, what
/// it does, how long, the text. Null when [step] has no form for it; the
/// row then opens the step's whole form.
Future<RuleStep?> editBlank(
  BuildContext context,
  RuleWords words,
  RuleStep step,
  Blank blank, {
  required List<AutomationSummary> automations,
  TokenSource? tokens,
}) async {
  switch ((step, blank)) {
    case (DoStep(:final thing) || ToggleStep(:final thing), Blank.device):
      final picked = await pickDevice(context, words, title: 'Which device?');
      if (picked == null || !context.mounted) return null;
      // The same action on another device keeps its params when it has it.
      final same = switch (step) {
        DoStep(:final capability) => picked.capability(capability) != null,
        ToggleStep(:final capability) => picked.capability(capability) != null,
        _ => false,
      };
      if (picked.id == thing) return null;
      if (same) {
        return switch (step) {
          DoStep() => DoStep(
            picked.id,
            step.capability,
            params: step.params,
            extra: step.extra,
          ),
          ToggleStep() => ToggleStep(picked.id, step.capability),
          _ => null,
        };
      }
      return actionForm(context, picked);
    case (NotifyStep(), Blank.title):
      return notifyForm(context, step as NotifyStep, tokens);
    case (WaitStep(), Blank.duration):
      return waitForm(context, step as WaitStep);
    default:
      return editStep(
        context,
        words,
        step,
        automations: automations,
        tokens: tokens,
      );
  }
}

/// Picks one of [thing]'s actions and fills in its params. A switch offers
/// turn on, turn off and toggle.
Future<RuleStep?> actionForm(
  BuildContext context,
  Thing thing, [
  RuleStep? current,
  bool allowToggle = true,
]) {
  final toggles = thing.actions.where((c) => c['type'] == 'toggle').toList();
  // The d-pad is a control on the device page, not a step: a rule presses
  // a key with "Press a remote key".
  final others = thing.actions
      .where((c) => c['type'] != 'toggle' && c['type'] != 'dpad_remote')
      .toList();
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
      return params == null
          ? null
          : DoStep(
              thing.id,
              id,
              params: params,
              extra: current is DoStep ? current.extra : null,
            );
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
        for (final c in others) ...[
          ChoiceRow(
            key: ValueKey('act-${c['id']}'),
            title: '${c['label'] ?? c['id']}',
            subtitle: isHighRisk(c)
                ? 'High risk: runs commands on ${thing.name}. An automation an '
                      'agent makes needs your approval before it can do this'
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
          // Its fields right under it, not after every other choice.
          if (cap != null &&
              cap['id'] == c['id'] &&
              paramsOf(cap).isNotEmpty) ...[
            const SizedBox(height: OmniSpace.sm),
            ParamControls(
              key: ValueKey('params-${cap['id']}'),
              params: paramsOf(cap),
              values: values,
              onChanged: () => setState(() {}),
              choices: {
                if (thing.driver == TvCalls.driver)
                  'package': () => tvAppChoices(context, thing.id),
                if (thing.isPhone) 'package': phoneAppChoices,
              },
            ),
            const SizedBox(height: OmniSpace.md),
          ],
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
    owns: [count],
    title: 'How often',
    subtitle:
        'It stops at the first of these: the most passes, or what you put '
        'under Stop when.',
    result: () =>
        (times == null
                ? step.until.isNotEmpty
                : times! >= 1 && times! <= 1000) &&
            every >= 0
        ? true
        : null,
    whyNot: () => every < 0
        ? 'Wait a whole number of seconds, minutes or hours'
        : times == null
        ? 'With no limit it needs a Stop when check, or it would never end'
        : 'Use a number from 1 to 1000',
    build: (context, setState) => [
      LabelledField(
        key: const ValueKey('repeat-times'),
        label: 'At most this many times (empty: up to 100, until it stops)',
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
        'If it has not happened by then, the automation runs what you put '
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

/// A web request: where, how, and what to send. Values from earlier steps
/// go in as tokens (`{{%answer}}`), shared variables as `{{$Name}}`.
Future<HttpStep?> httpForm(
  BuildContext context, [
  HttpStep? current,
  TokenSource? tokens,
]) {
  final url = TokenController(text: current?.url ?? 'https://');
  final body = TokenController(
    text: switch (current?.body) {
      null => '',
      final String s => s,
      final other => jsonEncode(other),
    },
  );
  var method = current?.method ?? 'GET';
  final headers = WebHeadersController(current?.extra['headers']);
  bool ok() {
    final t = url.text.trim();
    if (t.startsWith('{{')) return true;
    final u = Uri.tryParse(t);
    return u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
  }

  Object? bodyValue() {
    final t = body.text.trim();
    if (t.isEmpty) return null;
    try {
      return jsonDecode(t);
    } on FormatException {
      return t;
    }
  }

  return showFormSheet(
    context,
    owns: [url, body, headers],
    title: 'Send a web request',
    subtitle:
        'It counts as done when the address answers, and fails on an error '
        'reply, so a fallback can take over. Its reply goes into Web reply.',
    result: () => ok() && headers.whyNot == null
        ? HttpStep(
            url.text.trim(),
            method: method,
            body: method == 'GET' ? null : bodyValue(),
            extra: {...?current?.extra, 'headers': headers.headers}
              ..removeWhere((k, v) => k == 'headers' && v == null),
          )
        : null,
    whyNot: () => ok() ? headers.whyNot : 'Give an http:// or https:// address',
    build: (context, setState) => [
      TokenField(
        key: const ValueKey('http-url'),
        id: 'http-url',
        label: 'Address',
        hint: 'http://192.168.1.20:8123/api/webhook/home',
        controller: url,
        source: tokens,
        kinds: const {'text'},
        onChanged: (_) => setState(() {}),
      ),
      OmniSegmented<String>(
        key: const ValueKey('http-method'),
        segments: const [
          OmniSegment('GET', 'Get'),
          OmniSegment('POST', 'Post'),
          OmniSegment('PUT', 'Put'),
          OmniSegment('DELETE', 'Delete'),
        ],
        selected: method,
        onChanged: (v) => setState(() => method = v),
      ),
      if (method != 'GET') ...[
        const SizedBox(height: OmniSpace.sm),
        TokenField(
          key: const ValueKey('http-body'),
          id: 'http-body',
          label: 'What to send (optional)',
          hint: r'{"mood": "{{$Mood}}"}',
          controller: body,
          source: tokens,
          onChanged: (_) => setState(() {}),
        ),
      ],
      WebHeadersEditor(controller: headers, onChanged: () => setState(() {})),
      const SizedBox(height: OmniSpace.xs),
      const Text(
        'A web request is high risk: when an agent makes an automation with '
        'one, it waits for your approval.',
        style: OmniText.caption,
      ),
    ],
  );
}

Future<NotifyStep?> notifyForm(
  BuildContext context, [
  NotifyStep? current,
  TokenSource? tokens,
]) {
  final title = TokenController(text: current?.title ?? '');
  final body = TokenController(text: current?.body ?? '');
  return showFormSheet(
    context,
    owns: [title, body],
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
      TokenField(
        key: const ValueKey('notify-title'),
        id: 'notify-title',
        label: 'Title',
        hint: 'Welcome home',
        controller: title,
        source: tokens,
        onChanged: (_) => setState(() {}),
      ),
      TokenField(
        key: const ValueKey('notify-body'),
        id: 'notify-body',
        label: 'Text (optional)',
        controller: body,
        source: tokens,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

Future<SetStep?> setVariableForm(
  BuildContext context, [
  SetStep? current,
  TokenSource? tokens,
]) {
  // A run's own variable (%) stays one; a new one is shared.
  final sigil = current?.name.startsWith('%') == true ? '%' : '\$';
  final name = TextEditingController(
    text: current?.name.replaceFirst(RegExp(r'^[$%]'), '') ?? '',
  );
  final value = TokenController(
    text: current == null ? '' : valueText(current.value),
  );
  return showFormSheet(
    context,
    owns: [name, value],
    title: 'Set a variable',
    result: () => _variable.hasMatch(name.text.trim())
        ? SetStep('$sigil${name.text.trim()}', wordValue(value.text))
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
      _KnownVariables(controller: name, onPicked: () => setState(() {})),
      TokenField(
        key: const ValueKey('set-value'),
        id: 'set-value',
        label: 'Value',
        hint: 'on, off, 30 or a word',
        controller: value,
        source: tokens,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// The run variable a step's value goes into, as a name field: `answer`
/// for `%answer`. Empty takes the step's default.
class _StoreAs {
  _StoreAs(String kind, String? current)
    : _default = defaultAs[kind]!,
      controller = TextEditingController(
        text: (current ?? defaultAs[kind]!).replaceFirst(RegExp(r'^[%$]'), ''),
      );

  final String _default;
  final TextEditingController controller;

  bool get ok {
    final t = controller.text.trim();
    return t.isEmpty || _variable.hasMatch(t);
  }

  /// The `as` to save: null for the default, so the step stays short.
  String? get value {
    final t = controller.text.trim();
    final full = t.isEmpty ? _default : '%$t';
    return full == _default ? null : full;
  }

  /// A spec keeps an `as` it came with even when it is the default.
  String? keep(String? current) => value ?? (current == null ? null : _default);

  Widget field(StateSetter setState, String id) => LabelledField(
    key: ValueKey('$id-as'),
    label: 'Keep it as',
    hint: _default.substring(1),
    controller: controller,
    error: ok ? null : 'Letters, numbers and _ only',
    onChanged: (_) => setState(() {}),
  );
}

/// Choose from a menu, or ask for text: the run waits for the answer
/// from a notification, at most [AskStep.timeoutMs], then takes the
/// default. The answer goes into %answer for the next steps.
Future<AskStep?> askForm(
  BuildContext context, {
  AskStep? current,
  TokenSource? tokens,
  bool typed = false,
}) {
  var text = current?.asksForText ?? typed;
  final title = TokenController(text: current?.title ?? '');
  final body = TokenController(text: current?.body ?? '');
  final owns = <ChangeNotifier>[title, body];
  final choices = <TextEditingController>[
    for (final c in current?.choices ?? const ['', ''])
      TextEditingController(text: c),
  ];
  owns.addAll(choices);
  var defaultChoice = current?.defaultAnswer;
  final typedDefault = TextEditingController(
    text: text ? current?.defaultAnswer ?? '' : '',
  );
  final minutes = TextEditingController(
    text: '${((current?.timeoutMs ?? 300000) / 60000).round()}',
  );
  final store = _StoreAs('ask', current?.as);
  owns.addAll([typedDefault, minutes, store.controller]);
  List<String> filled() => [
    for (final c in choices)
      if (c.text.trim().isNotEmpty) c.text.trim(),
  ];
  int? timeout() {
    final m = int.tryParse(minutes.text.trim());
    return m == null || m < 1 || m > 1440 ? null : m * 60000;
  }

  return showFormSheet<AskStep>(
    context,
    owns: owns,
    title: text ? 'Ask for text' : 'Choose from a menu',
    subtitle:
        'It asks from a notification, even with the screen off, and waits '
        'for the answer.',
    whyNot: () => title.text.trim().isEmpty
        ? 'Write what to ask'
        : !text && filled().length < 2
        ? 'Give at least two choices'
        : !text && filled().length > 10
        ? 'Give at most ten choices'
        : timeout() == null
        ? 'Wait 1 to 1440 minutes'
        : !store.ok
        ? 'Name it with letters, numbers and _'
        : null,
    result: () {
      final ms = timeout();
      final options = filled();
      if (title.text.trim().isEmpty || ms == null || !store.ok) return null;
      if (!text && (options.length < 2 || options.length > 10)) return null;
      final fallback = text
          ? typedDefault.text.trim()
          : options.contains(defaultChoice)
          ? defaultChoice!
          : '';
      return AskStep(
        title.text.trim(),
        body: body.text.trim().isEmpty ? null : body.text.trim(),
        choices: text ? null : options,
        input: text ? true : (current?.input == null ? null : false),
        defaultAnswer: fallback.isEmpty ? null : fallback,
        timeoutMs: ms == 300000 && current?.timeoutMs == null ? null : ms,
        as: store.keep(current?.as),
        extra: current?.extra,
      );
    },
    build: (context, setState) => [
      OmniSegmented<bool>(
        key: const ValueKey('ask-kind'),
        segments: const [
          OmniSegment(false, 'Choose from a menu'),
          OmniSegment(true, 'Ask for text'),
        ],
        selected: text,
        onChanged: (v) => setState(() => text = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      TokenField(
        key: const ValueKey('ask-title'),
        id: 'ask-title',
        label: 'Ask',
        hint: 'Which app?',
        controller: title,
        source: tokens,
        onChanged: (_) => setState(() {}),
      ),
      TokenField(
        key: const ValueKey('ask-body'),
        id: 'ask-body',
        label: 'More words (optional)',
        controller: body,
        source: tokens,
        onChanged: (_) => setState(() {}),
      ),
      if (!text) ...[
        const Text('Choices', style: OmniText.caption),
        for (final (i, c) in choices.indexed)
          Row(
            key: ValueKey('ask-choice-row-$i'),
            children: [
              Expanded(
                child: LabelledField(
                  key: ValueKey('ask-choice-$i'),
                  label: 'Choice ${i + 1}',
                  controller: c,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (choices.length > 2)
                OmniIconAction(
                  key: ValueKey('ask-remove-$i'),
                  icon: OmniIcons.close,
                  label: 'Remove choice ${i + 1}',
                  onPressed: () => setState(() => choices.removeAt(i)),
                ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OmniButton.ghost(
            key: const ValueKey('ask-add-choice'),
            label: 'Add a choice',
            icon: OmniIcons.add,
            expand: false,
            onPressed: choices.length >= 10
                ? null
                : () => setState(() {
                    final c = TextEditingController();
                    owns.add(c);
                    choices.add(c);
                  }),
          ),
        ),
        if (filled().isNotEmpty) ...[
          const SizedBox(height: OmniSpace.sm),
          const Text(
            'If nobody answers in time, take',
            style: OmniText.caption,
          ),
          Wrap(
            key: const ValueKey('ask-defaults'),
            spacing: 6,
            runSpacing: 6,
            children: [
              OmniFilterChip(
                key: const ValueKey('ask-default-none'),
                label: 'Nothing: the step fails',
                selected: !filled().contains(defaultChoice),
                onTap: () => setState(() => defaultChoice = null),
              ),
              for (final o in filled())
                OmniFilterChip(
                  key: ValueKey('ask-default-$o'),
                  label: o,
                  selected: defaultChoice == o,
                  onTap: () => setState(() => defaultChoice = o),
                ),
            ],
          ),
        ],
      ] else
        LabelledField(
          key: const ValueKey('ask-default'),
          label: 'If nobody answers in time, take (optional)',
          controller: typedDefault,
          onChanged: (_) => setState(() {}),
        ),
      const SizedBox(height: OmniSpace.sm),
      LabelledField(
        key: const ValueKey('ask-timeout'),
        label: 'Wait at most',
        controller: minutes,
        number: true,
        suffix: 'min',
        onChanged: (_) => setState(() {}),
      ),
      store.field(setState, 'ask'),
    ],
  );
}

/// Reads a part of a value by its path: `body.name`, `items[0]`.
Future<GetStep?> getValueForm(
  BuildContext context, {
  GetStep? current,
  TokenSource? tokens,
}) {
  final from = TokenController(text: current?.from ?? '');
  final path = TextEditingController(text: current?.path ?? '');
  final store = _StoreAs('get', current?.as);
  return showFormSheet(
    context,
    owns: [from, path, store.controller],
    title: 'Get a value',
    subtitle: 'Its value goes into Value for the next steps.',
    whyNot: () => from.text.trim().isEmpty
        ? 'Pick what to read it from'
        : store.ok
        ? null
        : 'Name it with letters, numbers and _',
    result: () => from.text.trim().isEmpty || !store.ok
        ? null
        : GetStep(
            from.text.trim(),
            path: path.text.trim(),
            as: store.keep(current?.as),
            extra: current?.extra,
          ),
    build: (context, setState) => [
      TokenField(
        key: const ValueKey('get-from'),
        id: 'get-from',
        label: 'From',
        hint: 'Add a value below',
        controller: from,
        source: tokens,
        kinds: const {'object', 'list', 'text'},
        onChanged: (_) => setState(() {}),
      ),
      LabelledField(
        key: const ValueKey('get-path'),
        label: 'Path (optional)',
        hint: 'state.on or items[0].name',
        controller: path,
        onChanged: (_) => setState(() {}),
      ),
      store.field(setState, 'get'),
    ],
  );
}

/// Text from words and values, changed to capitals or trimmed.
Future<TextStep?> textForm(
  BuildContext context, {
  TextStep? current,
  TokenSource? tokens,
}) {
  final value = TokenController(text: current?.value ?? '');
  var op = current?.op ?? 'none';
  final store = _StoreAs('text', current?.as);
  return showFormSheet(
    context,
    owns: [value, store.controller],
    title: 'Text',
    subtitle: 'It goes into Text for the next steps.',
    whyNot: () => store.ok ? null : 'Name it with letters, numbers and _',
    result: () => !store.ok
        ? null
        : TextStep(
            value.text,
            op: op == 'none' && current?.op == null ? null : op,
            as: store.keep(current?.as),
            extra: current?.extra,
          ),
    build: (context, setState) => [
      TokenField(
        key: const ValueKey('text-value'),
        id: 'text-value',
        label: 'Text',
        hint: 'Hi, add a value below',
        controller: value,
        source: tokens,
        onChanged: (_) => setState(() {}),
      ),
      OmniSegmented<String>(
        key: const ValueKey('text-op'),
        segments: const [
          OmniSegment('none', 'As it is'),
          OmniSegment('upper', 'CAPITALS'),
          OmniSegment('lower', 'small'),
          OmniSegment('trim', 'Trim'),
        ],
        selected: op,
        onChanged: (v) => setState(() => op = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      store.field(setState, 'text'),
    ],
  );
}

/// A sum: numbers and values with + - * / %, brackets and round().
Future<MathStep?> mathForm(
  BuildContext context, {
  MathStep? current,
  TokenSource? tokens,
}) {
  final expr = TokenController(text: current?.expr ?? '');
  final store = _StoreAs('math', current?.as);
  return showFormSheet(
    context,
    owns: [expr, store.controller],
    title: 'Calculate',
    subtitle:
        'Numbers and values with + - * / %, brackets and round(). The '
        'answer goes into Result.',
    whyNot: () => expr.text.trim().isEmpty
        ? 'Write the sum'
        : store.ok
        ? null
        : 'Name it with letters, numbers and _',
    result: () => expr.text.trim().isEmpty || !store.ok
        ? null
        : MathStep(
            expr.text.trim(),
            as: store.keep(current?.as),
            extra: current?.extra,
          ),
    build: (context, setState) => [
      TokenField(
        key: const ValueKey('math-expr'),
        id: 'math-expr',
        label: 'Sum',
        hint: 'round(value * 2 + 1)',
        controller: expr,
        source: tokens,
        kinds: const {'number'},
        onChanged: (_) => setState(() {}),
      ),
      store.field(setState, 'math'),
    ],
  );
}

/// The time now, or a while before or after, written as [DateStep.format].
Future<DateStep?> dateForm(BuildContext context, [DateStep? current]) {
  final format = TextEditingController(text: current?.format ?? 'HH:mm');
  final offset = current?.offsetMinutes ?? 0;
  var when = offset == 0
      ? 'now'
      : offset < 0
      ? 'ago'
      : 'later';
  final minutes = TextEditingController(
    text: offset == 0 ? '30' : '${offset.abs()}',
  );
  final store = _StoreAs('date', current?.as);
  int? offsetMinutes() {
    if (when == 'now') return 0;
    final m = int.tryParse(minutes.text.trim());
    if (m == null || m < 1) return null;
    return when == 'ago' ? -m : m;
  }

  const presets = {'HH:mm': '18:30', 'EEEE': 'Monday', 'd MMM': '12 Nov'};
  return showFormSheet(
    context,
    owns: [format, minutes, store.controller],
    title: 'Date and time',
    subtitle: 'It goes into Date for the next steps.',
    whyNot: () => format.text.trim().isEmpty
        ? 'Choose how to write it'
        : offsetMinutes() == null
        ? 'Give a whole number of minutes'
        : store.ok
        ? null
        : 'Name it with letters, numbers and _',
    result: () {
      final m = offsetMinutes();
      if (format.text.trim().isEmpty || m == null || !store.ok) return null;
      return DateStep(
        format.text.trim(),
        offsetMinutes: m == 0 && current?.offsetMinutes == null ? null : m,
        as: store.keep(current?.as),
        extra: current?.extra,
      );
    },
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('date-when'),
        segments: const [
          OmniSegment('ago', 'Before now'),
          OmniSegment('now', 'Now'),
          OmniSegment('later', 'From now'),
        ],
        selected: when,
        onChanged: (v) => setState(() => when = v),
      ),
      if (when != 'now') ...[
        const SizedBox(height: OmniSpace.sm),
        LabelledField(
          key: const ValueKey('date-minutes'),
          label: 'Minutes',
          controller: minutes,
          number: true,
          onChanged: (_) => setState(() {}),
        ),
      ],
      const SizedBox(height: OmniSpace.sm),
      Wrap(
        key: const ValueKey('date-presets'),
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final MapEntry(key: f, value: shows) in presets.entries)
            OmniFilterChip(
              key: ValueKey('date-preset-$f'),
              label: shows,
              selected: format.text.trim() == f,
              onTap: () => setState(() => format.text = f),
            ),
        ],
      ),
      const SizedBox(height: OmniSpace.sm),
      LabelledField(
        key: const ValueKey('date-format'),
        label: 'Written as',
        hint: 'HH:mm',
        controller: format,
        onChanged: (_) => setState(() {}),
      ),
      store.field(setState, 'date'),
    ],
  );
}

/// What a Repeat with each goes through: a value from an earlier step (a
/// list), a list typed here, or each device in a room. The steps it runs
/// go on its own page.
Future<ForEachStep?> forEachForm(
  BuildContext context,
  RuleWords words, {
  ForEachStep? current,
  TokenSource? tokens,
  bool inRoom = false,
}) {
  var mode = switch (current?.over) {
    _ when current?.room != null => 'room',
    List() => 'list',
    null when inRoom => 'room',
    _ => 'value',
  };
  final value = TokenController(
    text: current?.over is String && current?.room == null
        ? current!.over as String
        : '',
  );
  final list = TextEditingController(
    text: switch (current?.over) {
      final List items => items.map(valueText).join(', '),
      _ => '',
    },
  );
  var room = current?.room ?? words.rooms.firstOrNull;
  final max = TextEditingController(text: '${current?.max ?? ''}');
  final store = _StoreAs('forEach', current?.as);
  int? maxValue() {
    final t = max.text.trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    return n == null || n < 1 || n > 1000 ? -1 : n;
  }

  Object? over() => switch (mode) {
    'room' => room == null ? null : '${ForEachStep.roomPrefix}$room',
    'list' => [
      for (final item in list.text.split(','))
        if (item.trim().isNotEmpty) wordValue(item),
    ],
    _ => value.text.trim().isEmpty ? null : value.text.trim(),
  };
  bool filled() {
    final o = over();
    return o != null && (o is! List || o.isNotEmpty);
  }

  // "Do this to each device": one step on the device the repeat holds.
  final existing = current?.steps
      .whereType<DoStep>()
      .where((s) => RuleWords.isEachDevice(s.thing))
      .firstOrNull;
  var each = switch (existing) {
    DoStep(:final capability, :final params)
        when params.length == 1 && params['value'] is bool =>
      '${params['value'] == true ? 'on' : 'off'}-$capability',
    DoStep(:final capability, :final params) when params.length == 1 =>
      'set-$capability',
    DoStep(:final capability) => 'do-$capability',
    null => null,
  };
  final eachValue = TextEditingController(
    text: each?.startsWith('set-') ?? false
        ? valueText(existing!.params['value'])
        : '',
  );
  RuleStep? eachStep() {
    final choice = each;
    if (choice == null || mode != 'room') return null;
    final dash = choice.indexOf('-');
    final kind = choice.substring(0, dash);
    final cap = choice.substring(dash + 1);
    final device = '{{${store.keep(current?.as) ?? defaultAs['forEach']}}}';
    return switch (kind) {
      'on' || 'off' => DoStep(device, cap, params: {'value': kind == 'on'}),
      'set' => switch (num.tryParse(eachValue.text.trim())) {
        final n? => DoStep(device, cap, params: {'value': n}),
        null => null,
      },
      _ => DoStep(device, cap),
    };
  }

  bool eachMissing() =>
      mode == 'room' &&
      (each?.startsWith('set-') ?? false) &&
      eachStep() == null;
  List<RuleStep>? stepsWith() {
    final steps = [...?current?.steps];
    final at = existing == null ? -1 : steps.indexOf(existing);
    final step = eachStep();
    if (mode != 'room') return current?.steps;
    if (step == null) {
      if (at >= 0) steps.removeAt(at);
    } else if (at >= 0) {
      steps[at] = step;
    } else {
      steps.add(step);
    }
    return steps;
  }

  return showFormSheet(
    context,
    owns: [value, list, max, store.controller, eachValue],
    title: 'Repeat with each',
    subtitle: 'Each item goes into Item for the steps inside.',
    whyNot: () => !filled()
        ? 'Choose what to go through'
        : maxValue() == -1
        ? 'At most 1 to 1000 times'
        : eachMissing()
        ? 'Type a number for each device'
        : store.ok
        ? null
        : 'Name it with letters, numbers and _',
    result: () {
      if (!filled() || maxValue() == -1 || !store.ok || eachMissing()) {
        return null;
      }
      return ForEachStep(
        over: over(),
        as: store.keep(current?.as),
        steps: stepsWith(),
        max: maxValue(),
        extra: current?.extra,
      );
    },
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('foreach-mode'),
        segments: [
          const OmniSegment('value', 'A value'),
          const OmniSegment('list', 'A list'),
          if (words.rooms.isNotEmpty || mode == 'room')
            const OmniSegment('room', 'A room'),
        ],
        selected: mode,
        onChanged: (v) => setState(() => mode = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      if (mode == 'value')
        TokenField(
          key: const ValueKey('foreach-in'),
          id: 'foreach-in',
          label: 'Each item of',
          hint: 'Add a value below',
          controller: value,
          source: tokens,
          kinds: const {'list'},
          onChanged: (_) => setState(() {}),
        )
      else if (mode == 'list')
        LabelledField(
          key: const ValueKey('foreach-list'),
          label: 'Items, with commas between',
          hint: 'Kitchen, Hall, Bedroom',
          controller: list,
          onChanged: (_) => setState(() {}),
        )
      else ...[
        for (final r in {...words.rooms, ?room})
          ChoiceRow(
            key: ValueKey('foreach-room-$r'),
            title: r,
            subtitle: 'each device in it',
            icon: AutomationIcons.room,
            selected: r == room,
            onTap: () => setState(() => room = r),
          ),
        ..._eachDeviceChoices(
          words,
          room,
          each,
          eachValue,
          (v) => setState(() => each = v),
          setState,
        ),
      ],
      LabelledField(
        key: const ValueKey('foreach-max'),
        label: 'At most this many (empty: 100)',
        controller: max,
        number: true,
        onChanged: (_) => setState(() {}),
      ),
      store.field(setState, 'foreach'),
    ],
  );
}

/// What every device in [room] can be told without a device of its own:
/// an on/off switch, a level, or an action that takes nothing. A
/// capability counts when each device has it with the same id and type.
List<Json> eachDeviceActions(RuleWords words, String? room) {
  final devices = [
    for (final t in words.things)
      if (room != null && t.room == room && t.actions.isNotEmpty) t,
  ];
  if (devices.isEmpty) return const [];
  bool fits(Json c) => switch (c['type']) {
    'toggle' => c['stateKey'] != null,
    'level' => true,
    'action' => (c['params'] as Map? ?? const {}).isEmpty,
    _ => false,
  };
  return [
    for (final c in devices.first.actions)
      if (fits(c) &&
          devices.every(
            (d) => d.capability('${c['id']}')?['type'] == c['type'],
          ))
        c,
  ];
}

String _capLabel(Json c) => '${c['label'] ?? c['id']}'
    .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
    .toLowerCase();

/// "Do this to each device" in a Repeat with each over [room]: a choice
/// for each thing they all can do, then the number a level takes.
List<Widget> _eachDeviceChoices(
  RuleWords words,
  String? room,
  String? each,
  TextEditingController value,
  ValueChanged<String?> pick,
  StateSetter setState,
) {
  final caps = eachDeviceActions(words, room);
  final choices = <(String, String)>[
    for (final c in caps)
      ...switch (c['type']) {
        'toggle' => [
          ('on-${c['id']}', words.eachDo('${c['id']}', {'value': true})),
          ('off-${c['id']}', words.eachDo('${c['id']}', {'value': false})),
        ],
        'level' => [('set-${c['id']}', "Set each device's ${_capLabel(c)}")],
        _ => [('do-${c['id']}', words.eachDo('${c['id']}', const {}))],
      },
  ];
  return [
    const OmniSectionHeader('Do this to each device'),
    if (choices.isEmpty)
      const Padding(
        padding: EdgeInsets.only(bottom: OmniSpace.sm),
        child: Text(
          'These devices have nothing they all can do. Add steps inside '
          'the repeat instead.',
          key: ValueKey('foreach-each-none'),
          style: OmniText.caption,
        ),
      )
    else ...[
      ChoiceRow(
        key: const ValueKey('foreach-each-later'),
        title: 'Choose the steps inside later',
        selected: each == null,
        onTap: () => pick(null),
      ),
      for (final (key, title) in choices) ...[
        ChoiceRow(
          key: ValueKey('foreach-each-$key'),
          title: title,
          icon: AutomationIcons.forEach,
          selected: each == key,
          onTap: () => pick(key),
        ),
        if (each == key && key.startsWith('set-'))
          LabelledField(
            key: const ValueKey('foreach-each-value'),
            label: 'To',
            hint: '50',
            controller: value,
            number: true,
            onChanged: (_) => setState(() {}),
          ),
      ],
    ],
  ];
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
          icon: automationIconFor(a),
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
      hasRelease: keep.hasRelease && (v is bool) == (keep.value is bool),
    );
