import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';

/// Starting points for a rule. Each spec is a rule with placeholders,
/// `"<key>"`, that the app (or [fillTemplate]) replaces with the user's
/// picks. A placeholder that is a whole string takes the value with its
/// type, and a step naming a list placeholder becomes one step per item.
///
/// Placeholder kinds: `person` (a person id), `tag` (a tag id), `sensor`
/// (`thing.key` of a reading), `toggle` (`thing.action` of an on/off
/// capability), `toggles` (a list of those), `time` (`HH:MM`) and
/// `duration` (milliseconds).
class RuleTemplate {
  const RuleTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.placeholders,
    required this.spec,
  });

  final String id;
  final String name;
  final String description;
  final List<TemplatePlaceholder> placeholders;
  final Map<String, Object?> spec;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'placeholders': [for (final p in placeholders) p.toJson()],
    'spec': spec,
  };
}

class TemplatePlaceholder {
  const TemplatePlaceholder(this.key, this.label, this.kind, {this.fallback});

  final String key;
  final String label;
  final String kind;

  /// The value used when none is given.
  final Object? fallback;

  bool get isList => kind == 'toggles';

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'kind': kind,
    'default': ?fallback,
  };
}

const _person = TemplatePlaceholder('person', 'Who', 'person');

const ruleTemplates = <RuleTemplate>[
  RuleTemplate(
    id: 'arrive_home',
    name: 'Arrive home',
    description: 'When you get home, turn things on.',
    placeholders: [
      _person,
      TemplatePlaceholder('things', 'Turn on', 'toggles'),
    ],
    spec: {
      'name': 'Arrive home',
      'when': [
        {
          'on': '<person>.home',
          'change': {'to': true},
        },
      ],
      'then': [
        {
          'do': '<things>',
          'params': {'value': true},
        },
      ],
    },
  ),
  RuleTemplate(
    id: 'leave_home_all_off',
    name: 'Leave home, all off',
    description: 'When you leave, turn everything you pick off.',
    placeholders: [
      _person,
      TemplatePlaceholder('things', 'Turn off', 'toggles'),
    ],
    spec: {
      'name': 'Leave home, all off',
      'when': [
        {
          'on': '<person>.home',
          'change': {'to': false},
        },
      ],
      'then': [
        {
          'do': '<things>',
          'params': {'value': false},
        },
      ],
    },
  ),
  RuleTemplate(
    id: 'motion_light',
    name: 'Motion light',
    description:
        'When motion is seen, turn a light on, and off again after a while. '
        'New motion starts the wait again.',
    placeholders: [
      TemplatePlaceholder('motion', 'Motion sensor', 'sensor'),
      TemplatePlaceholder('light', 'Light', 'toggle'),
      TemplatePlaceholder('delay', 'Off after', 'duration', fallback: 120000),
    ],
    spec: {
      'name': 'Motion light',
      'when': [
        {
          'on': '<motion>',
          'change': {'to': true},
        },
      ],
      'then': [
        {
          'do': '<light>',
          'params': {'value': true},
        },
        {'wait': '<delay>'},
        {
          'do': '<light>',
          'params': {'value': false},
        },
      ],
      'mode': 'restart',
    },
  ),
  RuleTemplate(
    id: 'tag_toggle',
    name: 'Tag toggle',
    description: 'Scan an NFC tag to switch something on or off.',
    placeholders: [
      TemplatePlaceholder('tag', 'Tag', 'tag'),
      TemplatePlaceholder('target', 'Switch', 'toggle'),
    ],
    spec: {
      'name': 'Tag toggle',
      'when': [
        {'on': '<tag>.scanned', 'event': true},
      ],
      'then': [
        {'toggle': '<target>'},
      ],
    },
  ),
  RuleTemplate(
    id: 'bedtime',
    name: 'Bedtime',
    description: 'At bedtime, turn things off and say good night.',
    placeholders: [
      TemplatePlaceholder('time', 'At', 'time', fallback: '23:00'),
      TemplatePlaceholder('things', 'Turn off', 'toggles'),
    ],
    spec: {
      'name': 'Bedtime',
      'when': [
        {'time': '<time>'},
      ],
      'then': [
        {
          'do': '<things>',
          'params': {'value': false},
        },
        {
          'notify': {'title': 'Good night'},
        },
      ],
    },
  ),
];

