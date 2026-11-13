part of 'pickers.dart';

// Steps.

/// The step library's categories, in order.
abstract final class StepCategories {
  static const devices = 'Devices';
  static const rooms = 'Rooms and scenes';
  static const wait = 'Wait';
  static const flow = 'Choose and repeat';
  static const ask = 'Ask and tell';
  static const data = 'Web and data';
  static const variables = 'Variables';

  static const all = [devices, rooms, wait, flow, ask, data, variables];
}

/// Picks a new step from the library: a search field, suggestions from
/// [rule] (the devices and kinds of step it already uses) and from what
/// [automations] control most, then the categories. Typing searches every
/// step kind and every device action, including each app a TV can open.
/// [allowKeep] offers the keep step, which only goes at the end of a
/// rule's own THEN. [tokens] are the values its fields can use.
Future<RuleStep?> pickStep(
  BuildContext context,
  RuleWords words, {
  required List<AutomationSummary> automations,
  bool allowKeep = false,
  RuleSpec? rule,
  TokenSource? tokens,
}) {
  final devices = [
    for (final t in words.things)
      if (t.actions.isNotEmpty) t,
  ];
  final scenes = [
    for (final a in automations)
      if (a.source == 'scene') a,
  ];
  LibraryChoice pop(
    String category,
    String key,
    String title,
    IconData icon,
    RuleStep Function() make, {
    String? subtitle,
    String keywords = '',
  }) => LibraryChoice(
    key: key,
    title: title,
    subtitle: subtitle,
    icon: icon,
    category: category,
    keywords: keywords,
    onTap: (c) async => Navigator.of(c).pop(make()),
  );
  LibraryChoice form(
    String category,
    String key,
    String title,
    IconData icon,
    Future<RuleStep?> Function(BuildContext c)? open, {
    String? subtitle,
    String keywords = '',
    bool warning = false,
  }) => LibraryChoice(
    key: key,
    title: title,
    subtitle: subtitle,
    icon: icon,
    category: category,
    keywords: keywords,
    warning: warning,
    onTap: open == null ? null : _then(open),
  );
  const dv = StepCategories.devices, r = StepCategories.rooms;
  const w = StepCategories.wait, f = StepCategories.flow;
  const a = StepCategories.ask, d = StepCategories.data;
  const v = StepCategories.variables;
  final kinds = <String, LibraryChoice>{
    'wait': form(
      w,
      'pick-wait',
      'Wait',
      OmniIcons.wait,
      waitForm,
      subtitle: 'a few seconds or minutes',
    ),
    'waitFor': form(
      w,
      'pick-wait-until',
      'Wait until something happens',
      AutomationIcons.waitUntil,
      (c) => waitUntilForm(c, words),
      subtitle: 'with a time limit and what to do then',
    ),
    'if': pop(
      f,
      'pick-if',
      'If… otherwise',
      OmniIcons.branch,
      IfStep.new,
      subtitle: 'do different steps depending on a check',
    ),
    'try': pop(
      f,
      'pick-try',
      'Try, with a fallback',
      AutomationIcons.fallback,
      TryStep.new,
      subtitle:
          'if a step fails, like an app that is not installed, do '
          'something else',
    ),
    'repeat': pop(
      f,
      'pick-repeat',
      'Repeat',
      AutomationIcons.repeat,
      RepeatStep.new,
      subtitle:
          'again and again until something holds, like until the TV is on',
    ),
    'forEach': form(
      f,
      'pick-foreach',
      'Repeat with each',
      AutomationIcons.forEach,
      (c) => forEachForm(c, words, tokens: tokens),
      subtitle: 'each item of a list, or each device in a room',
      keywords: 'loop list',
    ),
    'together': pop(
      f,
      'pick-together',
      'Do these together',
      AutomationIcons.together,
      TogetherStep.new,
      subtitle: 'run two or more lists of steps at once',
    ),
    if (allowKeep)
      'keep': pop(
        f,
        'pick-keep',
        'Keep a value while something holds',
        AutomationIcons.keep,
        () => KeepStep('', ''),
        subtitle: 'like keep the fan on while it is hot',
      ),
    'ask': form(
      a,
      'pick-ask-choose',
      'Choose from a menu',
      AutomationIcons.ask,
      (c) => askForm(c, tokens: tokens),
      subtitle: 'asks you from a notification, and the next steps use it',
      keywords: 'ask question',
    ),
    'askInput': form(
      a,
      'pick-ask-input',
      'Ask for text',
      AutomationIcons.ask,
      (c) => askForm(c, tokens: tokens, typed: true),
      subtitle: 'you reply from the notification',
      keywords: 'ask question input',
    ),
    'notify': form(
      a,
      'pick-notify',
      'Notify me',
      OmniIcons.notifications,
      (c) => notifyForm(c, null, tokens),
    ),
    'http': form(
      d,
      'pick-http',
      'Send a web request',
      AutomationIcons.web,
      (c) => httpForm(c, null, tokens),
      subtitle: 'to a Mac, Home Assistant or any web address',
      warning: true,
    ),
    'get': form(
      d,
      'pick-get',
      'Get a value',
      AutomationIcons.get,
      (c) => getValueForm(c, tokens: tokens),
      subtitle: 'from a web reply or another value, by its path',
      keywords: 'json path',
    ),
    'text': form(
      d,
      'pick-text',
      'Text',
      AutomationIcons.text,
      (c) => textForm(c, tokens: tokens),
      subtitle: 'join words and values, change capitals',
    ),
    'math': form(
      d,
      'pick-math',
      'Calculate',
      AutomationIcons.math,
      (c) => mathForm(c, tokens: tokens),
      subtitle: 'add, take away, multiply, divide, round',
      keywords: 'math sum number',
    ),
    'date': form(
      d,
      'pick-date',
      'Date and time',
      AutomationIcons.date,
      dateForm,
      subtitle: 'the time now or a while from now, as words',
      keywords: 'clock format',
    ),
    'set': form(
      v,
      'pick-set',
      'Set a variable',
      AutomationIcons.variable,
      (c) => setVariableForm(c, null, tokens),
      subtitle: 'for another automation to check',
    ),
    'run': form(
      r,
      'pick-run',
      'Run another automation',
      OmniIcons.automations,
      automations.isEmpty ? null : (c) => runForm(c, automations),
      subtitle: automations.isEmpty ? 'Make another automation first' : null,
    ),
  };
  final choices = [
    for (final t in devices)
      form(
        dv,
        'pick-device-${t.id}',
        t.name,
        t.icon,
        (c) => actionForm(c, t),
        subtitle: t.hasHighRisk
            ? '${t.actionsText}. Some steps run commands on it: Claude '
                  'needs your approval to use them'
            : t.actionsText,
        keywords: t.room ?? '',
        warning: t.hasHighRisk,
      ),
    for (final t in devices) ..._actionChoices(t),
    for (final s in scenes)
      pop(
        r,
        'pick-scene-${s.id}',
        'Run ${s.name}',
        OmniIcons.automations,
        () => RunStep(s.id),
        subtitle: 'a scene',
      ),
    if (words.rooms.isNotEmpty)
      form(
        r,
        'pick-foreach-room',
        'Do something to each device in a room',
        AutomationIcons.room,
        (c) => forEachForm(c, words, tokens: tokens, inRoom: true),
        subtitle: andList(words.rooms),
      ),
    ...kinds.values,
  ];
  return showLibrary(
    context,
    title: 'Then…',
    hint: 'Search devices and steps',
    categories: StepCategories.all,
    choices: choices,
    suggestions: _suggestions(words, rule, automations, kinds),
    more: () => _appChoices(context, devices),
  );
}

