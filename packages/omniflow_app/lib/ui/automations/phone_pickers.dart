part of 'pickers.dart';

// The phone's newer triggers, and the app picker for its Open an app step.

/// The library category of the newer phone triggers. It comes last, so
/// the list keeps its order above it.
const phoneMoreCategory = 'Calls, media and more';

IconData _phoneIconOf(String key) =>
    phoneMoreTriggerIcon(key) ?? AutomationIcons.phone;

/// The newer This phone triggers for the trigger library: the next alarm,
/// calls, media, the calendar, shake and face down, headphones, startup
/// and app installs.
List<LibraryChoice> phoneMoreTriggerChoices(String category, String phone) {
  LibraryChoice choice(
    String key,
    String title,
    String icon,
    Future<RuleTrigger?> Function(BuildContext c) form, {
    String? subtitle,
    String keywords = '',
  }) => LibraryChoice(
    key: key,
    title: title,
    subtitle: subtitle,
    icon: _phoneIconOf(icon),
    category: category,
    keywords: keywords,
    onTap: _then(form),
  );
  Future<RuleTrigger?> event(String key) async =>
      OnTrigger(thing: phone, key: key, mode: OnMode.event);
  return [
    choice(
      'pick-phone-alarm',
      'Before my next alarm',
      PhoneMoreKeys.alarmSoon,
      (c) => alarmSoonTriggerForm(c, phone),
      subtitle: 'say 20 minutes before, for a wake-up light',
      keywords: 'wake morning clock',
    ),
    choice(
      'pick-phone-call',
      'A call rings, is answered or ends',
      PhoneMoreKeys.callRinging,
      (c) => callTriggerForm(c, phone),
      subtitle: 'pause the TV, quiet the speakers',
      keywords: 'phone call ringing',
    ),
    choice(
      'pick-phone-media',
      'Media starts or stops playing',
      PhoneMoreKeys.mediaStarted,
      (c) => mediaTriggerForm(c, phone),
      subtitle: 'music or a video on this phone',
      keywords: 'music video spotify youtube',
    ),
    choice(
      'pick-phone-calendar',
      'A calendar event starts or ends',
      PhoneMoreKeys.calendarStarted,
      (c) => calendarTriggerForm(c, phone),
      subtitle: 'by words in its title',
      keywords: 'meeting agenda',
    ),
    choice(
      'pick-phone-shake',
      'The phone is shaken',
      PhoneMoreKeys.shaken,
      (c) => event(PhoneMoreKeys.shaken),
    ),
    choice(
      'pick-phone-facedown',
      'The phone is put face down',
      PhoneMoreKeys.faceDown,
      (c) => phoneMoreSwitchForm(c, phone, PhoneMoreKeys.faceDown),
      subtitle: 'or picked up again',
      keywords: 'flip table',
    ),
    choice(
      'pick-phone-headphones',
      'Wired headphones are plugged in',
      PhoneMoreKeys.headphones,
      (c) => phoneMoreSwitchForm(c, phone, PhoneMoreKeys.headphones),
      subtitle: 'or unplugged',
      keywords: 'headset earphones',
    ),
    choice(
      'pick-phone-boot',
      'The phone starts up',
      PhoneMoreKeys.startedUp,
      (c) => event(PhoneMoreKeys.startedUp),
      keywords: 'boot restart',
    ),
    choice(
      'pick-phone-install',
      'An app is installed or updated',
      PhoneMoreKeys.appInstalled,
      (c) => installTriggerForm(c, phone),
      keywords: 'new app update',
    ),
  ];
}

/// The form that changes a newer phone trigger, or null for another key.
Future<RuleTrigger?>? editPhoneMoreTrigger(
  BuildContext context,
  String phone,
  OnTrigger t,
) => switch (t.key) {
  PhoneMoreKeys.alarmSoon => alarmSoonTriggerForm(context, phone, t),
  _ when PhoneMoreKeys.calls.contains(t.key) => callTriggerForm(
    context,
    phone,
    t,
  ),
  _ when PhoneMoreKeys.media.contains(t.key) => mediaTriggerForm(
    context,
    phone,
    t,
  ),
  _ when PhoneMoreKeys.calendar.contains(t.key) => calendarTriggerForm(
    context,
    phone,
    t,
  ),
  _ when PhoneMoreKeys.switches.contains(t.key) => phoneMoreSwitchForm(
    context,
    phone,
    t.key,
    t,
  ),
  _ when PhoneMoreKeys.installs.contains(t.key) => installTriggerForm(
    context,
    phone,
    t,
  ),
  _ => null,
};

