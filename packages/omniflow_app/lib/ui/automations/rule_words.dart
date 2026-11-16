import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show daysWords;

import '../../api/engine_calls.dart' show Json;
import '../../api/rule_calls.dart' show RuleWordPiece, RuleWordsReply;
import '../../rules/house_words.dart';
import '../../rules/rule_spec.dart';
import '../../rules/things.dart';
import '../design/design.dart';
import '../devices/device_text.dart' show appName;
import 'phone_words.dart';
import 'rules_core_words.dart';

export 'rules_core_words.dart';

/// The icons the automation screens use beyond [OmniIcons], all Material
/// Symbols rounded.
abstract final class AutomationIcons {
  static const rule = Symbols.rule_rounded;
  static const link = Symbols.link_rounded;
  static const template = Symbols.auto_awesome_rounded;
  static const variable = Symbols.data_object_rounded;
  static const web = Symbols.public_rounded;
  static const together = Symbols.alt_route_rounded;
  static const keep = Symbols.lock_clock_rounded;
  static const days = Symbols.calendar_month_rounded;
  static const waitUntil = Symbols.hourglass_bottom_rounded;
  static const repeat = Symbols.repeat_rounded;
  static const fallback = Symbols.alt_route_rounded;
  static const pass = Symbols.check_circle_rounded;
  static const fail = Symbols.cancel_rounded;
  static const send = Symbols.arrow_forward_rounded;
  static const stop = Symbols.block_rounded;
  static const dot = Symbols.circle_rounded;
  static const ask = Symbols.quiz_rounded;
  static const get = Symbols.output_rounded;
  static const text = Symbols.text_fields_rounded;
  static const math = Symbols.calculate_rounded;
  static const date = Symbols.event_rounded;
  static const forEach = Symbols.data_array_rounded;
  static const phone = Symbols.smartphone_rounded;
  static const app = Symbols.apps_rounded;
  static const bluetooth = Symbols.bluetooth_rounded;
  static const screen = Symbols.screen_lock_portrait_rounded;
  static const dnd = Symbols.do_not_disturb_on_rounded;
  static const charging = Symbols.battery_charging_full_rounded;
  static const room = Symbols.meeting_room_rounded;
  static const look = Symbols.palette_rounded;
  static const list = Symbols.list_alt_rounded;
}

/// What a tap on part of a row's sentence edits.
enum Blank {
  device('device'),
  value('what it does'),
  duration('how long'),
  title('text'),
  time('time'),
  days('days'),
  start('start time'),
  end('end time'),
  automation('automation'),

  /// The step's whole form: steps with many fields.
  form('step');

  const Blank(this.words);

  /// For the screen reader: "Change device".
  final String words;
}

/// A piece of a row's sentence: plain words, or a [blank] a tap edits.
/// [token] is the inside of a `{{...}}` template it shows in words.
class WordPart {
  const WordPart(this.text, {this.blank, this.token});

  final String text;
  final Blank? blank;
  final String? token;
}

String joinParts(List<WordPart> parts) => parts.map((p) => p.text).join();

/// The phone's own triggers (contract section 6), in the words the trigger
/// picker offers them with.
abstract final class PhoneKeys {
  static const appOpened = 'app_opened';
  static const appClosed = 'app_closed';
  static const notification = 'notification';
  static const bluetoothConnected = 'bluetooth_connected';
  static const bluetoothDisconnected = 'bluetooth_disconnected';
  static const screenOn = 'screen_on';
  static const dndOn = 'dnd_on';
  static const charging = 'charging';

  static const events = {
    appOpened,
    appClosed,
    notification,
    bluetoothConnected,
    bluetoothDisconnected,
  };
  static const states = {screenOn, dndOn, charging};
}

const _dayNames = {
  'mon': 'Mon',
  'tue': 'Tue',
  'wed': 'Wed',
  'thu': 'Thu',
  'fri': 'Fri',
  'sat': 'Sat',
  'sun': 'Sun',
};

String dayName(String day) => _dayNames[day] ?? day;

/// "every day", "on weekdays", "on weekends" or "on Mon, Wed and Fri",
/// in the engine's words.
String daysText(List<String> days) => daysWords(days);

/// "a", "a or b", "a, b or c".
String orList(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.single,
  _ => '${items.sublist(0, items.length - 1).join(', ')} or ${items.last}',
};

/// "At sunset", "30 min before sunrise on weekdays".
String sunText(SunTrigger t) {
  final m = t.offsetMinutes.abs();
  final by = m == 0
      ? 'At ${t.event}'
      : '${durationText(m * 60000)} ${t.offsetMinutes < 0 ? 'before' : 'after'} '
            '${t.event}';
  return t.days.isEmpty ? by : '$by ${daysText(t.days)}';
}

