import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart' show Json;
import '../../rules/rule_spec.dart';
import '../../rules/things.dart';
import '../design/design.dart';
import '../devices/device_text.dart' show appName;

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

/// "every day", "on weekdays", "on weekends" or "on Mon, Wed and Fri".
String daysText(List<String> days) {
  final set = days.toSet();
  if (set.isEmpty || set.length == 7) return 'every day';
  if (set.length == 5 && !set.contains('sat') && !set.contains('sun')) {
    return 'on weekdays';
  }
  if (set.length == 2 && set.containsAll(const ['sat', 'sun'])) {
    return 'on weekends';
  }
  final names = [
    for (final d in weekDays)
      if (set.contains(d)) dayName(d),
  ];
  return 'on ${andList(names)}';
}

/// "a", "a and b", "a, b and c".
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
    final labels = [
      for (final a in actions)
        if (a['type'] != 'dpad_remote' && !isHighRisk(a))
          '${a['label']}'.toLowerCase(),
    ];
    return labels.isEmpty
        ? 'takes no commands'
        : andList(labels.take(4).toList());
  }

  /// Whether any action runs commands on it (a shell, an uninstall).
  bool get hasHighRisk => actions.any(isHighRisk);
}

bool isHighRisk(Json capability) =>
    capability['highRisk'] == true || capability['type'] == 'exec';

/// Writes triggers, conditions and steps in plain words with the names of
/// the user's things. The household person reads as "I".
class RuleWords {
  RuleWords(this.things, [this.automations = const {}]);

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

  /// The household person when there is only one.
  String? get me => people.length == 1 ? people.single.id : null;

  String _who(String id) => id == me ? 'I' : (thing(id)?.name ?? id);

  String _name(String id) => thing(id)?.name ?? id;

  String _label(String id, String key) =>
      (thing(id)?.labelOf(key) ?? key).replaceAll('.', ' ').toLowerCase();

  /// " temperature" after a thing's name, or nothing when the thing reports
  /// one value only ("Room temperature goes above 28 °C").
  String _keyWords(String id, String key) {
    final keys = thing(id)?.stateKeys ?? const [];
    return keys.length <= 1 && keys.every((k) => k.key == key)
        ? ''
        : ' ${_label(id, key)}';
  }

  // Triggers.

  String trigger(RuleTrigger t) => switch (t) {
    OnTrigger() => _on(t),
    TimeTrigger() =>
      'At ${t.at}${t.days.isEmpty ? '' : ' ${daysText(t.days)}'}',
    SunTrigger() => sunText(t),
    IntervalTrigger() => 'Every ${durationText(t.seconds * 1000)}',
    ManualTrigger() => 'Only when I run it',
  };

  String _on(OnTrigger t) {
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
      OnMode.change =>
        t.hasTo
            ? '$name${_keyWords(t.thing, t.key)} changes to ${valueText(t.to, unit: unit)}'
            : '$name${_keyWords(t.thing, t.key)} changes',
    };
  }

  IconData triggerIcon(RuleTrigger t) => switch (t) {
    OnTrigger() when thing(t.thing)?.isPerson == true => OmniIcons.home,
    OnTrigger() when thing(t.thing)?.isTag == true => OmniIcons.tag,
    OnTrigger() => thing(t.thing)?.icon ?? OmniIcons.device,
    TimeTrigger() => OmniIcons.time,
    SunTrigger() => OmniIcons.sun,
    IntervalTrigger() => OmniIcons.repeat,
    ManualTrigger() => OmniIcons.action,
  };

  // Conditions.

  String condition(RuleCondition c) => switch (c) {
    CompareCondition(source: 'state') => _state(c),
    CompareCondition(source: 'var') =>
      '${c.ref.replaceFirst(r'$', '')} ${_op(c.op)} ${_value(c.value)}',
    CompareCondition() =>
      'The trigger\'s ${c.ref} ${_op(c.op)} ${_value(c.value)}',
    BetweenCondition() => 'Between ${c.start} and ${c.end}',
    DaysCondition() => _capital(daysText(c.days)),
    UnknownCondition() => 'A condition made outside this app',
  };

  String _state(CompareCondition c) {
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
    UnknownCondition() => OmniIcons.info,
  };

  // Steps.

  String step(RuleStep s) => switch (s) {
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

  /// "TV · power on", "Hall bulb · brightness 70%".
  String _do(String id, String capability, Json params) {
    final th = thing(id);
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
    return '${_name(id)} · $label${unitless.isEmpty ? '' : ' $unitless'}';
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
