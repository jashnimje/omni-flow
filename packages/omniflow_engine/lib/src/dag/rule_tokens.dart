import '../manifest/validation.dart';
import 'rule_shorthand.dart';
import 'rules.dart';

/// Why a path cannot be read in a rule, for `rule.tokens`.
class RuleTokenPathException implements Exception {
  RuleTokenPathException(this.message);

  final String message;
}

/// The payload keys of the events whose shape is known, with their words.
const _eventPayloads = <String, List<(String, String)>>{
  'notification': [
    ('package', 'app'),
    ('label', 'app name'),
    ('title', 'title'),
    ('text', 'text'),
  ],
  'app_opened': [('package', 'app'), ('label', 'app name')],
  'app_closed': [('package', 'app'), ('label', 'app name')],
  'bluetooth_connected': [('name', 'name'), ('address', 'address')],
  'bluetooth_disconnected': [('name', 'name'), ('address', 'address')],
  'scanned': [('uid', 'tag UID'), ('source', 'reader'), ('at', 'time')],
};

/// Every value a step at [path] (`then[2]`, `then[0].then[1]`) can use,
/// from the triggers and every step before it, in order. [rule] may be
/// unsaved and unfinished: it is normalized when it can be, and read as
/// written when not. [thingName] gives a thing's name for the labels.
List<Map<String, Object?>> ruleTokens(
  Object? rule,
  String path, {
  RuleContext context = const RuleContext(),
  String Function(String thing)? thingName,
}) {
  final spec = _readable(rule, context);
  final words = _Words(thingName ?? (t) => t.replaceAll('_', ' '));
  final out = _Tokens();
  final when = spec['when'];
  if (when is List) {
    for (var i = 0; i < when.length; i++) {
      final t = _asTrigger(when[i], context);
      if (t != null) words.trigger(t, 'when[$i]', out);
    }
  }
  final parts = [
    for (final m in RegExp(r'([A-Za-z]+)|\[(\d+)\]').allMatches(path))
      m.group(1) ?? int.parse(m.group(2)!),
  ];
  if (parts.length < 2 || parts.first != 'then' || parts[1] is! int) {
    throw RuleTokenPathException(
      'The path must name a step, like then[2] or then[0].then[1]',
    );
  }
  Object? list = spec['then'];
  var at = 'then';
  var i = 1;
  while (true) {
    final index = parts[i] as int;
    final steps = list is List ? list : const [];
    final last = i == parts.length - 1;
    if (index > steps.length || (!last && index == steps.length)) {
      throw RuleTokenPathException('$path is not a step of this rule');
    }
    for (var k = 0; k < index; k++) {
      words.stepDeep(_asStep(steps[k]), '$at[$k]', out);
    }
    if (last) break;
    final step = _asStep(steps[index]) ?? const {};
    final here = '$at[$index]';
    final next = parts[i + 1];
    if (next is! String) throw RuleTokenPathException('$path is not a step');
    switch (next) {
      case 'then' || 'else' when step['if'] != null:
        list = step[next];
        at = '$here.$next';
        i += 2;
      case 'try':
        list = step['try'];
        at = '$here.try';
        i += 2;
      case 'otherwise':
        final tried = step['try'] is List ? step['try'] as List : const [];
        for (var k = 0; k < tried.length; k++) {
          words.stepDeep(_asStep(tried[k]), '$here.try[$k]', out);
        }
        out.add('{{msg.error}}', 'What went wrong', '$here.try', 'text');
        list = step['otherwise'];
        at = '$here.otherwise';
        i += 2;
      case 'together':
        final groups = step['together'] is List
            ? step['together'] as List
            : const [];
        final g = i + 2 < parts.length ? parts[i + 2] : null;
        if (g is! int || g >= groups.length) {
          throw RuleTokenPathException('$path is not a step of this rule');
        }
        list = groups[g];
        at = '$here.together[$g]';
        i += 3;
      case 'repeat' || 'forEach' || 'waitFor':
        final inner = step[next] is Map ? step[next] as Map : const {};
        final key = next == 'waitFor' ? 'onTimeout' : 'do';
        if (i + 2 >= parts.length || parts[i + 2] != key) {
          throw RuleTokenPathException('$path is not a step of this rule');
        }
        if (next == 'repeat') {
          out.add('{{msg.iteration}}', 'Repeat · pass', here, 'number');
        } else if (next == 'forEach') {
          final as = '${inner['as'] ?? '%item'}';
          final room =
              inner['in'] is String &&
              (inner['in'] as String).startsWith('room:');
          out.add(
            '{{$as}}',
            room ? 'Each device' : 'Each item',
            here,
            room ? 'text' : 'any',
          );
          out.add('{{msg.index}}', 'Each item · number', here, 'number');
        }
        list = inner[key];
        at = '$here.$next.$key';
        i += 3;
      default:
        throw RuleTokenPathException('$path is not a step of this rule');
    }
    if (i >= parts.length || parts[i] is! int) {
      throw RuleTokenPathException('$path is not a step of this rule');
    }
  }
  return out.list;
}

/// [rule] normalized, or as written when it does not normalize yet.
Map<String, Object?> _readable(Object? rule, RuleContext context) {
  if (rule is! Map) {
    throw RuleTokenPathException('The rule must be an object');
  }
  try {
    return normalizeRule({
      'name': 'tokens',
      ...Map<String, Object?>.from(rule),
    }, context: context);
  } on ValidationException {
    return Map<String, Object?>.from(rule);
  }
}