extension on String {
  String? get nonEmpty => isEmpty ? null : this;
}

String andList(List<String> items) => switch (items.length) {
  0 => '',
  1 => items.single,
  _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
};

/// A state value in plain words: on/off for booleans.
String valueText(Object? v, {String? unit}) => switch (v) {
  true => 'on',
  false => 'off',
  null => 'nothing',
  final num n => unit == null ? _num(n) : '${_num(n)} ${unit.trim()}'.trim(),
  _ => '$v',
};

String _num(num n) => n == n.roundToDouble() ? '${n.round()}' : '$n';

/// What a thing can report or be told, read from its capabilities and state.
extension ThingWords on Thing {
  bool get isPerson => driver == 'person';
  bool get isTag => driver == 'nfc_tag';
  bool get isPlace => driver == 'place';
  bool get isPhone => driver == 'phone';

  /// The room it is in, by name, when it has one.
  String? get room => json['room'] as String?;

  IconData get icon => OmniIcons.forDevice(json);

  /// The unit of the reading at [key], when its capability names one.
  String? unitOf(String key) {
    for (final c in capabilities) {
      if (c['stateKey'] != key && c['id'] != key) continue;
      if (c['unit'] case final String unit) return unit;
      if ((c['params'] as Map?)?['value'] case final Map v) {
        if (v['unit'] case final String unit) return unit;
      }
    }
    return null;
  }

  /// Whether the state at [key] is on/off: a toggle reads it, or it is a
  /// boolean now.
  bool isOnOff(String key) =>
      capabilities.any((c) => c['type'] == 'toggle' && c['stateKey'] == key) ||
      state[key] is bool;

  /// Whether the state at [key] is a number: a level reads it, or it is a
  /// number now.
  bool isNumber(String key) =>
      capabilities.any(
        (c) =>
            const {'level', 'color_temp'}.contains(c['type']) &&
            c['stateKey'] == key,
      ) ||
      state[key] is num;

  /// The readings that are numbers, in words: brightness, volume.
  List<String> get numberLabels => [
    for (final k in stateKeys)
      if (!isOnOff(k.key) && isNumber(k.key)) k.label.toLowerCase(),
  ];

  /// One line on what it can report, for the trigger picker.
  String get reportsText {
    final numbers = numberLabels;
    final parts = <String>[
      for (final e in events) e.label.toLowerCase(),
      if (stateKeys.any((k) => isOnOff(k.key))) 'turns on or off',
      if (numbers.isNotEmpty) '${orList(numbers)} goes above or below',
      for (final k in stateKeys)
        if (!isOnOff(k.key) && !isNumber(k.key))
          '${k.label.toLowerCase()} changes',
    ];
    return parts.isEmpty ? 'reports nothing yet' : andList(parts);
  }

  /// One line on what it can be told, for the step picker.
  String get actionsText {
    final labels = <String>{
      for (final a in actions)
        if (a['type'] != 'dpad_remote' && !isHighRisk(a)) plainAction(a),
    };
    // A board that sends both reads as one kind of thing, not two.
    const codes = ['infrared codes', 'radio codes'];
    if (labels.containsAll(codes)) {
      labels
        ..removeAll(codes)
        ..add('infrared and radio codes');
    }
    return labels.isEmpty
        ? 'takes no commands'
        : andList(labels.take(4).toList());
  }

  /// Whether any action runs commands on it (a shell, an uninstall).
  bool get hasHighRisk => actions.any(isHighRisk);
}

/// What [capability] does in a person's words, from its type and label
/// rather than the protocol it uses: "on and off", "brightness",
/// "infrared codes" for "Send NEC IR (32-bit code, MSB first)".
String plainAction(Json capability) {
  final type = capability['type'];
  final id = '${capability['id'] ?? ''}'.toLowerCase();
  final label = '${capability['label'] ?? id}'
      .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
      .trim()
      .toLowerCase();
  bool names(String word) =>
      RegExp('(^|[^a-z])$word([^a-z]|\$)').hasMatch(id) ||
      RegExp('\\b$word\\b').hasMatch(label);
  if (names('ir') || names('infrared')) return 'infrared codes';
  if (names('rf') || label.contains('mhz')) return 'radio codes';
  return switch (type) {
    'toggle' when label == 'power' => 'on and off',
    'toggle' => '$label on and off',
    'color_rgb' => 'colour',
    _ when id == 'launch_app' => 'open apps',
    _ => label,
  };
}

