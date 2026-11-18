part of 'pickers.dart';

// Triggers.

/// Picks a new trigger from the library: Me, This phone, Things and Time,
/// with a search over all of them. [thingsOnly] leaves out the time
/// triggers, for a wait until.
Future<RuleTrigger?> pickTrigger(
  BuildContext context,
  RuleWords words, {
  bool thingsOnly = false,
}) {
  final things = [
    for (final t in words.things)
      if (!t.isPerson && !t.isPlace && !t.isTag && _reports(t)) t,
  ];
  final phone = words.phone?.id ?? 'phone';
  LibraryChoice choice(
    String category,
    String key,
    String title,
    IconData icon,
    Future<RuleTrigger?> Function(BuildContext c)? form, {
    String? subtitle,
    String keywords = '',
  }) => LibraryChoice(
    key: key,
    title: title,
    subtitle: subtitle,
    icon: icon,
    category: category,
    keywords: keywords,
    onTap: form == null ? null : _then(form),
  );
  const me = 'Me', onPhone = 'This phone', inThings = 'Things';
  const time = 'Time';
  return showLibrary(
    context,
    title: thingsOnly ? 'Wait until…' : 'When…',
    hint: 'Search devices, places, tags',
    categories: [
      me,
      onPhone,
      inThings,
      if (!thingsOnly) time,
      phoneMoreCategory,
    ],
    choices: [
      if (words.people.isNotEmpty)
        choice(
          me,
          'pick-home',
          words.me != null
              ? 'I get home or leave'
              : 'Someone gets home or leaves',
          OmniIcons.home,
          (c) => presenceTriggerForm(c, words),
          subtitle: 'Wi-Fi, Bluetooth or a hub that sees my phone',
        ),
      if (words.people.isNotEmpty)
        choice(
          me,
          'pick-people',
          'The first person gets home or the last leaves',
          OmniIcons.home,
          peopleTriggerForm,
          subtitle: 'everyone in the home, each by their own phone',
          keywords: 'everyone family household away',
        ),
      choice(
        me,
        'pick-tag',
        'An NFC tag is scanned',
        OmniIcons.tag,
        words.tags.isEmpty ? null : (c) => tagTriggerForm(c, words),
        subtitle: words.tags.isEmpty
            ? 'No tags yet. Add one with Add, then come back'
            : andList([for (final t in words.tags) t.name]),
      ),
      choice(
        onPhone,
        'pick-phone-app',
        'An app opens',
        AutomationIcons.app,
        (c) => phoneAppTriggerForm(c, phone, PhoneKeys.appOpened),
        subtitle: 'or closes, on this phone',
        keywords: 'app closes',
      ),
      choice(
        onPhone,
        'pick-phone-notification',
        'A notification arrives from',
        OmniIcons.notifications,
        (c) => phoneAppTriggerForm(c, phone, PhoneKeys.notification),
        subtitle: 'a chosen app, or any app',
      ),
      choice(
        onPhone,
        'pick-phone-bluetooth',
        'A Bluetooth device connects',
        AutomationIcons.bluetooth,
        (c) => phoneBluetoothTriggerForm(c, phone),
        subtitle: 'or disconnects: the car, headphones',
        keywords: 'disconnects car headphones',
      ),
      choice(
        onPhone,
        'pick-phone-screen',
        'The screen turns on or off',
        AutomationIcons.screen,
        (c) => phoneSwitchTriggerForm(c, phone, PhoneKeys.screenOn),
      ),
      choice(
        onPhone,
        'pick-phone-dnd',
        'Do Not Disturb turns on or off',
        AutomationIcons.dnd,
        (c) => phoneSwitchTriggerForm(c, phone, PhoneKeys.dndOn),
      ),
      choice(
        onPhone,
        'pick-phone-charging',
        'The phone starts or stops charging',
        AutomationIcons.charging,
        (c) => phoneSwitchTriggerForm(c, phone, PhoneKeys.charging),
        keywords: 'charger battery',
      ),
      ...phoneMoreTriggerChoices(phoneMoreCategory, phone),
      choice(
        me,
        'pick-house-mode',
        'The house mode changes',
        OmniIcons.home,
        modeTriggerForm,
        subtitle: 'to Home, Away, Night, Vacation or your own',
        keywords: 'mode away night vacation',
      ),
      choice(
        me,
        'pick-timer-ends',
        'A timer ends',
        OmniIcons.wait,
        timerTriggerForm,
        subtitle: 'a named timer, like Pasta',
        keywords: 'timer countdown',
      ),
      for (final t in things)
        choice(
          t.isPhone ? onPhone : inThings,
          'pick-thing-${t.id}',
          t.isPhone ? 'Something else on ${t.name}' : t.name,
          t.icon,
          (c) => thingTriggerForm(c, words, t),
          subtitle: t.reportsText,
          keywords: t.isPhone ? '' : t.room ?? '',
        ),
      if (!thingsOnly) ...[
        choice(
          time,
          'pick-time',
          'At a time',
          OmniIcons.time,
          timeTriggerForm,
          subtitle: 'on chosen days',
        ),
        choice(
          time,
          'pick-sun',
          'At sunrise or sunset',
          OmniIcons.sun,
          sunTriggerForm,
          subtitle: 'or a while before or after, at home',
        ),
        choice(
          time,
          'pick-interval',
          'Every few minutes',
          OmniIcons.repeat,
          intervalTriggerForm,
        ),
        LibraryChoice(
          key: 'pick-manual',
          title: 'Only when I run it',
          subtitle: 'from the list, a scene button or another automation',
          icon: OmniIcons.action,
          category: time,
          onTap: (c) async => Navigator.of(c).pop(const ManualTrigger()),
        ),
        LibraryChoice(
          key: 'pick-engine-start',
          title: 'When OmniFlow starts',
          subtitle: 'once, after the phone restarts or OmniFlow opens',
          icon: engineStartIcon,
          category: time,
          keywords: 'startup boot restart',
          onTap: (c) async => Navigator.of(c).pop(const EngineStartTrigger()),
        ),
      ],
    ],
  );
}

