import 'canonical.dart';

/// What a condition rule can look at while a run is in progress.
class EvalContext {
  const EvalContext({
    required this.now,
    this.globals = const {},
    this.flowVars = const {},
    this.msg = const {},
    this.deviceStates = const {},
    this.people,
  });

  /// The person things, for a `people` rule. Null reads every state that
  /// looks like a person's (`home` true or false, and a `place`).
  final Set<String>? people;

  /// Whether any person is home.
  bool get anyoneHome => peopleHome(deviceStates, people).isNotEmpty;

  /// Local wall-clock time.
  final DateTime now;
  final Map<String, Object?> globals;
  final Map<String, Object?> flowVars;
  final Map<String, Object?> msg;
  final Map<String, Map<String, Object?>> deviceStates;

  /// `$Name` reads a global, `%name` a run variable, and `msg.key` the
  /// message that reached the condition (`msg.value`, `msg.previous`).
  Object? variable(String name) => name.startsWith(r'$')
      ? globals[name.substring(1)]
      : name.startsWith('%')
      ? flowVars[name.substring(1)]
      : name.startsWith('msg.')
      ? _path(msg, name.substring(4))
      : null;

  /// One side of a `compare`: `{literal}`, `{state: "thing.key"}` (the
  /// thing's current state), `{msg: "key"}` (the message, dotted paths
  /// allowed) or `{var: "$Name" | "%name"}`.
  Object? value(Object? side) {
    if (side is! Map || side.length != 1) return null;
    final ref = side.values.single;
    switch (side.keys.single) {
      case 'literal':
        return ref;
      case 'msg':
        return ref is String ? _path(msg, ref) : null;
      case 'var':
        return ref is String ? variable(ref) : null;
      case 'state':
        if (ref is! String) return null;
        final dot = ref.indexOf('.');
        if (dot < 1) return null;
        return deviceStates[ref.substring(0, dot)]?[ref.substring(dot + 1)];
    }
    return null;
  }

  static Object? _path(Map<String, Object?> from, String path) {
    Object? at = from;
    for (final part in path.split('.')) {
      if (at is! Map) return null;
      at = at[part];
    }
    return at;
  }
}

/// Evaluates one condition rule (the shapes `checkRule` accepts).
bool evaluateRule(Map<String, Object?> rule, EvalContext ctx) {
  switch (rule['type']) {
    case 'all_of':
      return _rules(rule).every((r) => evaluateRule(r, ctx));
    case 'any_of':
      return _rules(rule).any((r) => evaluateRule(r, ctx));
    case 'xor':
      return _rules(rule).where((r) => evaluateRule(r, ctx)).length == 1;
    case 'not':
      return !evaluateRule(Map<String, Object?>.from(rule['rule'] as Map), ctx);
    case 'time_window':
      return inTimeWindow(
        ctx.now,
        rule['start'] as String,
        rule['end'] as String,
      );
    case 'days':
      return (rule['days'] as List).contains(_weekdays[ctx.now.weekday - 1]);
    case 'compare':
      return compareValues(
        ctx.value(rule['left']),
        rule['op'] as String,
        ctx.value(rule['right']),
      );
    case 'people':
      return switch (rule['is']) {
        'anyone_home' => ctx.anyoneHome,
        'all_away' => !ctx.anyoneHome,
        _ => throw ArgumentError('unknown people rule ${rule['is']}'),
      };
  }
  throw ArgumentError('unknown rule type ${rule['type']}');
}

/// The people [states] say are home: of [people] when given, else of every
/// state shaped like a person's.
Set<String> peopleHome(
  Map<String, Map<String, Object?>> states,
  Set<String>? people,
) => {
  for (final e in states.entries)
    if ((people?.contains(e.key) ??
            (e.value['home'] is bool && e.value.containsKey('place'))) &&
        e.value['home'] == true)
      e.key,
};

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// `==` and `!=` take any values, numbers by value and lists and objects by
/// content. The ordering operators hold only between two numbers, so a
/// missing value never passes a threshold.
bool compareValues(Object? left, String op, Object? right) => switch (op) {
  '==' => valuesEqual(left, right),
  '!=' => !valuesEqual(left, right),
  _ when left is! num || right is! num => false,
  '<' => left < right,
  '<=' => left <= right,
  '>' => left > right,
  '>=' => left >= right,
  _ => false,
};

Iterable<Map<String, Object?>> _rules(Map<String, Object?> rule) =>
    (rule['rules'] as List).map((r) => Map<String, Object?>.from(r as Map));

/// Numbers by value (80 equals 80.0), lists and objects by content.
bool valuesEqual(Object? a, Object? b) => (a is List || a is Map)
    ? (b is List || b is Map) && canonicalJson(a) == canonicalJson(b)
    : a == b;

/// True when [now] is inside `start..end`, both `HH:MM`. A window whose end
/// is earlier than its start crosses midnight, so 18:00 to 05:00 includes
/// 23:00 and 02:00. The start minute is inside, the end minute is not. Equal
/// start and end mean the whole day.
bool inTimeWindow(DateTime now, String start, String end) {
  final s = _minutes(start);
  final e = _minutes(end);
  final m = now.hour * 60 + now.minute;
  if (s == e) return true;
  return s < e ? (m >= s && m < e) : (m >= s || m < e);
}

int _minutes(String hhmm) {
  final parts = hhmm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}