bool isHighRisk(Json capability) =>
    capability['highRisk'] == true || capability['type'] == 'exec';

/// Writes triggers, conditions and steps in plain words with the names of
/// the user's things. The household person reads as "I".
class RuleWords {
  RuleWords(
    this.things, [
    this.automations = const {},
    Map<String, String>? tokenLabels,
    Map<String, List<RuleWordPiece>>? served,
  ]) : tokenLabels = tokenLabels ?? {},
       served = served ?? {};

  /// The engine's words for the parts of the rule being edited, from
  /// `rule.words`, by each part's JSON. A part found here reads exactly as
  /// the automation card and the diagram read it. The words below are
  /// only for a part the engine has not answered for yet.
  final Map<String, List<RuleWordPiece>> served;

  List<WordPart>? _served(Json part) {
    if (served.isEmpty) return null;
    final pieces = served[RuleWordsReply.keyOf(part)];
    if (pieces == null || pieces.isEmpty) return null;
    return [
      for (final p in pieces)
        WordPart(
          p.token == null ? p.text : (tokenLabels[p.token] ?? p.text),
          blank: Blank.values.where((b) => b.name == p.blank).firstOrNull,
          token: p.token,
        ),
    ];
  }

  String? _servedText(Json part) {
    final parts = _served(part);
    return parts == null ? null : joinParts(parts);
  }

  final List<Thing> things;

  /// Automation names by id, for run steps.
  final Map<String, String> automations;

  Thing? thing(String id) => things.where((t) => t.id == id).firstOrNull;

  late final List<Thing> people = [
    for (final t in things)
      if (t.isPerson) t,
  ];

  late final List<Thing> tags = [
    for (final t in things)
      if (t.isTag) t,
  ];

  /// The rooms the devices are in, by name, sorted.
  late final List<String> rooms = {for (final t in things) ?t.room}.toList()
    ..sort();

  /// The household person when there is only one.
  String? get me => people.length == 1 ? people.single.id : null;

  String _who(String id) => id == me ? 'I' : (thing(id)?.name ?? id);

  String _name(String id) =>
      thing(id)?.name ?? (id.startsWith('{{') ? templateText(id) : id);

  String _label(String id, String key) =>
      (thing(id)?.labelOf(key) ?? key).replaceAll('.', ' ').toLowerCase();

  /// A power reading with a fixed set of values (a TV's on, asleep or
  /// off), which reads as the thing itself: "Living room TV is asleep".
  bool _isPowerChoice(String id, String key) =>
      (thing(id)?.valuesOf(key).isNotEmpty ?? false) &&
      _label(id, key).trim() == 'power';

  /// " temperature" after a thing's name, or nothing when the thing reports
  /// one value only ("Room temperature goes above 28 °C").
  String _keyWords(String id, String key) {
    final keys = thing(id)?.stateKeys ?? const [];
    return keys.length <= 1 && keys.every((k) => k.key == key)
        ? ''
        : ' ${_label(id, key)}';
  }

  // Triggers.

  String trigger(RuleTrigger t) => _servedText(t.toJson()) ?? _trigger(t);

  String _trigger(RuleTrigger t) => switch (t) {
    OnTrigger(forMs: final int ms) when t.canHold => _held(t, ms),
    OnTrigger() => _on(t),
    TimeTrigger() =>
      'At ${t.at}${t.days.isEmpty ? '' : ' ${daysText(t.days)}'}',
    SunTrigger() => sunText(t),
    IntervalTrigger() => intervalText(t),
    ManualTrigger() => 'Only when I run it',
    PeopleTrigger() => peopleTriggerText(t),
    EngineStartTrigger() => 'When OmniFlow starts',
  };

  /// A state that has held for [ms]: "Front door has been on for 5 min",
  /// "I have been away for 10 min", "Room temperature has been above 28 °C
  /// for 15 min".
  String _held(OnTrigger t, int ms) {
    final how = durationText(ms);
    final th = thing(t.thing);
    if (th?.isPerson == true && t.key == 'home' && t.to is bool) {
      final who = _who(t.thing);
      final where = t.to == true ? 'home' : 'away';
      return who == 'I'
          ? 'I have been $where for $how'
          : '$who has been $where for $how';
    }
    final name = '${_name(t.thing)}${_keyWords(t.thing, t.key)}';
    final unit = th?.unitOf(t.key);
    if (t.mode == OnMode.crosses) {
      return t.above != null
          ? '$name has been above ${valueText(t.above, unit: unit)} for $how'
          : '$name has been below ${valueText(t.below, unit: unit)} for $how';
    }
    // An on or off reads as the thing itself, as "Desk lamp turns on" does.
    if (th?.isOnOff(t.key) == true && t.to is bool) {
      return '${_name(t.thing)} has been ${t.to == true ? 'on' : 'off'} '
          'for $how';
    }
    return '$name has been ${valueText(t.to, unit: unit)} for $how';
  }