Map<String, Object?>? _asTrigger(Object? t, RuleContext context) {
  if (t is Map) return Map<String, Object?>.from(t);
  if (t is String) {
    try {
      return expandTrigger(t, context);
    } on ShorthandException {
      return null;
    }
  }
  return null;
}

Map<String, Object?>? _asStep(Object? s) {
  if (s is Map) return Map<String, Object?>.from(s);
  if (s is String) {
    try {
      return expandStep(s);
    } on ShorthandException {
      return null;
    }
  }
  return null;
}

class _Tokens {
  final _byToken = <String, Map<String, Object?>>{};

  /// Adds a token, moving an earlier one with the same text to here: the
  /// later step's value is the one a later step reads.
  void add(String token, String label, String from, String kind) {
    _byToken.remove(token);
    _byToken[token] = {
      'token': token,
      'label': label,
      'from': from,
      'kind': kind,
    };
  }

  List<Map<String, Object?>> get list => _byToken.values.toList();
}

class _Words {
  _Words(this.name);

  final String Function(String thing) name;

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  void trigger(Map<String, Object?> t, String from, _Tokens out) {
    final on = t['on'];
    if (on is String && on.contains('.')) {
      final thing = name(on.substring(0, on.indexOf('.')));
      final key = on.substring(on.indexOf('.') + 1);
      if (t['event'] == true) {
        out.add('{{msg.device}}', 'Device', from, 'text');
        final known = _eventPayloads[key];
        if (known == null) {
          out.add(
            '{{msg.payload}}',
            '${_cap(thing)} · event details',
            from,
            'object',
          );
        } else {
          for (final (k, words) in known) {
            out.add(
              '{{msg.payload.$k}}',
              '${_cap(key.replaceAll('_', ' '))} · $words',
              from,
              'text',
            );
          }
        }
      } else {
        final change = t['change'];
        final kind = t['crosses'] is Map
            ? 'number'
            : change is Map && change['to'] is bool
            ? 'bool'
            : 'any';
        out.add('{{msg.value}}', '${_cap(thing)} · new value', from, kind);
        out.add(
          '{{msg.previous}}',
          '${_cap(thing)} · value before',
          from,
          kind,
        );
        out.add('{{msg.device}}', 'Device', from, 'text');
      }
    } else if (t['manual'] == true) {
      out.add('{{msg.shared.text}}', 'Shared text', from, 'text');
      out.add('{{msg.shared.url}}', 'Shared link', from, 'text');
    }
    out.add('{{msg.at}}', 'Time it started', from, 'text');
  }

  /// The values [step] and the steps inside it make.
  void stepDeep(Map<String, Object?>? step, String from, _Tokens out) {
    if (step == null) return;
    this.step(step, from, out);
    void inner(Object? list, String at) {
      if (list is! List) return;
      for (var k = 0; k < list.length; k++) {
        stepDeep(_asStep(list[k]), '$at[$k]', out);
      }
    }

    for (final key in ['then', 'else', 'try', 'otherwise']) {
      if (key == 'then' && step['if'] == null) continue;
      inner(step[key], '$from.$key');
    }
    if (step['together'] case final List groups) {
      for (var g = 0; g < groups.length; g++) {
        inner(groups[g], '$from.together[$g]');
      }
    }
    for (final key in ['repeat', 'forEach']) {
      if (step[key] case final Map m) inner(m['do'], '$from.$key.do');
    }
    if (step['waitFor'] case final Map w) {
      inner(w['onTimeout'], '$from.waitFor.onTimeout');
    }
  }

  void step(Map<String, Object?> s, String from, _Tokens out) {
    String variable(Object? inner, String fallback) {
      final as = inner is Map ? inner['as'] : null;
      return as is String && as.startsWith('%') ? as : fallback;
    }

    String label(String base, String used, String fallback) =>
        used == fallback ? base : '$base ($used)';

    if (s['do'] is String) {
      final ref = s['do'] as String;
      final v = variable(s, '%state');
      final thing = ref.contains('.')
          ? ref.substring(0, ref.indexOf('.'))
          : ref;
      final who = thing.startsWith('{{') ? 'the device' : name(thing);
      out.add(
        '{{$v}}',
        label('${_cap(who)} · new state', v, '%state'),
        from,
        'object',
      );
      return;
    }
    if (s['http'] is Map) {
      final v = variable(s['http'], '%reply');
      final base = label('Web reply', v, '%reply');
      out.add('{{$v}}', base, from, 'object');
      out.add('{{$v.status}}', '$base · status', from, 'number');
      out.add('{{$v.body}}', '$base · body', from, 'any');
      return;
    }
    if (s['waitFor'] is Map) {
      out.add('{{msg.event}}', 'What it waited for', from, 'object');
      return;
    }
    if (s['set'] is Map) {
      final name = (s['set'] as Map)['var'];
      if (name is String && name.length > 1) {
        out.add('{{$name}}', 'Variable ${name.substring(1)}', from, 'any');
      }
      return;
    }
    for (final (key, fallback, base, kind) in const [
      ('ask', '%answer', 'Answer', 'text'),
      ('get', '%value', 'Value', 'any'),
      ('text', '%text', 'Text', 'text'),
      ('math', '%result', 'Result', 'number'),
      ('date', '%date', 'Date', 'text'),
    ]) {
      if (s[key] is! Map) continue;
      final v = variable(s[key], fallback);
      out.add('{{$v}}', label(base, v, fallback), from, kind);
      return;
    }
  }
}