class TemplateFillException implements Exception {
  TemplateFillException(this.message);

  final String message;
}

final _placeholder = RegExp(r'<([a-z][a-z0-9_]*)>');

/// The actions that turn a thing on and off when it has no on/off switch,
/// such as a TV's wake and sleep.
typedef PowerActions = ({String on, String off});

/// [template]'s spec with [values] in place of its placeholders.
///
/// [powerActionsOf] names, for a `thing.action` picked as a switch, the
/// actions that turn that thing on and off instead. A step that sets such a
/// target to true or false becomes a plain step on its on or off action.
Map<String, Object?> fillTemplate(
  RuleTemplate template,
  Map<String, Object?> values, {
  PowerActions? Function(String target)? powerActionsOf,
}) {
  final filled = <String, Object?>{};
  for (final p in template.placeholders) {
    final value = values[p.key] ?? p.fallback;
    if (value == null) throw TemplateFillException('needs ${p.key}');
    if (p.isList && (value is! List || value.isEmpty)) {
      throw TemplateFillException('${p.key} must be a list of one or more');
    }
    filled[p.key] = value;
  }
  for (final key in values.keys) {
    if (!filled.containsKey(key)) {
      throw TemplateFillException('${template.id} has no placeholder $key');
    }
  }

  Object? fill(Object? v) => switch (v) {
    String s => _fillString(s, filled),
    Map m => {for (final e in m.entries) '${e.key}': fill(e.value)},
    List l => [
      for (final item in l)
        if (_listKeyIn(item, template.placeholders) case final key?)
          for (final each in filled[key] as List)
            fill(_replaceWhole(item, '<$key>', each))
        else
          fill(item),
    ],
    _ => v,
  };

  Object? power(Object? v) => switch (v) {
    Map m
        when m['do'] is String &&
            m['params'] is Map &&
            (m['params'] as Map)['value'] is bool =>
      switch (powerActionsOf?.call(m['do'] as String)) {
        final actions? => {
          for (final e in m.entries)
            if (e.key != 'params') '${e.key}': e.value,
          'do': _onThing(
            m['do'] as String,
            (m['params'] as Map)['value'] == true ? actions.on : actions.off,
          ),
        },
        null => {for (final e in m.entries) '${e.key}': power(e.value)},
      },
    Map m => {for (final e in m.entries) '${e.key}': power(e.value)},
    List l => [for (final item in l) power(item)],
    _ => v,
  };

  return Map<String, Object?>.from(power(fill(template.spec)) as Map);
}

/// The wake and sleep actions of [manifest], when its capability [id] is
/// one of them or its `power` action: what turns a TV on and off.
PowerActions? powerActionsOf(DriverManifest? manifest, String id) {
  bool isAction(String name) =>
      manifest?.capability(name)?.type == CapabilityType.action;
  if (!const {'power', 'wake', 'sleep'}.contains(id) ||
      !isAction(id) ||
      !isAction('wake') ||
      !isAction('sleep')) {
    return null;
  }
  return (on: 'wake', off: 'sleep');
}

String _onThing(String target, String action) =>
    '${target.substring(0, target.lastIndexOf('.'))}.$action';

Object? _fillString(String s, Map<String, Object?> values) {
  final whole = _placeholder.matchAsPrefix(s);
  if (whole != null && whole.end == s.length) return values[whole.group(1)];
  return s.replaceAllMapped(
    _placeholder,
    (m) => '${values[m.group(1)] ?? m.group(0)}',
  );
}

/// The list placeholder a step names as a whole value, if any.
String? _listKeyIn(Object? item, List<TemplatePlaceholder> placeholders) {
  if (item is! Map) return null;
  for (final p in placeholders) {
    if (p.isList && item.values.contains('<${p.key}>')) return p.key;
  }
  return null;
}

Object? _replaceWhole(Object? item, String token, Object? value) => item is Map
    ? {for (final e in item.entries) e.key: e.value == token ? value : e.value}
    : item;