/// An app opening or closing, or a notification from it: [key] is
/// `app_opened`, `app_closed` or `notification`. No app means any app.
Future<OnTrigger?> phoneAppTriggerForm(
  BuildContext context,
  String phone,
  String key, [
  OnTrigger? current,
]) {
  var event = current?.key ?? key;
  final notification = key == PhoneKeys.notification;
  final app = TextEditingController(
    text: '${current?.match?['package'] ?? ''}',
  );
  // Read once per sheet. Empty when Android does not answer, and then only
  // the typed field shows.
  final installed = const InstalledApps().list();
  return showFormSheet(
    context,
    owns: [app],
    title: notification ? 'A notification arrives from' : 'An app opens',
    subtitle: notification
        ? 'OmniFlow needs notification access, which Android asks for once. '
              'What it says is never stored.'
        : 'OmniFlow needs usage access, which Android asks for once.',
    result: () => OnTrigger(
      thing: phone,
      key: event,
      mode: OnMode.event,
      match: {
        ..._otherMatch(current, 'package'),
        'package': ?app.text.trim().nonEmptyOrNull,
      }.nonEmptyOrNull,
    ),
    build: (context, setState) => [
      if (!notification)
        OmniSegmented<String>(
          key: const ValueKey('phone-app-event'),
          segments: const [
            OmniSegment(PhoneKeys.appOpened, 'Opens'),
            OmniSegment(PhoneKeys.appClosed, 'Closes'),
          ],
          selected: event,
          onChanged: (v) => setState(() => event = v),
        ),
      const SizedBox(height: OmniSpace.sm),
      FutureBuilder<List<InstalledApp>>(
        future: installed,
        builder: (context, snap) {
          final apps = snap.data ?? const <InstalledApp>[];
          if (apps.isEmpty) return const SizedBox.shrink();
          final package = app.text.trim();
          final chosen = apps.where((a) => a.package == package).firstOrNull;
          return OmniListRow(
            key: const ValueKey('phone-app-choose'),
            icon: AutomationIcons.app,
            title: package.isEmpty ? 'Any app' : chosen?.label ?? package,
            subtitle: 'Choose from the apps on this phone',
            chevron: true,
            onTap: () async {
              final picked = await pickPhoneApp(context, apps);
              if (picked != null) setState(() => app.text = picked);
            },
          );
        },
      ),
      LabelledField(
        key: const ValueKey('phone-app'),
        label: 'Or type its package name (empty for any app)',
        hint: 'com.netflix.mediaclient',
        controller: app,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// The phone's launchable [apps] by name, searchable. Gives the package of
/// the one picked, or an empty package for Any app.
Future<String?> pickPhoneApp(BuildContext context, List<InstalledApp> apps) =>
    _push(
      context,
      _PickerPage(
        title: 'Choose an app',
        hint: 'Search apps',
        sections: [
          (
            'Apps on this phone',
            [
              _Choice(
                key: 'pick-phone-app-any',
                title: 'Any app',
                icon: AutomationIcons.app,
                onTap: (c) async => Navigator.of(c).pop(''),
              ),
              for (final a in apps)
                _Choice(
                  key: 'pick-phone-app-${a.package}',
                  title: a.label,
                  subtitle: a.package,
                  icon: AutomationIcons.app,
                  onTap: (c) async => Navigator.of(c).pop(a.package),
                ),
            ],
          ),
        ],
      ),
    );

/// A Bluetooth device connecting or disconnecting, by its name, or any.
Future<OnTrigger?> phoneBluetoothTriggerForm(
  BuildContext context,
  String phone, [
  OnTrigger? current,
]) {
  var event = current?.key ?? PhoneKeys.bluetoothConnected;
  final name = TextEditingController(text: '${current?.match?['name'] ?? ''}');
  return showFormSheet(
    context,
    owns: [name],
    title: 'A Bluetooth device',
    subtitle: 'OmniFlow needs Bluetooth access, which Android asks for once.',
    result: () => OnTrigger(
      thing: phone,
      key: event,
      mode: OnMode.event,
      match: {
        ..._otherMatch(current, 'name'),
        'name': ?name.text.trim().nonEmptyOrNull,
      }.nonEmptyOrNull,
    ),
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('phone-bt-event'),
        segments: const [
          OmniSegment(PhoneKeys.bluetoothConnected, 'Connects'),
          OmniSegment(PhoneKeys.bluetoothDisconnected, 'Disconnects'),
        ],
        selected: event,
        onChanged: (v) => setState(() => event = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      LabelledField(
        key: const ValueKey('phone-bt-name'),
        label: 'Device name (empty for any)',
        hint: 'My car',
        controller: name,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// The screen, Do Not Disturb or charging turning on, off, or either:
/// [key] is `screen_on`, `dnd_on` or `charging`.
Future<OnTrigger?> phoneSwitchTriggerForm(
  BuildContext context,
  String phone,
  String key, [
  OnTrigger? current,
]) {
  // 'either' stands for no "to": any change.
  var to = current == null || !current.hasTo ? 'either' : '${current.to}';
  final charging = key == PhoneKeys.charging;
  return showFormSheet(
    context,
    title: switch (key) {
      PhoneKeys.screenOn => 'The screen',
      PhoneKeys.dndOn => 'Do Not Disturb',
      _ => 'Charging',
    },
    result: () => OnTrigger(
      thing: phone,
      key: key,
      to: to == 'true',
      hasTo: to != 'either',
    ),
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('phone-turns'),
        segments: [
          OmniSegment('true', charging ? 'Starts' : 'Turns on'),
          OmniSegment('false', charging ? 'Stops' : 'Turns off'),
          const OmniSegment('either', 'Either'),
        ],
        selected: to,
        onChanged: (v) => setState(() => to = v),
      ),
    ],
  );
}

/// The filter on an event's details other than [key], kept since no form
/// here edits it.
Map<String, Object?> _otherMatch(OnTrigger? current, String key) => {
  for (final e in (current?.match ?? const {}).entries)
    if (e.key != key) e.key: e.value,
};

extension on String {
  String? get nonEmptyOrNull => isEmpty ? null : this;
}

extension on Map<String, Object?> {
  Map<String, Object?>? get nonEmptyOrNull => isEmpty ? null : this;
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
    if (editHouseTrigger(context, t) case final form?) return form;
    final thing = words.thing(t.thing);
    if (thing == null) return null;
    if (thing.isPerson) return presenceTriggerForm(context, words, t);
    if (thing.isTag) return tagTriggerForm(context, words, t);
    if (thing.isPhone) {
      switch (t.key) {
        case PhoneKeys.appOpened ||
            PhoneKeys.appClosed ||
            PhoneKeys.notification:
          return phoneAppTriggerForm(context, thing.id, t.key, t);
        case PhoneKeys.bluetoothConnected || PhoneKeys.bluetoothDisconnected:
          return phoneBluetoothTriggerForm(context, thing.id, t);
        case PhoneKeys.screenOn || PhoneKeys.dndOn || PhoneKeys.charging:
          return phoneSwitchTriggerForm(context, thing.id, t.key, t);
      }
      if (editPhoneMoreTrigger(context, thing.id, t) case final form?) {
        return form;
      }
    }
    return thingTriggerForm(context, words, thing, t);
  }
  return switch (t) {
    TimeTrigger() => timeTriggerForm(context, t),
    SunTrigger() => sunTriggerForm(context, t),
    IntervalTrigger() => intervalTriggerForm(context, t),
    PeopleTrigger() => peopleTriggerForm(context, t),
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
  // "I have been away for 10 min": held like any state.
  var holdMs = current?.forMs;
  return showFormSheet(
    context,
    title: 'When…',
    result: () => person == null
        ? null
        : OnTrigger(
            thing: person!,
            key: 'home',
            to: arriving,
            hasTo: true,
            forMs: holdMs,
          ),
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
      Text(
        'Home is decided by your home Wi-Fi, a Bluetooth beacon, or a hub '
        'that sees your phone.',
        style: OmniText.captionOf(context),
      ),
      HoldField(ms: holdMs, onChanged: (v) => setState(() => holdMs = v)),
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
        : OnTrigger(
            thing: tag!,
            key: 'scanned',
            mode: OnMode.event,
            match: _keptMatch(current, tag!, 'scanned'),
          ),
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
        (_) => OnTrigger(
          thing: thing.id,
          key: e.key,
          mode: OnMode.event,
          match: _keptMatch(current, thing.id, e.key),
        ),
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
  // A state it turns to, or a number it goes past, can be held for a time.
  var holdMs = current?.forMs;
  bool holds(String? picked) =>
      picked != null &&
      RegExp(r'^(on|off|above|below|changeto)-').hasMatch(picked);
  return _optionsForm(
    context,
    title: 'When ${thing.name}…',
    options: options,
    selected: selected,
    initialInput: input,
    unit: unit,
    extra: (picked, setState) => [
      if (holds(picked))
        HoldField(ms: holdMs, onChanged: (v) => setState(() => holdMs = v)),
    ],
    finish: (t) => t..forMs = t.canHold ? holdMs : null,
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
        style: OmniText.captionOf(context),
      ),
      const SizedBox(height: OmniSpace.xs),
      DayChips(days: days, onChanged: () => setState(() {})),
    ],
  );
}

/// Today's sunrise and sunset at home, or null while home has no place on
/// the map.
Future<({String sunrise, String sunset})?> _sunToday(
  EngineClient engine, {
  bool hour12 = false,
}) async {
  final r = await engine.call(HomeLocationCalls.get);
  if (r['ok'] != true || r['location'] == null) return null;
  final today = r['today'] is Map ? r['today'] as Map : const {};
  String clock(Object? at) {
    final t = DateTime.tryParse('$at')?.toLocal();
    return t == null ? 'none today' : timeOfDayText(hour12, t);
  }

  return (sunrise: clock(today['sunrise']), sunset: clock(today['sunset']));
}

Future<SunTrigger?> sunTriggerForm(
  BuildContext context, [
  SunTrigger? current,
]) async {
  final scope = ProviderScope.containerOf(context, listen: false);
  final engine = scope.read(engineClientProvider);
  final hour12 = scope.read(hour12Provider);
  var today = await _sunToday(engine, hour12: hour12);
  if (!context.mounted) return null;
  var event = current?.event ?? 'sunset';
  final initial = current?.offsetMinutes ?? 0;
  var when = initial == 0
      ? 'at'
      : initial < 0
      ? 'before'
      : 'after';
  final minutes = TextEditingController(
    text: initial == 0 ? '30' : '${initial.abs()}',
  );
  final days = <String>{...?current?.days};
  String? locating;
  return showFormSheet<SunTrigger>(
    context,
    owns: [minutes],
    title: 'At sunrise or sunset',
    subtitle: 'At home, worked out from where home is each day.',
    result: () {
      if (today == null) return null;
      final m = int.tryParse(minutes.text.trim());
      if (when != 'at' && (m == null || m < 1 || m > 720)) return null;
      return SunTrigger(
        event,
        offsetMinutes: switch (when) {
          'before' => -m!,
          'after' => m!,
          _ => 0,
        },
        days: [
          for (final d in weekDays)
            if (days.contains(d)) d,
        ],
      );
    },
    whyNot: () => today == null
        ? 'Set where home is first'
        : when != 'at'
        ? 'Minutes are 1 to 720'
        : null,
    build: (context, setState) => [
      if (today == null) ...[
        OmniBanner.info(
          locating ??
              'Sunrise and sunset need to know where home is. Use this '
                  'phone\'s location while you are at home.',
          key: const ValueKey('sun-no-home'),
        ),
        OmniButton(
          key: const ValueKey('sun-use-phone'),
          label: 'Use this phone\'s location',
          icon: OmniIcons.place,
          onPressed: () async {
            final here = await const Permissions().lastLocation();
            if (here == null) {
              setState(
                () => locating =
                    'The phone has no location yet. Turn on location in '
                    'Android, open a map once, then try again.',
              );
              return;
            }
            final r = await engine.call(HomeLocationCalls.set, {
              'latitude': here.latitude,
              'longitude': here.longitude,
            });
            if (r['ok'] != true) {
              setState(() => locating = errorMessage(r));
              return;
            }
            final now = await _sunToday(engine, hour12: hour12);
            setState(() => today = now);
          },
        ),
        OmniButton.ghost(
          key: const ValueKey('sun-home-location'),
          label: 'Type where home is',
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const HomeLocationPage()),
            );
            final now = await _sunToday(engine, hour12: hour12);
            setState(() => today = now);
          },
        ),
        const SizedBox(height: OmniSpace.md),
      ] else
        Text(
          'Today at home: sunrise ${today!.sunrise}, sunset ${today!.sunset}',
          key: const ValueKey('sun-today'),
          style: OmniText.captionOf(context),
        ),
      const SizedBox(height: OmniSpace.sm),
      OmniSegmented<String>(
        key: const ValueKey('sun-event'),
        segments: const [
          OmniSegment('sunrise', 'Sunrise'),
          OmniSegment('sunset', 'Sunset'),
        ],
        selected: event,
        onChanged: (v) => setState(() => event = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      OmniSegmented<String>(
        key: const ValueKey('sun-when'),
        segments: const [
          OmniSegment('before', 'Before'),
          OmniSegment('at', 'Right then'),
          OmniSegment('after', 'After'),
        ],
        selected: when,
        onChanged: (v) => setState(() => when = v),
      ),
      if (when != 'at') ...[
        const SizedBox(height: OmniSpace.sm),
        LabelledField(
          key: const ValueKey('sun-minutes'),
          label: 'Minutes $when',
          controller: minutes,
          number: true,
          onChanged: (_) => setState(() {}),
        ),
      ],
      const SizedBox(height: OmniSpace.md),
      Text(
        'On ${daysText(days.toList()).replaceFirst('on ', '')}',
        style: OmniText.captionOf(context),
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
  // Lined up on the clock: minutes in, and a window of the day.
  final offset = TextEditingController(
    text: (current?.offsetSeconds ?? 0) > 0
        ? '${current!.offsetSeconds ~/ 60}'
        : '',
  );
  var between = current?.between;
  int? offsetSeconds() {
    final text = offset.text.trim();
    if (text.isEmpty) return 0;
    final m = int.tryParse(text);
    return m == null || m < 0 || m * 60 >= ms ~/ 1000 ? null : m * 60;
  }

  return showFormSheet(
    context,
    owns: [offset],
    title: 'Every few minutes',
    result: () {
      final o = offsetSeconds();
      if (ms < 1000 || o == null) return null;
      if (between != null && between![0] == between![1]) return null;
      return IntervalTrigger(ms ~/ 1000, offsetSeconds: o, between: between);
    },
    whyNot: () => offsetSeconds() == null
        ? 'Minutes in must be less than the time between runs'
        : between != null && between![0] == between![1]
        ? 'Pick two different times'
        : null,
    build: (context, setState) => [
      DurationInput(
        label: 'Every',
        ms: ms,
        onChanged: (v) => setState(() => ms = v),
      ),
      AlignedFields(
        offsetMinutes: offset,
        between: between,
        onOffset: () => setState(() {}),
        onBetween: (v) => setState(() => between = v),
      ),
    ],
  );
}