  String _on(OnTrigger t) {
    if (houseTriggerText(t) case final words?) return words;
    final th = thing(t.thing);
    if (th?.isPerson == true && t.key == 'home' && t.mode == OnMode.change) {
      final who = _who(t.thing);
      final i = who == 'I';
      return switch (t.hasTo ? t.to : null) {
        true => i ? 'I get home' : '$who gets home',
        false => i ? 'I leave' : '$who leaves',
        _ => i ? 'I get home or leave' : '$who gets home or leaves',
      };
    }
    if (th?.isTag == true && t.mode == OnMode.event) {
      return '${_name(t.thing)} is scanned';
    }
    if (th?.isPhone == true) {
      if (_phone(t) case final words?) return words;
    }
    final name = _name(t.thing);
    final unit = th?.unitOf(t.key);
    return switch (t.mode) {
      OnMode.event => '$name ${_label(t.thing, t.key)}',
      OnMode.crosses =>
        t.above != null
            ? '$name${_keyWords(t.thing, t.key)} goes above ${valueText(t.above, unit: unit)}'
            : '$name${_keyWords(t.thing, t.key)} goes below ${valueText(t.below, unit: unit)}',
      OnMode.change when th?.isOnOff(t.key) == true => switch (t.hasTo
          ? t.to
          : null) {
        true => '$name turns on',
        false => '$name turns off',
        _ => '$name turns on or off',
      },
      OnMode.change when t.to is String && _isPowerChoice(t.thing, t.key) =>
        t.to == 'asleep' ? '$name falls asleep' : '$name turns ${t.to}',
      OnMode.change =>
        t.hasTo
            ? '$name${_keyWords(t.thing, t.key)} changes to ${valueText(t.to, unit: unit)}'
            : '$name${_keyWords(t.thing, t.key)} changes',
    };
  }

  /// The phone's triggers in words, or null for a key it has no words for.
  String? _phone(OnTrigger t) {
    final match = t.match ?? const {};
    final app = match['package'] is String
        ? appName(match['package'] as String)
        : null;
    final device = match['name'] as String?;
    String turns(String what) => switch (t.hasTo ? t.to : null) {
      true => '$what turns on',
      false => '$what turns off',
      _ => '$what turns on or off',
    };
    return switch (t.key) {
      PhoneKeys.appOpened => app == null ? 'An app opens' : '$app opens',
      PhoneKeys.appClosed => app == null ? 'An app closes' : '$app closes',
      PhoneKeys.notification =>
        app == null
            ? 'A notification arrives'
            : 'A notification arrives from $app',
      PhoneKeys.bluetoothConnected =>
        device == null ? 'A Bluetooth device connects' : '$device connects',
      PhoneKeys.bluetoothDisconnected =>
        device == null
            ? 'A Bluetooth device disconnects'
            : '$device disconnects',
      PhoneKeys.screenOn => turns('The screen'),
      PhoneKeys.dndOn => turns('Do Not Disturb'),
      PhoneKeys.charging => switch (t.hasTo ? t.to : null) {
        true => 'The phone starts charging',
        false => 'The phone stops charging',
        _ => 'The phone starts or stops charging',
      },
      _ => phoneMoreTriggerText(t),
    };
  }

  IconData _phoneIcon(String key) => switch (key) {
    PhoneKeys.appOpened || PhoneKeys.appClosed => AutomationIcons.app,
    PhoneKeys.notification => OmniIcons.notifications,
    PhoneKeys.bluetoothConnected ||
    PhoneKeys.bluetoothDisconnected => AutomationIcons.bluetooth,
    PhoneKeys.screenOn => AutomationIcons.screen,
    PhoneKeys.dndOn => AutomationIcons.dnd,
    PhoneKeys.charging => AutomationIcons.charging,
    _ => phoneMoreTriggerIcon(key) ?? AutomationIcons.phone,
  };

  /// The phone thing, when the engine lists one.
  Thing? get phone => things.where((t) => t.isPhone).firstOrNull;