/// What a device can do, each as its own search result: "Turn Desk lamp
/// on", "Launch app on TV".
List<LibraryChoice> _actionChoices(Thing t) => [
  for (final cap in t.actions)
    if (cap['type'] == 'toggle') ...[
      for (final on in [true, false])
        LibraryChoice(
          key: 'pick-act-${t.id}-${cap['id']}-${on ? 'on' : 'off'}',
          title: t.toggles.length > 1 || t.actions.length > 1
              ? 'Turn ${t.name} ${'${cap['label']}'.toLowerCase()} '
                    '${on ? 'on' : 'off'}'
              : 'Turn ${t.name} ${on ? 'on' : 'off'}',
          icon: t.icon,
          category: StepCategories.devices,
          keywords: t.room ?? '',
          searchOnly: true,
          onTap: (c) async =>
              Navigator.of(c)
                  .pop(DoStep(t.id, '${cap['id']}', params: {'value': on})),
        ),
    ] else if (cap['type'] != 'dpad_remote')
      LibraryChoice(
        key: 'pick-act-${t.id}-${cap['id']}',
        title: '${cap['label'] ?? cap['id']} on ${t.name}',
        icon: OmniIcons.forCapability(cap['type'] as String?),
        category: StepCategories.devices,
        keywords: t.room ?? '',
        searchOnly: true,
        warning: isHighRisk(cap),
        onTap: _then((c) => actionForm(c, t, DoStep(t.id, '${cap['id']}'))),
      ),
];

