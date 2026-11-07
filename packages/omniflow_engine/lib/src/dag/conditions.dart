/// What a condition rule can look at while a run is in progress.
class EvalContext {
  const EvalContext({
    required this.now,
    this.globals = const {},
    this.flowVars = const {},
    this.msg = const {},
    this.deviceStates = const {},
  });

  /// Local wall-clock time.
  final DateTime now;
  final Map<String, Object?> globals;
  final Map<String, Object?> flowVars;
  final Map<String, Object?> msg;
  final Map<String, Map<String, Object?>> deviceStates;

  /// `$Name` reads a global, `%name` a run variable.
  Object? variable(String name) => name.startsWith(r'$')
      ? globals[name.substring(1)]
      : name.startsWith('%')
      ? flowVars[name.substring(1)]
      : null;
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
    case 'var_equals':
      return _equal(ctx.variable(rule['name'] as String), rule['value']);
    case 'var_compare':
      final left = ctx.variable(rule['name'] as String);
      final right = rule['value'];
      if (left is! num || right is! num) return false;
      return switch (rule['op']) {
        '<' => left < right,
        '<=' => left <= right,
        '>' => left > right,
        '>=' => left >= right,
        '==' => left == right,
        '!=' => left != right,
        _ => false,
      };
    case 'device_state_is':
      final state = ctx.deviceStates[rule['deviceId']];
      return state != null && _equal(state[rule['key']], rule['value']);
  }
  throw ArgumentError('unknown rule type ${rule['type']}');
}

Iterable<Map<String, Object?>> _rules(Map<String, Object?> rule) =>
    (rule['rules'] as List).map((r) => Map<String, Object?>.from(r as Map));

/// Numbers compare by value (80 equals 80.0), everything else with ==.
bool _equal(Object? a, Object? b) => (a is num && b is num) ? a == b : a == b;

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
