import 'dart:convert';

/// What the shorthand `home:entered` resolves against.
class RuleContext {
  const RuleContext({this.places = const {}, this.person, this.personHome});

  /// Each place id, and each zone id a place answers to, to the place id.
  final Map<String, String> places;

  /// The household person, whose `home` follows [personHome].
  final String? person;

  /// The place id that counts as home for [person].
  final String? personHome;
}

/// A shorthand string that does not read as what its list holds.
class ShorthandException implements Exception {
  ShorthandException(this.message);

  final String message;

  @override
  String toString() => message;
}

final _thingKey = RegExp(r'^[a-z][a-z0-9_]*\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$');
final _hhmm = r'([01]\d|2[0-3]):[0-5]\d';
final _place = RegExp(r'^([a-z][a-z0-9_]*):(entered|left)$');
final _stateCompare = RegExp(
  r'^([a-z][a-z0-9_]*\.[A-Za-z0-9_.]+?)\s*(=|>|<)\s*(.+)$',
);
final _condition = RegExp(
  r'^(\$[A-Za-z_]\w*|%[A-Za-z_]\w*|[a-z][a-z0-9_]*\.[A-Za-z0-9_.]+?)\s*(==|!=|>=|<=|=|>|<)\s*(.*)$',
);
final _duration = RegExp(r'^(\d+)(ms|s|m|h)$');

/// A trigger written as one string: `manual`, `time:18:00`,
/// `time:07:00@mon,fri`, `every:30s`, `nfc:front_door`, `event:desk.button`,
/// `home:entered`, `jade.home`, `jade.home=true`, `room.temp>28`.
Map<String, Object?> expandTrigger(String text, RuleContext context) {
  final s = text.trim();
  if (s == 'manual') return {'manual': true};
  if (s.startsWith('time:')) {
    final m = RegExp('^($_hhmm)(@(.+))?\$').firstMatch(s.substring(5).trim());
    if (m == null) {
      throw ShorthandException('time is time:HH:MM or time:HH:MM@mon,fri');
    }
    return {
      'time': m.group(1),
      if (m.group(4) != null) 'days': _list(m.group(4)!),
    };
  }
  if (s.startsWith('every:')) {
    final ms = _milliseconds(s.substring(6), bareUnit: 's');
    if (ms % 1000 != 0 || ms == 0) {
      throw ShorthandException('every takes whole seconds, like every:30s');
    }
    return {'interval': ms ~/ 1000};
  }
  if (s.startsWith('nfc:')) {
    final tag = s.substring(4).trim();
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(tag)) {
      throw ShorthandException('nfc takes a tag id, like nfc:front_door');
    }
    return {'on': '$tag.scanned', 'event': true};
  }
  if (s.startsWith('event:')) {
    final ref = s.substring(6).trim();
    if (!_thingKey.hasMatch(ref)) {
      throw ShorthandException(
        'event takes thing.event, like event:desk.button',
      );
    }
    return {'on': ref, 'event': true};
  }
  final place = _place.firstMatch(s);
  if (place != null) {
    final id = context.places[place.group(1)];
    if (id == null) throw ShorthandException('no place ${place.group(1)}');
    final entered = place.group(2) == 'entered';
    final on = context.person != null && context.personHome == id
        ? '${context.person}.home'
        : '$id.inside';
    return {
      'on': on,
      'change': {'to': entered},
    };
  }
  final compare = _stateCompare.firstMatch(s);
  if (compare != null) {
    final value = _value(compare.group(3)!);
    return switch (compare.group(2)) {
      '=' => {
        'on': compare.group(1),
        'change': {'to': value},
      },
      final op when value is num => {
        'on': compare.group(1),
        'crosses': {op == '>' ? 'above' : 'below': value},
      },
      final op => throw ShorthandException(
        '${compare.group(1)}$op needs a number to cross',
      ),
    };
  }
  if (_thingKey.hasMatch(s)) return {'on': s, 'change': <String, Object?>{}};
  throw ShorthandException(
    'is not a trigger: use thing.key, thing.key=value, thing.key>number, '
    'nfc:tag, place:entered, time:HH:MM, every:30s or manual',
  );
}