/// "Open Netflix on TV" for each app each TV can open, loaded the first
/// time someone types in the library.
Future<List<LibraryChoice>> _appChoices(
  BuildContext context,
  List<Thing> devices,
) async {
  final out = <LibraryChoice>[];
  for (final tv in devices) {
    if (tv.driver != TvCalls.driver) continue;
    final launch = tv.capability('launch_app');
    if (launch == null) continue;
    final List<ParamChoice> apps;
    try {
      apps = await tvAppChoices(context, tv.id);
    } on Object {
      continue;
    }
    for (final app in apps) {
      out.add(
        LibraryChoice(
          key: 'pick-app-${tv.id}-${app.value}',
          title: 'Open ${app.label} on ${tv.name}',
          subtitle: app.label == app.value ? null : app.value,
          icon: AutomationIcons.app,
          category: StepCategories.devices,
          keywords: app.value,
          searchOnly: true,
          onTap: (c) async => Navigator.of(c)
              .pop(DoStep(tv.id, 'launch_app', params: {'package': app.value})),
        ),
      );
    }
  }
  return out;
}

/// The devices and step kinds [rule] already uses, then the devices the
/// other automations control most.
List<LibrarySuggestion> _suggestions(
  RuleWords words,
  RuleSpec? rule,
  List<AutomationSummary> automations,
  Map<String, LibraryChoice> kinds,
) {
  final used = <String, int>{};
  final usedKinds = <String>{};
  void walk(List<RuleStep> steps) {
    for (final s in steps) {
      switch (s) {
        case DoStep(:final thing) || ToggleStep(:final thing):
          used[thing] = (used[thing] ?? 0) + 1;
        case KeepStep(:final thing):
          used[thing] = (used[thing] ?? 0) + 1;
        case IfStep():
          usedKinds.add('if');
          walk(s.then);
          walk(s.otherwise);
        case TryStep():
          usedKinds.add('try');
          walk(s.steps);
          walk(s.otherwise);
        case RepeatStep():
          usedKinds.add('repeat');
          walk(s.steps);
        case ForEachStep():
          usedKinds.add('forEach');
          walk(s.steps);
        case TogetherStep():
          usedKinds.add('together');
          s.branches.forEach(walk);
        case WaitForStep():
          usedKinds.add('waitFor');
          walk(s.onTimeout);
        default:
          if (_kindOf(s) case final kind?) usedKinds.add(kind);
      }
    }
  }

  walk(rule?.then ?? const []);
  final ranked = used.keys.toList()
    ..sort((a, b) => used[b]!.compareTo(used[a]!));
  final elsewhere = <String, int>{};
  for (final a in automations) {
    for (final d in a.controls) {
      elsewhere[d] = (elsewhere[d] ?? 0) + 1;
    }
  }
  final most = elsewhere.keys.where((d) => !used.containsKey(d)).toList()
    ..sort((a, b) => elsewhere[b]!.compareTo(elsewhere[a]!));
  final devices = [
    for (final id in [...ranked, ...most])
      if (words.thing(id) case final t? when t.actions.isNotEmpty) t,
  ].take(4);
  return [
    for (final t in devices)
      LibrarySuggestion(
        key: 'suggest-device-${t.id}',
        label: t.name,
        icon: t.icon,
        onTap: _then((c) => actionForm(c, t)),
      ),
    for (final kind in usedKinds)
      if (kinds[kind] case final choice? when choice.onTap != null)
        LibrarySuggestion(
          key: 'suggest-kind-$kind',
          label: choice.title,
          icon: choice.icon,
          onTap: choice.onTap!,
        ),
  ];
}

String? _kindOf(RuleStep s) => switch (s) {
  WaitStep() => 'wait',
  NotifyStep() => 'notify',
  HttpStep() => 'http',
  SetStep() => 'set',
  RunStep() => 'run',
  AskStep() => s.asksForText ? 'askInput' : 'ask',
  GetStep() => 'get',
  TextStep() => 'text',
  MathStep() => 'math',
  DateStep() => 'date',
  _ => null,
};