/// "20 minutes before my next alarm". The phone reports the alarm the
/// clock app set, and the engine times the trigger from it.
Future<OnTrigger?> alarmSoonTriggerForm(
  BuildContext context,
  String phone, [
  OnTrigger? current,
]) {
  final minutes = TextEditingController(
    text: '${current?.match?['minutes'] ?? 20}',
  );
  int? value() {
    final m = int.tryParse(minutes.text.trim());
    return m != null && m >= 1 && m <= 720 ? m : null;
  }

  return showFormSheet(
    context,
    owns: [minutes],
    title: 'Before my next alarm',
    subtitle:
        'Uses the next alarm in your clock app. Nothing happens on a day '
        'with no alarm.',
    whyNot: () => value() == null ? 'Minutes are 1 to 720' : null,
    result: () => switch (value()) {
      final m? => OnTrigger(
        thing: phone,
        key: PhoneMoreKeys.alarmSoon,
        mode: OnMode.event,
        match: {'minutes': m},
      ),
      null => null,
    },
    build: (context, setState) => [
      LabelledField(
        key: const ValueKey('phone-alarm-minutes'),
        label: 'Minutes before the alarm',
        controller: minutes,
        number: true,
        suffix: 'min',
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// A call ringing, being answered or ending. Asks for the phone state
/// permission the first time it is picked. The number is never read.
Future<OnTrigger?> callTriggerForm(
  BuildContext context,
  String phone, [
  OnTrigger? current,
]) async {
  if (current == null) await const Permissions().call('phoneState');
  if (!context.mounted) return null;
  var key = current?.key ?? PhoneMoreKeys.callRinging;
  return showFormSheet(
    context,
    title: 'A call',
    subtitle:
        'OmniFlow needs to know when a call starts and ends, which Android '
        'asks for once. It never reads who is calling.',
    result: () => OnTrigger(thing: phone, key: key, mode: OnMode.event),
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('phone-call-event'),
        segments: const [
          OmniSegment(PhoneMoreKeys.callRinging, 'Rings'),
          OmniSegment(PhoneMoreKeys.callAnswered, 'Answered'),
          OmniSegment(PhoneMoreKeys.callEnded, 'Ends'),
        ],
        selected: key,
        onChanged: (v) => setState(() => key = v),
      ),
    ],
  );
}

/// Media starting or stopping, from any app or a chosen one.
Future<OnTrigger?> mediaTriggerForm(
  BuildContext context,
  String phone, [
  OnTrigger? current,
]) {
  var key = current?.key ?? PhoneMoreKeys.mediaStarted;
  final app = TextEditingController(
    text: '${current?.match?['package'] ?? ''}',
  );
  return showFormSheet(
    context,
    owns: [app],
    title: 'Media on this phone',
    subtitle:
        'OmniFlow needs notification access to see what is playing, which '
        'Android asks for once.',
    result: () => OnTrigger(
      thing: phone,
      key: key,
      mode: OnMode.event,
      match: {
        ..._otherMatch(current, 'package'),
        'package': ?app.text.trim().nonEmptyOrNull,
      }.nonEmptyOrNull,
    ),
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('phone-media-event'),
        segments: const [
          OmniSegment(PhoneMoreKeys.mediaStarted, 'Starts'),
          OmniSegment(PhoneMoreKeys.mediaStopped, 'Stops'),
        ],
        selected: key,
        onChanged: (v) => setState(() => key = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      LabelledField(
        key: const ValueKey('phone-media-app'),
        label: 'App package name (empty for any app)',
        hint: 'com.spotify.music',
        controller: app,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// A calendar event with words in its title starting or ending. Asks for
/// calendar access the first time it is picked. Only the next 24 hours
/// are read, and only a matching title leaves the phone.
Future<OnTrigger?> calendarTriggerForm(
  BuildContext context,
  String phone, [
  OnTrigger? current,
]) async {
  if (current == null) await const Permissions().call('calendar');
  if (!context.mounted) return null;
  var key = current?.key ?? PhoneMoreKeys.calendarStarted;
  final words = TextEditingController(
    text: '${current?.match?['words'] ?? ''}',
  );
  String? typed() {
    final w = words.text.trim();
    return w.isEmpty || w.length > 60 ? null : w;
  }

  return showFormSheet(
    context,
    owns: [words],
    title: 'A calendar event',
    subtitle:
        'OmniFlow reads the next day of your calendar on this phone, which '
        'Android asks for once. Only the title of a matching event is used.',
    whyNot: () => typed() == null ? 'Type a word from the title' : null,
    result: () => switch (typed()) {
      final w? => OnTrigger(
        thing: phone,
        key: key,
        mode: OnMode.event,
        match: {'words': w},
      ),
      null => null,
    },
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('phone-calendar-event'),
        segments: const [
          OmniSegment(PhoneMoreKeys.calendarStarted, 'Starts'),
          OmniSegment(PhoneMoreKeys.calendarEnded, 'Ends'),
        ],
        selected: key,
        onChanged: (v) => setState(() => key = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      LabelledField(
        key: const ValueKey('phone-calendar-words'),
        label: 'Words in the title',
        hint: 'gym',
        controller: words,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// Face down or wired headphones, turning on, off, or either.
Future<OnTrigger?> phoneMoreSwitchForm(
  BuildContext context,
  String phone,
  String key, [
  OnTrigger? current,
]) {
  var to = current == null || !current.hasTo ? 'true' : '${current.to}';
  final faceDown = key == PhoneMoreKeys.faceDown;
  return showFormSheet(
    context,
    title: faceDown ? 'Face down' : 'Wired headphones',
    subtitle: faceDown
        ? 'OmniFlow reads the motion sensor only while an automation uses it.'
        : null,
    result: () => OnTrigger(
      thing: phone,
      key: key,
      to: to == 'true',
      hasTo: to != 'either',
    ),
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('phone-more-turns'),
        segments: [
          OmniSegment('true', faceDown ? 'Put face down' : 'Plugged in'),
          OmniSegment('false', faceDown ? 'Picked up' : 'Unplugged'),
          const OmniSegment('either', 'Either'),
        ],
        selected: to,
        onChanged: (v) => setState(() => to = v),
      ),
    ],
  );
}

/// An app installed or updated, any or a chosen package.
Future<OnTrigger?> installTriggerForm(
  BuildContext context,
  String phone, [
  OnTrigger? current,
]) {
  var key = current?.key ?? PhoneMoreKeys.appInstalled;
  final app = TextEditingController(
    text: '${current?.match?['package'] ?? ''}',
  );
  return showFormSheet(
    context,
    owns: [app],
    title: 'An app',
    result: () => OnTrigger(
      thing: phone,
      key: key,
      mode: OnMode.event,
      match: {
        ..._otherMatch(current, 'package'),
        'package': ?app.text.trim().nonEmptyOrNull,
      }.nonEmptyOrNull,
    ),
    build: (context, setState) => [
      OmniSegmented<String>(
        key: const ValueKey('phone-install-event'),
        segments: const [
          OmniSegment(PhoneMoreKeys.appInstalled, 'Installed'),
          OmniSegment(PhoneMoreKeys.appUpdated, 'Updated'),
        ],
        selected: key,
        onChanged: (v) => setState(() => key = v),
      ),
      const SizedBox(height: OmniSpace.sm),
      LabelledField(
        key: const ValueKey('phone-install-app'),
        label: 'App package name (empty for any app)',
        hint: 'com.example.app',
        controller: app,
        onChanged: (_) => setState(() {}),
      ),
    ],
  );
}

/// The apps on this phone by name, for an Open an app step's package.
Future<List<ParamChoice>> phoneAppChoices() async => [
  for (final a in await const InstalledApps().list())
    (value: a.package, label: a.label),
];
