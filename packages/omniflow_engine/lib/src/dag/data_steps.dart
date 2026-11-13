import 'dart:convert';

import 'expression.dart';

/// The value at [path] inside [value] (`state.on`, `items[0].name`), and
/// whether it is there. A JSON text is read as the JSON it holds.
(bool, Object?) valueAt(Object? value, String? path) {
  var current = _decoded(value);
  if (path == null || path.isEmpty) return (true, current);
  for (final part in _segments(path)) {
    current = _decoded(current);
    if (part is int) {
      if (current is! List || part >= current.length) return (false, null);
      current = current[part];
    } else {
      if (current is! Map || !current.containsKey(part)) return (false, null);
      current = current[part];
    }
  }
  return (true, current);
}

Object? _decoded(Object? value) {
  if (value is! String) return value;
  final t = value.trimLeft();
  if (!t.startsWith('{') && !t.startsWith('[')) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return value;
  }
}

final _segment = RegExp(r'([^.\[\]]+)|\[(\d+)\]');

List<Object> _segments(String path) => [
  for (final m in _segment.allMatches(path))
    if (m.group(2) != null) int.parse(m.group(2)!) else m.group(1)!,
];

/// [text] changed by [op]: `upper`, `lower`, `trim` or `none`.
String applyTextOp(String text, Object? op) => switch (op) {
  'upper' => text.toUpperCase(),
  'lower' => text.toLowerCase(),
  'trim' => text.trim(),
  _ => text,
};

/// Why [expr] cannot be worked out, or null when it can, with every
/// `{{...}}` taken as 1. A division by zero is a run-time matter.
String? expressionProblem(String expr) {
  final probe = expr.replaceAll(RegExp(r'\{\{[^{}]*\}\}'), '1');
  try {
    evaluateExpression(probe, (_) => 1);
    return null;
  } on ExpressionException catch (e) {
    if (e.message == 'division by zero') return null;
    return 'cannot be worked out: ${e.message}';
  }
}

/// [at] written in [format]: `yyyy` `yy` `MMMM` `MMM` `MM` `M` `dd` `d`
/// `EEEE` `EEE` `HH` `H` `hh` `h` `mm` `ss` `a`; other letters stay as
/// they are, and text in single quotes is kept.
String formatDate(DateTime at, String format) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  const days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  final hour12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final tokens = <String, String Function()>{
    'yyyy': () => at.year.toString().padLeft(4, '0'),
    'yy': () => two(at.year % 100),
    'MMMM': () => months[at.month - 1],
    'MMM': () => months[at.month - 1].substring(0, 3),
    'MM': () => two(at.month),
    'M': () => '${at.month}',
    'dd': () => two(at.day),
    'd': () => '${at.day}',
    'EEEE': () => days[at.weekday - 1],
    'EEE': () => days[at.weekday - 1].substring(0, 3),
    'HH': () => two(at.hour),
    'H': () => '${at.hour}',
    'hh': () => two(hour12),
    'h': () => '$hour12',
    'mm': () => two(at.minute),
    'ss': () => two(at.second),
    'a': () => at.hour < 12 ? 'AM' : 'PM',
  };
  final out = StringBuffer();
  var i = 0;
  outer:
  while (i < format.length) {
    if (format[i] == "'") {
      final end = format.indexOf("'", i + 1);
      out.write(format.substring(i + 1, end < 0 ? format.length : end));
      i = end < 0 ? format.length : end + 1;
      continue;
    }
    for (final t in tokens.entries) {
      if (format.startsWith(t.key, i)) {
        out.write(t.value());
        i += t.key.length;
        continue outer;
      }
    }
    out.write(format[i]);
    i++;
  }
  return out.toString();
}