/// A condition written as one string: `jade.home`, `room.temp>=20`,
/// `$Mode=away`, `time:18:00-23:00`, `days:mon,fri`, `not:jade.home`.
Map<String, Object?> expandCondition(String text) {
  final s = text.trim();
  if (s.startsWith('not:')) return {'not': expandCondition(s.substring(4))};
  if (s.startsWith('time:')) {
    final m = RegExp('^($_hhmm)-($_hhmm)\$').firstMatch(s.substring(5).trim());
    if (m == null) {
      throw ShorthandException('a time window is time:HH:MM-HH:MM');
    }
    return {
      'between': [m.group(1), m.group(3)],
    };
  }
  if (s.startsWith('days:')) return {'days': _list(s.substring(5))};
  if (_thingKey.hasMatch(s)) return {'state': s, 'op': '==', 'value': true};
  final m = _condition.firstMatch(s);
  if (m == null || m.group(3)!.isEmpty) {
    throw ShorthandException(
      'is not a condition: use thing.key, thing.key=value, \$Var=value, '
      'thing.key>number, time:HH:MM-HH:MM, days:mon,fri or not:...',
    );
  }
  final left = m.group(1)!;
  return {
    left.startsWith(r'$') || left.startsWith('%') ? 'var' : 'state': left,
    'op': m.group(2) == '=' ? '==' : m.group(2),
    'value': _value(m.group(3)!),
  };
}

/// A step written as one string: `lamp.power=true`, `tv.home`,
/// `toggle:lamp.power`, `wait:2s`, `notify:Door open`, `set:$Mode=away`,
/// `run:evening`.
Map<String, Object?> expandStep(String text) {
  final s = text.trim();
  if (s.startsWith('toggle:')) return {'toggle': s.substring(7).trim()};
  if (s.startsWith('wait:')) {
    return {'wait': _milliseconds(s.substring(5))};
  }
  if (s.startsWith('notify:')) {
    final message = _unquote(s.substring(7));
    if (message.isEmpty) throw ShorthandException('notify needs the text');
    return {
      'notify': {'title': message},
    };
  }
  if (s.startsWith('set:')) {
    final eq = s.indexOf('=');
    if (eq < 0) throw ShorthandException(r'set is set:$Name=value');
    return {
      'set': {
        'var': s.substring(4, eq).trim(),
        'value': _value(s.substring(eq + 1)),
      },
    };
  }
  if (s.startsWith('run:')) return {'run': s.substring(4).trim()};
  final eq = s.indexOf('=');
  if (eq > 0) {
    final value = _value(s.substring(eq + 1));
    return {
      'do': s.substring(0, eq).trim(),
      'params': value is Map ? value : {'value': value},
    };
  }
  if (_thingKey.hasMatch(s)) return {'do': s};
  throw ShorthandException(
    'is not a step: use thing.action, thing.action=value, toggle:thing.action, '
    'wait:2s, notify:text, set:\$Name=value or run:automation',
  );
}

int _milliseconds(String text, {String? bareUnit}) {
  final t = text.trim();
  final m = _duration.firstMatch(
    bareUnit != null && RegExp(r'^\d+$').hasMatch(t) ? '$t$bareUnit' : t,
  );
  if (m == null) {
    throw ShorthandException('$t is not a duration: use 500ms, 2s, 5m or 1h');
  }
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)) {
    'ms' => n,
    's' => n * 1000,
    'm' => n * 60000,
    _ => n * 3600000,
  };
}

List<String> _list(String text) => [
  for (final d in text.split(','))
    if (d.trim().isNotEmpty) d.trim(),
];

/// JSON when [text] is JSON (`true`, `80`, `{"app": "x"}`), else the text.
Object? _value(String text) {
  final t = text.trim();
  try {
    return jsonDecode(t);
  } on FormatException {
    return _unquote(t);
  }
}

String _unquote(String text) {
  final t = text.trim();
  return t.length >= 2 &&
          ((t.startsWith('"') && t.endsWith('"')) ||
              (t.startsWith("'") && t.endsWith("'")))
      ? t.substring(1, t.length - 1)
      : t;
}
