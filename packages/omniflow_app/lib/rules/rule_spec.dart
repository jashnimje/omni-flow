import '../api/engine_calls.dart' show Json;

/// The rule form of an automation in the object form the engine stores
/// (`normalizeRule` in the engine's `dag/rules.dart`), as `automation.save`
/// takes it and `automation.get` returns it: when any of [when] happens,
/// and all of [onlyIf] hold, run [then] in order. The engine compiles and
/// checks it. The builder edits this object in place and rebuilds.
///
/// ```json
/// {"id"?: "evening", "name": "Evening", "when": [Trigger],
///  "onlyIf": [Condition], "then": [Step], "mode"?: ..., "cooldownSeconds"?: n}
/// ```
class RuleSpec {
  RuleSpec({
    this.name = '',
    List<RuleTrigger>? when,
    List<RuleCondition>? onlyIf,
    List<RuleStep>? then,
    Json? extra,
  }) : when = when ?? [],
       onlyIf = onlyIf ?? [],
       then = then ?? [],
       extra = extra ?? {};

  factory RuleSpec.fromJson(Json json) => RuleSpec(
    name: '${json['name'] ?? ''}',
    when: [for (final t in _maps(json['when'])) RuleTrigger.fromJson(t)],
    onlyIf: [for (final c in _maps(json['onlyIf'])) RuleCondition.fromJson(c)],
    then: RuleStep.listFromJson(json['then']),
    extra: {
      for (final e in json.entries)
        if (!const {'name', 'when', 'onlyIf', 'then'}.contains(e.key))
          e.key: e.value,
    },
  );

  String name;
  final List<RuleTrigger> when;
  final List<RuleCondition> onlyIf;
  final List<RuleStep> then;

  /// The root keys the builder does not edit (`id`, `mode`,
  /// `cooldownSeconds`, `enabled`), kept so saving does not drop them.
  final Json extra;

  /// Whether every list the rule form needs filled has something in it: a
  /// trigger and a step, and in each If a condition and a THEN step, and a
  /// step in each Do together branch. A rule of keep steps alone needs no
  /// trigger, since each keep watches its own conditions.
  bool get complete => (when.isNotEmpty || onlyKeeps) && stepsComplete(then);

  /// Whether [then] is all keep steps.
  bool get onlyKeeps => then.isNotEmpty && then.every((s) => s is KeepStep);

  /// Whether the first failed step stops the rest. Without it every step
  /// runs and failures go to the run log.
  bool get stopOnError => extra['stopOnError'] == true;
  set stopOnError(bool stop) =>
      stop ? extra['stopOnError'] = true : extra.remove('stopOnError');

  Json toJson() => {
    ...extra,
    'name': name,
    'when': [for (final t in when) t.toJson()],
    if (onlyIf.isNotEmpty) 'onlyIf': [for (final c in onlyIf) c.toJson()],
    'then': [for (final s in then) s.toJson()],
  };
}

/// Whether [steps] has a step, and each If and Do together in it is filled.
bool stepsComplete(List<RuleStep> steps) =>
    steps.isNotEmpty &&
    steps.every(
      (s) => switch (s) {
        IfStep() =>
          s.conditions.isNotEmpty &&
              stepsComplete(s.then) &&
              (s.otherwise.isEmpty || stepsComplete(s.otherwise)),
        TogetherStep() => s.branches.every(stepsComplete),
        WaitForStep() => s.onTimeout.isEmpty || stepsComplete(s.onTimeout),
        KeepStep() => s.whileConditions.isNotEmpty,
        _ => true,
      },
    );

List<Json> _maps(Object? list) => [
  for (final m in (list as List? ?? const []))
    if (m is Map) Map<String, Object?>.from(m),
];

const weekDays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

enum OnMode { change, event, crosses }

/// What starts a rule:
///
/// - `{"on": "thing.key", "change": {"to"?: v}}`: the state key changed.
/// - `{"on": "thing.key", "event": true, "match"?: {...}}`: the thing raised
///   the event `key`.
/// - `{"on": "thing.key", "crosses": {"above" | "below": n}}`.
/// - `{"time": "HH:MM", "days"?: ["mon", ...]}`.
/// - `{"interval": seconds}`.
/// - `{"manual": true}`: only when run by hand.
sealed class RuleTrigger {
  const RuleTrigger();