  IconData triggerIcon(RuleTrigger t) => switch (t) {
    OnTrigger() when thing(t.thing)?.isPhone == true => _phoneIcon(t.key),
    OnTrigger() when isHouseThing(t.thing) =>
      t.thing == 'timers' ? OmniIcons.wait : OmniIcons.home,
    OnTrigger() when thing(t.thing)?.isPerson == true => OmniIcons.home,
    OnTrigger() when thing(t.thing)?.isTag == true => OmniIcons.tag,
    OnTrigger() => thing(t.thing)?.icon ?? OmniIcons.device,
    TimeTrigger() => OmniIcons.time,
    SunTrigger() => OmniIcons.sun,
    IntervalTrigger() => OmniIcons.repeat,
    ManualTrigger() => OmniIcons.action,
    PeopleTrigger() => OmniIcons.home,
    EngineStartTrigger() => engineStartIcon,
  };

  // Conditions.

  String condition(RuleCondition c) => _servedText(c.toJson()) ?? _condition(c);

  String _condition(RuleCondition c) => switch (c) {
    CompareCondition(source: 'state') => _state(c),
    CompareCondition(source: 'var') =>
      '${c.ref.replaceFirst(r'$', '')} ${_op(c.op)} ${_value(c.value)}',
    CompareCondition() =>
      'The trigger\'s ${c.ref} ${_op(c.op)} ${_value(c.value)}',
    BetweenCondition() => 'Between ${c.start} and ${c.end}',
    DaysCondition() => _capital(daysText(c.days)),
    PeopleCondition() => peopleConditionText(c),
    UnknownCondition() => 'A condition made outside this app',
  };

  String _state(CompareCondition c) {
    if (houseConditionText(c) case final words?) return words;
    final (id, key) = splitRef(c.ref);
    final th = thing(id);
    if (th?.isPerson == true && key == 'home' && c.value is bool) {
      final home = (c.op == '==') == (c.value == true);
      final who = _who(id);
      final verb = who == 'I' ? 'am' : 'is';
      return '$who $verb ${home ? 'home' : 'away'}';
    }
    final name = _name(id);
    if (th?.isOnOff(key) == true && c.value is bool) {
      final on = (c.op == '==') == (c.value == true);
      return '$name is ${on ? 'on' : 'off'}';
    }
    if (c.value is String &&
        (c.op == '==' || c.op == '!=') &&
        _isPowerChoice(id, key)) {
      return '$name ${_op(c.op)} ${c.value}';
    }
    if (key == 'app' && c.op == '==' && c.value is String) {
      return '$name is on ${appName(c.value as String)}';
    }
    return '$name${_keyWords(id, key)} ${_op(c.op)} '
        '${_value(c.value, unit: th?.unitOf(key))}';
  }

  String _op(String op) => switch (op) {
    '>' => 'is above',
    '<' => 'is below',
    '>=' => 'is at least',
    '<=' => 'is at most',
    '!=' => 'is not',
    _ => 'is',
  };

  String _value(Object? v, {String? unit}) => switch (v) {
    {'state': final String ref} => () {
      final (id, key) = splitRef(ref);
      return '${_name(id)} ${_label(id, key)}';
    }(),
    {'var': final name} => '$name'.replaceFirst(r'$', ''),
    {'msg': final key} => 'the trigger\'s $key',
    _ => valueText(v, unit: unit),
  };

  IconData conditionIcon(RuleCondition c) => switch (c) {
    CompareCondition(source: 'state') => () {
      final th = thing(splitRef(c.ref).$1);
      return th?.isPerson == true
          ? OmniIcons.person
          : th?.icon ?? OmniIcons.device;
    }(),
    CompareCondition() => AutomationIcons.variable,
    BetweenCondition() => OmniIcons.time,
    DaysCondition() => AutomationIcons.days,
    PeopleCondition() => OmniIcons.person,
    UnknownCondition() => OmniIcons.info,
  };

  // Tokens: values from the trigger and earlier steps, as `{{...}}`.

  /// Labels the engine gave for tokens (`%reply.body` -> "Web reply ·
  /// body"), filled as `rule.tokens` answers arrive.
  final Map<String, String> tokenLabels;

  /// A token in words: the engine's label, or its name in plain words.
  String tokenText(String inside) {
    if (tokenLabels[inside] case final label?) return label;
    final parts = inside.split('.');
    final head = parts.first;
    final name = switch (head) {
      'msg' => 'Trigger',
      '%reply' => 'Web reply',
      '%answer' => 'Answer',
      '%state' => 'New state',
      _ when head.startsWith('%') || head.startsWith(r'$') => _capital(
        head.substring(1).replaceAll('_', ' '),
      ),
      _ => head,
    };
    final rest = parts.skip(1).join(' ');
    return rest.isEmpty ? name : '$name · $rest';
  }

  static final _template = RegExp(r'\{\{([^{}]+)\}\}');

  /// [text] split into plain words and its `{{...}}` tokens in words, each
  /// part marked as the [blank] it edits.
  List<WordPart> templateParts(String text, {Blank? blank}) {
    final out = <WordPart>[];
    var at = 0;
    for (final m in _template.allMatches(text)) {
      if (m.start > at) {
        out.add(WordPart(text.substring(at, m.start), blank: blank));
      }
      final inside = m.group(1)!.trim();
      out.add(WordPart(tokenText(inside), blank: blank, token: inside));
      at = m.end;
    }
    if (at < text.length || out.isEmpty) {
      out.add(WordPart(text.substring(at), blank: blank));
    }
    return out;
  }

  /// [text] with its tokens in words.
  String templateText(String text) => joinParts(templateParts(text));

  // Sentences with blanks.

  /// A trigger as words, with the parts a tap edits on their own.
  List<WordPart> triggerParts(RuleTrigger t) =>
      _served(t.toJson()) ?? _triggerParts(t);

  List<WordPart> _triggerParts(RuleTrigger t) => switch (t) {
    TimeTrigger() => [
      const WordPart('At '),
      WordPart(t.at, blank: Blank.time),
      if (t.days.isNotEmpty) ...[
        const WordPart(' '),
        WordPart(daysText(t.days), blank: Blank.days),
      ],
    ],
    _ => [WordPart(trigger(t))],
  };

  /// A condition as words, with the parts a tap edits on their own.
  List<WordPart> conditionParts(RuleCondition c) =>
      _served(c.toJson()) ?? _conditionParts(c);

  List<WordPart> _conditionParts(RuleCondition c) => switch (c) {
    BetweenCondition() => [
      const WordPart('Between '),
      WordPart(c.start, blank: Blank.start),
      const WordPart(' and '),
      WordPart(c.end, blank: Blank.end),
    ],
    _ => [WordPart(condition(c))],
  };

  /// A step as words, with the parts a tap edits on their own: the device,
  /// what it does, how long, the text. [step] is these parts joined.
  List<WordPart> stepParts(RuleStep s) => _served(s.toJson()) ?? _stepParts(s);

  List<WordPart> _stepParts(RuleStep s) => switch (s) {
    DoStep() when houseStepText(s) != null => [
      WordPart(houseStepText(s)!, blank: Blank.form),
    ],
    DoStep() when isEachDevice(s.thing) => [
      WordPart(eachDo(s.capability, s.params)),
    ],
    DoStep() => [
      WordPart(_name(s.thing), blank: Blank.device),
      const WordPart(' · '),
      WordPart(_doWhat(s.thing, s.capability, s.params), blank: Blank.value),
    ],
    ToggleStep() => [
      const WordPart('Toggle '),
      WordPart(_name(s.thing), blank: Blank.device),
      WordPart(_capSuffix(s.thing, s.capability)),
    ],
    WaitStep() => [
      const WordPart('Wait '),
      WordPart(durationText(s.ms), blank: Blank.duration),
    ],
    NotifyStep() => [
      const WordPart('Notify: '),
      ...templateParts(s.title, blank: Blank.title),
    ],
    SetStep() => [
      WordPart(
        'Set ${s.name.replaceFirst(RegExp(r'^[$%]'), '')} to ',
        blank: Blank.form,
      ),
      if (s.value case final String v)
        ...templateParts(v, blank: Blank.value)
      else
        WordPart(valueText(s.value), blank: Blank.value),
    ],
    RunStep() => [
      const WordPart('Run '),
      WordPart(
        automations[s.automationId] ?? s.automationId,
        blank: Blank.automation,
      ),
    ],
    AskStep() => [
      const WordPart('Ask: '),
      ...templateParts(s.title, blank: Blank.form),
      WordPart(
        s.asksForText
            ? ', and wait for a reply'
            : ', with ${orList(s.choices)}',
      ),
    ],
    GetStep() => [
      const WordPart('Get '),
      WordPart(s.path.isEmpty ? 'the value' : s.path, blank: Blank.form),
      const WordPart(' from '),
      ...templateParts(s.from, blank: Blank.form),
    ],
    TextStep() => [
      const WordPart('Make text '),
      ...templateParts(s.value, blank: Blank.form),
      if (_textOps[s.op] case final op?) WordPart(' $op'),
    ],
    MathStep() => [
      const WordPart('Work out '),
      ...templateParts(s.expr, blank: Blank.form),
    ],
    DateStep() => [
      const WordPart('Get the time '),
      if ((s.offsetMinutes ?? 0) != 0)
        WordPart(
          '${durationText(s.offsetMinutes!.abs() * 60000)} '
          '${s.offsetMinutes! < 0 ? 'ago ' : 'from now '}',
        ),
      const WordPart('as '),
      WordPart(s.format, blank: Blank.form),
    ],
    ForEachStep() => [
      const WordPart('Repeat with each '),
      ...switch (s.over) {
        _ when s.room != null => [
          const WordPart('device in '),
          WordPart(s.room!, blank: Blank.form),
        ],
        final List items => [
          const WordPart('of '),
          WordPart(andList([for (final i in items) valueText(i)])),
        ],
        final String over => [
          const WordPart('item in '),
          ...templateParts(over, blank: Blank.form),
        ],
        _ => [const WordPart('item')],
      },
    ],
    _ => [WordPart(_plainStep(s))],
  };