  factory RuleTrigger.fromJson(Json json) {
    if (json['time'] case final String at) {
      return TimeTrigger(at, days: [...?(json['days'] as List?)?.cast()]);
    }
    if (json['interval'] case final num seconds) {
      return IntervalTrigger(seconds.toInt());
    }
    if (json['manual'] == true) return const ManualTrigger();
    return OnTrigger.fromJson(json);
  }

  Json toJson();
}

class OnTrigger extends RuleTrigger {
  OnTrigger({
    required this.thing,
    required this.key,
    this.mode = OnMode.change,
    this.to,
    this.hasTo = false,
    this.match,
    this.above,
    this.below,
  });

  factory OnTrigger.fromJson(Json json) {
    final (thing, key) = splitRef('${json['on'] ?? ''}');
    if (json['event'] == true) {
      return OnTrigger(
        thing: thing,
        key: key,
        mode: OnMode.event,
        match: (json['match'] as Map?)?.cast(),
      );
    }
    if (json['crosses'] case final Map crosses) {
      return OnTrigger(
        thing: thing,
        key: key,
        mode: OnMode.crosses,
        above: crosses['above'] as num?,
        below: crosses['below'] as num?,
      );
    }
    final change = json['change'] is Map ? json['change'] as Map : const {};
    return OnTrigger(
      thing: thing,
      key: key,
      to: change['to'],
      hasTo: change.containsKey('to'),
    );
  }

  String thing;
  String key;
  OnMode mode;

  /// The value a change must reach, when [hasTo]. A change to null is a
  /// real choice, so presence is kept apart from the value.
  Object? to;
  bool hasTo;
  Map<String, Object?>? match;
  num? above;
  num? below;

  String get ref => '$thing.$key';

  @override
  Json toJson() => {
    'on': ref,
    ...switch (mode) {
      OnMode.change => {
        'change': {if (hasTo) 'to': to},
      },
      OnMode.event => {'event': true, 'match': ?match},
      OnMode.crosses => {
        'crosses': above != null ? {'above': above} : {'below': below},
      },
    },
  };
}

class TimeTrigger extends RuleTrigger {
  TimeTrigger(this.at, {List<String>? days}) : days = days ?? [];

  String at;
  final List<String> days;

  @override
  Json toJson() => {'time': at, if (days.isNotEmpty) 'days': days};
}

class IntervalTrigger extends RuleTrigger {
  IntervalTrigger(this.seconds);

  int seconds;

  @override
  Json toJson() => {'interval': seconds};
}

class ManualTrigger extends RuleTrigger {
  const ManualTrigger();

  @override
  Json toJson() => {'manual': true};
}

/// What must hold for a rule to go on:
///
/// - `{"state": "thing.key" | "var": "$Name" | "msg": "key", "op": "==",
///   "value": v}`, where `v` is a literal or `{"state" | "var" | "msg": ...}`
/// - `{"between": ["HH:MM", "HH:MM"]}`, across midnight when the first is
///   later
/// - `{"days": ["sat", "sun"]}`
/// - `{"not": ...}`, `{"anyOf": [...]}`, `{"allOf": [...]}`, kept as written
sealed class RuleCondition {
  const RuleCondition();

  factory RuleCondition.fromJson(Json json) {
    if (json['between'] case [final String start, final String end]) {
      return BetweenCondition(start, end);
    }
    if (json['days'] case final List days) {
      return DaysCondition(days.cast());
    }
    for (final source in CompareCondition.sources) {
      if (json[source] case final String ref) {
        return CompareCondition(
          source,
          ref,
          '${json['op'] ?? '=='}',
          json['value'],
        );
      }
    }
    return UnknownCondition(json);
  }

  Json toJson();
}

class CompareCondition extends RuleCondition {
  CompareCondition(this.source, this.ref, this.op, this.value);

  static const sources = ['state', 'var', 'msg'];

  /// `state` (a thing's current state, [ref] `thing.key`), `var` or `msg`.
  String source;
  String ref;
  String op;
  Object? value;

  @override
  Json toJson() => {source: ref, 'op': op, 'value': value};
}

class BetweenCondition extends RuleCondition {
  BetweenCondition(this.start, this.end);

  String start;
  String end;

  @override
  Json toJson() => {
    'between': [start, end],
  };
}

class DaysCondition extends RuleCondition {
  DaysCondition(List<String> days) : days = [...days];

  final List<String> days;

  @override
  Json toJson() => {'days': days};
}

/// A condition the builder shows but does not edit (`not`, `anyOf`,
/// `allOf`), kept as it came.
class UnknownCondition extends RuleCondition {
  const UnknownCondition(this.json);

  final Json json;

  @override
  Json toJson() => json;
}

/// One step of a rule:
///
/// - `{"do": "thing.capability", "params"?: {...}}`
/// - `{"toggle": "thing.capability"}`
/// - `{"wait": ms}`
/// - `{"waitFor": {"on": ..., "change" | "event" | "crosses": ...,
///   "timeoutMs": n, "onTimeout"?: [Step]}}`: the steps after it run when
///   it matches, `onTimeout` when the time runs out, and then the rule ends
/// - `{"if": [Condition], "then": [Step], "else"?: [Step]}`
/// - `{"together": [[Step], [Step], ...]}`: two or more branches at once
/// - `{"notify": {"title": "...", "body"?: "..."}}`
/// - `{"set": {"var": "$Name", "value": v}}`
/// - `{"run": "automation id"}`
sealed class RuleStep {
  const RuleStep();

  static List<RuleStep> listFromJson(Object? list) => [
    for (final s in _maps(list)) RuleStep.fromJson(s),
  ];

  factory RuleStep.fromJson(Json json) {
    if (json['do'] case final String ref) {
      final (thing, capability) = splitRef(ref);
      return DoStep(
        thing,
        capability,
        params: Map<String, Object?>.from(json['params'] as Map? ?? const {}),
      );
    }
    if (json['toggle'] case final String ref) {
      final (thing, capability) = splitRef(ref);
      return ToggleStep(thing, capability);
    }
    if (json['wait'] case final num ms) return WaitStep(ms.toInt());
    if (json['waitFor'] case final Map wait) {
      final w = Map<String, Object?>.from(wait);
      return WaitForStep(
        OnTrigger.fromJson(w),
        timeoutMs: (w['timeoutMs'] as num? ?? 60000).toInt(),
        onTimeout: listFromJson(w['onTimeout']),
      );
    }
    if (json.containsKey('if')) {
      final conditions = json['if'] is Map ? [json['if']] : json['if'];
      return IfStep(
        conditions: [
          for (final c in _maps(conditions)) RuleCondition.fromJson(c),
        ],
        then: listFromJson(json['then']),
        otherwise: listFromJson(json['else']),
      );
    }
    if (json['together'] case final List branches) {
      return TogetherStep([for (final b in branches) listFromJson(b)]);
    }
    if (json['notify'] case final String title) return NotifyStep(title);
    if (json['notify'] case final Map n) {
      final payload = Map<String, Object?>.from(n);
      return NotifyStep(
        '${payload.remove('title') ?? ''}',
        body: payload.remove('body') as String?,
        extra: payload,
      );
    }
    if (json['set'] case final Map s) return SetStep('${s['var']}', s['value']);
    if (json['run'] case final String id) return RunStep(id);
    if (json['keep'] case final Map keep) {
      final k = Map<String, Object?>.from(keep);
      final (thing, capability) = splitRef('${k['target'] ?? ''}');
      return KeepStep(
        thing,
        capability,
        value: k['value'],
        whileConditions: [
          for (final c in _maps(k['while'])) RuleCondition.fromJson(c),
        ],
        release: k['release'],
        hasRelease: k.containsKey('release'),
      );
    }
    return UnknownStep(json);
  }

  Json toJson();
}

/// `thing.key` split at its first dot.
(String, String) splitRef(String ref) {
  final dot = ref.indexOf('.');
  return dot < 0 ? (ref, '') : (ref.substring(0, dot), ref.substring(dot + 1));
}

class DoStep extends RuleStep {
  DoStep(this.thing, this.capability, {Json? params}) : params = params ?? {};

  String thing;
  String capability;
  Json params;

  @override
  Json toJson() => {
    'do': '$thing.$capability',
    if (params.isNotEmpty) 'params': params,
  };
}

class ToggleStep extends RuleStep {
  ToggleStep(this.thing, this.capability);

  String thing;
  String capability;