  static const _textOps = {
    'upper': 'in capitals',
    'lower': 'in small letters',
    'trim': 'without spaces at the ends',
  };

  // Steps.

  String step(RuleStep s) => joinParts(stepParts(s));

  String _plainStep(RuleStep s) => switch (s) {
    DoStep() => _do(s.thing, s.capability, s.params),
    ToggleStep() =>
      'Toggle ${_name(s.thing)}${_capSuffix(s.thing, s.capability)}',
    WaitStep() => 'Wait ${durationText(s.ms)}',
    WaitForStep() => 'Wait until ${_lower(trigger(s.until))}',
    IfStep() =>
      s.conditions.isEmpty
          ? 'If…'
          : 'If ${_lower(condition(s.conditions.first))}'
                '${s.conditions.length > 1 ? ' and ${s.conditions.length - 1} more' : ''}…',
    TogetherStep() => 'Do these together',
    TryStep() =>
      s.otherwise.isEmpty
          ? 'Try these, and go on if one fails'
          : 'Try these, with a fallback',
    RepeatStep() => 'Repeat ${repeatHow(s)}',
    NotifyStep() => 'Notify: ${s.title}',
    HttpStep() =>
      'Send ${s.method} to ${Uri.tryParse(s.url)?.host.nonEmpty ?? s.url}',
    SetStep() =>
      'Set ${s.name.replaceFirst(RegExp(r'^[$%]'), '')} to ${valueText(s.value)}',
    RunStep() => 'Run ${automations[s.automationId] ?? s.automationId}',
    KeepStep() => keep(s),
    AskStep() ||
    GetStep() ||
    TextStep() ||
    MathStep() ||
    DateStep() ||
    ForEachStep() => joinParts(stepParts(s)),
    UnknownStep() => 'A step made outside this app',
  };

  String keep(KeepStep s) {
    final target = _targetText(s.thing, s.capability, s.value);
    final holds = s.whileConditions.isEmpty
        ? '…'
        : ' while ${andList([for (final c in s.whileConditions) _lower(condition(c))])}';
    return 'Keep $target$holds';
  }

  String _targetText(String id, String capability, Object? value) {
    final th = thing(id);
    final cap = th?.capability(capability);
    final name = _name(id);
    if (cap?['type'] == 'toggle' && value is bool) {
      return '$name ${value ? 'on' : 'off'}';
    }
    return '$name ${'${cap?['label'] ?? capability}'.toLowerCase()} '
        '${valueText(value, unit: _paramUnit(cap, 'value'))}';
  }

  String _capSuffix(String id, String capability) {
    final caps = thing(id)?.toggles ?? const [];
    if (caps.length <= 1) return '';
    final label = thing(id)?.capability(capability)?['label'];
    return ' ${'${label ?? capability}'.toLowerCase()}';
  }

  static final _runDevice = RegExp(r'^\{\{\s*%[A-Za-z_][A-Za-z0-9_]*\s*\}\}$');

  /// Whether a step names its device through a run variable, `{{%item}}`:
  /// each device of a room in a Repeat with each.
  static bool isEachDevice(String thing) => _runDevice.hasMatch(thing);