  @override
  Json toJson() => {'toggle': '$thing.$capability'};
}

class WaitStep extends RuleStep {
  WaitStep(this.ms);

  int ms;

  @override
  Json toJson() => {'wait': ms};
}

class WaitForStep extends RuleStep {
  WaitForStep(this.until, {this.timeoutMs = 60000, List<RuleStep>? onTimeout})
    : onTimeout = onTimeout ?? [];

  OnTrigger until;
  int timeoutMs;
  final List<RuleStep> onTimeout;

  @override
  Json toJson() => {
    'waitFor': {
      ...until.toJson(),
      'timeoutMs': timeoutMs,
      if (onTimeout.isNotEmpty)
        'onTimeout': [for (final s in onTimeout) s.toJson()],
    },
  };
}

class IfStep extends RuleStep {
  IfStep({
    List<RuleCondition>? conditions,
    List<RuleStep>? then,
    List<RuleStep>? otherwise,
  }) : conditions = conditions ?? [],
       then = then ?? [],
       otherwise = otherwise ?? [];

  final List<RuleCondition> conditions;
  final List<RuleStep> then;
  final List<RuleStep> otherwise;

  @override
  Json toJson() => {
    'if': [for (final c in conditions) c.toJson()],
    'then': [for (final s in then) s.toJson()],
    if (otherwise.isNotEmpty) 'else': [for (final s in otherwise) s.toJson()],
  };
}

class TogetherStep extends RuleStep {
  TogetherStep([List<List<RuleStep>>? branches])
    : branches = branches ?? [[], []];

  final List<List<RuleStep>> branches;

  @override
  Json toJson() => {
    'together': [
      for (final b in branches) [for (final s in b) s.toJson()],
    ],
  };
}

class SetStep extends RuleStep {
  SetStep(this.name, this.value);

  String name;
  Object? value;

  @override
  Json toJson() => {
    'set': {'var': name, 'value': value},
  };
}

class NotifyStep extends RuleStep {
  NotifyStep(this.title, {this.body, Json? extra}) : extra = extra ?? {};

  String title;
  String? body;

  /// Other announcement fields a rule carried, kept as they came.
  final Json extra;

  @override
  Json toJson() => {
    'notify': {...extra, 'title': title, 'body': ?body},
  };
}

class RunStep extends RuleStep {
  RunStep(this.automationId);

  String automationId;

  @override
  Json toJson() => {'run': automationId};
}

/// `{"keep": {"target": "thing.action", "value": v, "while": [Condition],
/// "release"?: v}}`: holds the target at [value] while every condition
/// holds, and sends [release] once they stop (the opposite of a boolean
/// [value] when it is left out). Keep steps go last in a rule's then.
class KeepStep extends RuleStep {
  KeepStep(
    this.thing,
    this.capability, {
    this.value = true,
    List<RuleCondition>? whileConditions,
    this.release,
    this.hasRelease = false,
  }) : whileConditions = whileConditions ?? [];

  String thing;
  String capability;
  Object? value;
  final List<RuleCondition> whileConditions;
  Object? release;
  bool hasRelease;

  @override
  Json toJson() => {
    'keep': {
      'target': '$thing.$capability',
      'value': value,
      'while': [for (final c in whileConditions) c.toJson()],
      if (hasRelease) 'release': release,
    },
  };
}

/// A step a newer engine wrote that this app cannot edit. It is kept as it
/// came, so saving the rule does not drop it.
class UnknownStep extends RuleStep {
  const UnknownStep(this.json);

  final Json json;

  @override
  Json toJson() => json;
}

/// A typed literal from a text field: true, false, null, a number, or else
/// the text itself.
Object? literalFromText(String text) {
  final t = text.trim();
  return switch (t) {
    'true' => true,
    'false' => false,
    'null' => null,
    _ => num.tryParse(t) ?? t,
  };
}

/// A duration in ms as the largest whole unit: `90 s`, `5 min`, `2 h`.
String durationText(int ms) {
  if (ms % 3600000 == 0 && ms >= 3600000) return '${ms ~/ 3600000} h';
  if (ms % 60000 == 0 && ms >= 60000) return '${ms ~/ 60000} min';
  if (ms % 1000 == 0) return '${ms ~/ 1000} s';
  return '$ms ms';
}