  /// What a step does to each device of a room: "Turn each device on",
  /// "Set each device's brightness to 40%", "Wake on each device". The
  /// label comes from any device that has [capability].
  String eachDo(String capability, Json params) {
    final cap = things
        .map((t) => t.capability(capability))
        .nonNulls
        .firstOrNull;
    final label = '${cap?['label'] ?? capability}'
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        .toLowerCase();
    final value = params['value'];
    if (cap?['type'] == 'toggle' && value is bool && params.length == 1) {
      final onOff = value ? 'on' : 'off';
      return label == 'power'
          ? 'Turn each device $onOff'
          : "Turn each device's $label $onOff";
    }
    if (value != null && params.length == 1) {
      final to = valueText(value, unit: _paramUnit(cap, 'value'));
      return "Set each device's $label to ${to.replaceAll(' %', '%')}";
    }
    final what = label.isEmpty
        ? capability
        : '${label[0].toUpperCase()}${label.substring(1)}';
    final shown = [
      for (final e in params.entries) '${e.key} ${valueText(e.value)}',
    ];
    return '$what on each device${shown.isEmpty ? '' : ', ${shown.join(', ')}'}';
  }

  /// "TV · power on", "Hall bulb · brightness 70%".
  String _do(String id, String capability, Json params) => isEachDevice(id)
      ? eachDo(capability, params)
      : '${_name(id)} · ${_doWhat(id, capability, params)}';

  /// "power on", "brightness 70%": what a do step tells the device.
  String _doWhat(String id, String capability, Json params) {
    final th = thing(id);
    if (th?.isPhone == true) {
      if (phoneStepWhat(capability, params) case final words?) return words;
    }
    final cap = th?.capability(capability);
    final label = '${cap?['label'] ?? capability}'.toLowerCase();
    final shown = [
      for (final e in params.entries)
        if (e.key == 'value')
          valueText(e.value, unit: _paramUnit(cap, e.key))
        else
          '${e.key} ${valueText(e.value, unit: _paramUnit(cap, e.key))}',
    ];
    final unitless = shown.map((p) => p.replaceAll(' %', '%')).join(', ');
    return '$label${unitless.isEmpty ? '' : ' $unitless'}';
  }

  static String? _paramUnit(Json? cap, String key) {
    final spec = (cap?['params'] as Map?)?[key];
    return spec is Map ? spec['unit'] as String? : null;
  }

  /// How often a repeat runs: "up to 10 times, every 3 s, until TV is on".
  String repeatHow(RepeatStep s) => [
    if (s.times case final n?) s.until.isEmpty ? '$n times' : 'up to $n times',
    if (s.everyMs > 0) 'every ${durationText(s.everyMs)}',
    if (s.until.isNotEmpty)
      'until ${[for (final c in s.until) _lower(condition(c))].join(' and ')}',
  ].join(', ');

  IconData stepIcon(RuleStep s) => switch (s) {
    DoStep() => thing(s.thing)?.icon ?? OmniIcons.device,
    ToggleStep() => thing(s.thing)?.icon ?? OmniIcons.power,
    WaitStep() => OmniIcons.wait,
    WaitForStep() => AutomationIcons.waitUntil,
    IfStep() => OmniIcons.branch,
    TogetherStep() => AutomationIcons.together,
    TryStep() => AutomationIcons.fallback,
    RepeatStep() => AutomationIcons.repeat,
    NotifyStep() => OmniIcons.notifications,
    HttpStep() => AutomationIcons.web,
    SetStep() => AutomationIcons.variable,
    RunStep() => OmniIcons.automations,
    KeepStep() => AutomationIcons.keep,
    AskStep() => AutomationIcons.ask,
    GetStep() => AutomationIcons.get,
    TextStep() => AutomationIcons.text,
    MathStep() => AutomationIcons.math,
    DateStep() => AutomationIcons.date,
    ForEachStep() => AutomationIcons.forEach,
    UnknownStep() => OmniIcons.info,
  };

  /// The rule written as one line, for a review or a template preview.
  String sentence(RuleSpec rule) {
    final when = [for (final t in rule.when) trigger(t)];
    final onlyIf = [for (final c in rule.onlyIf) _lower(condition(c))];
    final then = [for (final s in rule.then) _lower(step(s))];
    return [
      if (when.isNotEmpty) 'When ${_lower(when.join(' or '))}',
      if (onlyIf.isNotEmpty) 'only if ${andList(onlyIf)}',
      if (then.isNotEmpty) then.join(', then '),
    ].join(', ');
  }

  /// [s] with its first letter lowered for the middle of a sentence, unless
  /// it starts with "I" or an acronym ("TV").
  static String _lower(String s) {
    if (s.isEmpty || s.startsWith('I ') || s == 'I') return s;
    if (s.length > 1 && s[1].toUpperCase() == s[1] && s[1] != ' ') return s;
    return '${s[0].toLowerCase()}${s.substring(1)}';
  }

  static String _capital(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
