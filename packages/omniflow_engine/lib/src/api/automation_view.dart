import '../dag/node_types.dart';
import '../dag/rules.dart' show daysSuffix, daysWords, sunTriggerLabel;
import 'clock_words.dart';
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';
import '../devices/device_service.dart' show stateKeyOf;
import '../devices/wiz_pilot.dart' show isWizSceneCapability;
import '../devices/wiz_scenes.dart';
import 'house_things.dart';
import 'phone_words.dart';
import 'rules_core_words.dart';

/// One piece of an automation's sentence: `when`, `if` and `then` are the
/// coloured chips, `text` the words between them.
Map<String, Object?> _chip(String kind, String text) => {
  'kind': kind,
  'text': text,
};

/// What an automation reads in plain words needs: each thing's name and
/// driver, the household person (who reads as "I"), and the automation
/// names a run step names.
class SentenceContext {
  const SentenceContext({
    this.names = const {},
    this.drivers = const {},
    this.person,
    this.automations = const {},
    this.hour12 = false,
  });

  final Map<String, String> names;
  final Map<String, DriverManifest> drivers;
  final String? person;
  final Map<String, String> automations;

  /// Whether times read on a 12-hour clock ("7:30 PM") or 24 hours.
  final bool hour12;

  /// [hhmm] as the person reads the time.
  String clock(Object? hhmm) => clockWords(hhmm, hour12: hour12);

  String name(String thing) => thing.startsWith('{{')
      ? 'each device'
      : names[thing] ?? thing.replaceAll('_', ' ');

  /// `Jade ` for a step sent `to` a person, else nothing.
  String _toWhom(Map<Object?, Object?> step) =>
      step['to'] is String ? '${name(step['to'] as String)} ' : '';

  CapabilitySpec? _capability(String thing, String key) {
    final manifest = drivers[thing];
    if (manifest == null) return null;
    return manifest.capability(key) ??
        manifest.capabilities
            .where((c) => stateKeyOf(c.stateJsonPath) == key)
            .firstOrNull;
  }

  /// The words for one key of a thing: its capability label, or the key.
  /// A label listing the values a sensor reports ("Power (on, asleep or
  /// off)") drops the list: the value says which.
  String _key(String thing, String key) {
    final capability = _capability(thing, key);
    if (capability == null) return key.replaceAll('_', ' ').toLowerCase();
    final label = capability.values.isEmpty
        ? capability.label
        : capability.label.replaceAll(RegExp(r'\s*\([^)]*\)'), '');
    return label.toLowerCase();
  }

  /// Whether [key] of [thing] is a power reading with a fixed set of values
  /// (a TV's on, asleep or off), which reads as the thing itself: "Living
  /// room TV is asleep".
  bool _isPowerChoice(String thing, String key) =>
      drivers[thing]?.capabilities.any(
        (c) =>
            c.values.isNotEmpty &&
            (c.id == key || stateKeyOf(c.stateJsonPath) == key) &&
            c.label
                    .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
                    .trim()
                    .toLowerCase() ==
                'power',
      ) ??
      false;

  /// Whether [key] of [thing] is its one on/off: a toggle that is the
  /// thing's only toggle, so "Desk lamp is on" says enough.
  bool isOnOff(String thing, String key) {
    final toggles =
        drivers[thing]?.capabilities
            .where((c) => c.type == CapabilityType.toggle)
            .toList() ??
        const [];
    return toggles.length == 1 &&
        (toggles.single.id == key ||
            stateKeyOf(toggles.single.stateJsonPath) == key);
  }

  /// The words for a state a thing reports: the label of the capability
  /// that fills that key (a TV's power sensor, not its Power key), without
  /// its parenthetical list of values.
  String state(String ref) {
    final (thing, key) = _split(ref);
    final reported = drivers[thing]?.capabilities
        .where((c) => stateKeyOf(c.stateJsonPath) == key)
        .firstOrNull;
    final words = reported == null
        ? _key(thing, key)
        : reported.label.replaceAll(RegExp(r'\s*\([^)]*\)'), '').toLowerCase();
    return '${name(thing)} $words';
  }

  static (String, String) _split(String ref) {
    final dot = ref.indexOf('.');
    return dot < 0
        ? (ref, '')
        : (ref.substring(0, dot), ref.substring(dot + 1));
  }

  static String value(Object? v) => switch (v) {
    true => 'on',
    false => 'off',
    String s => s,
    _ => '$v',
  };

  static String duration(Object? ms) {
    if (ms is! int) return '$ms ms';
    if (ms > 0 && ms % 3600000 == 0) return '${ms ~/ 3600000} h';
    if (ms > 0 && ms % 60000 == 0) return '${ms ~/ 60000} min';
    if (ms % 1000 == 0) return '${ms ~/ 1000} s';
    return '$ms ms';
  }

  static String seconds(Object? s) => s is int ? duration(s * 1000) : '$s s';

  bool _isMe(String thing) => thing == person;

  String trigger(Map<String, Object?> t) {
    if (rulesCoreTriggerWords(this, t) case final words?) return words;
    if (t['on'] is String) return 'When ${_on(t)}';
    if (t['time'] != null) {
      final days = t['days'];
      return 'At ${clock(t['time'])}${daysSuffix(days)}';
    }
    if (t['sun'] != null) {
      final label = sunTriggerLabel(t);
      return '${label[0].toUpperCase()}${label.substring(1)}';
    }
    if (t['interval'] != null) return 'Every ${seconds(t['interval'])}';
    return 'When I run it';
  }

  /// What an `on` trigger or a waitFor waits for, after "when".
  String _on(Map<String, Object?> t) {
    if (houseTriggerWords(t) case final words?) return words;
    final (thing, key) = _split(t['on'] as String);
    if (t['event'] == true) {
      if (drivers[thing]?.id == 'phone') {
        final words = phoneTriggerWords(name(thing), key, t['match']);
        if (words != null) return words;
      }
      if (key == 'scanned') return '${name(thing)} is scanned';
      return '${name(thing)} ${_key(thing, key)}';
    }
    final change = t['change'];
    final to = change is Map && change.containsKey('to') ? change['to'] : null;
    if (key == 'home' && to is bool && drivers[thing]?.id == 'person') {
      if (_isMe(thing)) return to ? 'I get home' : 'I leave';
      return '${name(thing)} ${to ? 'gets home' : 'leaves'}';
    }
    final crosses = t['crosses'];
    if (crosses is Map && crosses.isNotEmpty) {
      return '${state(t['on'] as String)} goes ${crosses.keys.single} '
          '${crosses.values.single}';
    }
    if (change is Map && change.containsKey('to')) {
      // A light's power reads as the light itself: "Desk lamp turns on".
      if (to is bool && isOnOff(thing, key)) {
        return '${name(thing)} turns ${value(to)}';
      }
      if (to is String && _isPowerChoice(thing, key)) {
        return '${name(thing)} ${to == 'asleep' ? 'falls asleep' : 'turns $to'}';
      }
      return '${state(t['on'] as String)} turns ${value(to)}';
    }
    return '${state(t['on'] as String)} changes';
  }

  static const _opWords = {
    '==': 'is',
    '!=': 'is not',
    '>': 'is above',
    '<': 'is below',
    '>=': 'is at least',
    '<=': 'is at most',
  };

  String condition(Map<String, Object?> c) {
    if (houseConditionWords(c) case final words?) return words;
    if (rulesCoreConditionWords(c) case final words?) return words;
    if (c['between'] case [final start, final end]) {
      return 'between ${clock(start)} and ${clock(end)}';
    }
    if (c['days'] is List) return daysWords(c['days'] as List);
    if (c['not'] is Map) {
      return 'not ${condition(Map<String, Object?>.from(c['not'] as Map))}';
    }
    for (final (group, word) in [('anyOf', ' or '), ('allOf', ' and ')]) {
      if (c[group] is List) {
        return [
          for (final inner in c[group] as List)
            condition(Map<String, Object?>.from(inner as Map)),
        ].join(word);
      }
    }
    final op = _opWords[c['op']] ?? '${c['op']}';
    final right = c['value'];
    final rightText = right is Map && right.length == 1
        ? (right.keys.single == 'state'
              ? state('${right.values.single}')
              : '${right.values.single}')
        : value(right);
    if (c['state'] case final String ref) {
      final (thing, key) = _split(ref);
      if (key == 'home' &&
          right is bool &&
          drivers[thing]?.id == 'person' &&
          (c['op'] == '==' || c['op'] == '!=')) {
        final home = (c['op'] == '==') == right;
        if (_isMe(thing)) return home ? 'I am home' : 'I am away';
        return '${name(thing)} is ${home ? 'home' : 'away'}';
      }
      // A power sensor compared with true (a TV's "power is on" written
      // as `=on`) reads as the thing, like its toggle would.
      if (right is bool &&
          (isOnOff(thing, key) || _isPowerChoice(thing, key)) &&
          (c['op'] == '==' || c['op'] == '!=')) {
        final on = (c['op'] == '==') == right;
        return '${name(thing)} is ${on ? 'on' : 'off'}';
      }
      if (right is String &&
          _isPowerChoice(thing, key) &&
          (c['op'] == '==' || c['op'] == '!=')) {
        return '${name(thing)} $op $right';
      }
      return '${state(ref)} $op $rightText';
    }
    if (c['var'] != null) return '${c['var']} $op $rightText';
    return 'the message ${c['msg']} $op $rightText';
  }

  /// The words for setting [ref] (`thing.action`) with [params].
  String action(String ref, Map? params) {
    final (thing, key) = _split(ref);
    final capability = _capability(thing, key);
    final who = name(thing);
    if (drivers[thing]?.id == 'phone') {
      if (phoneStepWords(who, key, params) case final words?) return words;
    }
    if (params == null || params.isEmpty) return '$who ${_key(thing, key)}';
    if (_lightWords(capability, params) case final words?) {
      return '$who $words';
    }
    if (params.length == 1 && params.containsKey('value')) {
      final v = params['value'];
      if (capability?.type == CapabilityType.toggle && v is bool) {
        return '$who ${value(v)}';
      }
      final unit = capability?.params['value']?.unit;
      final suffix = unit == null ? '' : (unit == '%' ? '%' : ' $unit');
      return '$who ${_key(thing, key)} ${value(v)}$suffix';
    }
    return '$who ${_key(thing, key)} '
        '${params.entries.map((e) => '${e.key} ${value(e.value)}').join(', ')}';
  }

  /// A light's scene, colour or white in words ([lightStepWords]).
  static String? _lightWords(CapabilitySpec? capability, Map params) {
    if (capability == null) return null;
    final scene = isWizSceneCapability(capability)
        ? wizSceneOf(params['scene'])
        : null;
    return lightStepWords(
      type: capability.type.wireName,
      params: params,
      unit: capability.params['value']?.unit,
      sceneName: isWizSceneCapability(capability)
          ? scene?.name ?? value(params['scene'])
          : null,
      sceneMoves: scene?.dynamic ?? true,
    );
  }

  String step(Map<String, Object?> s) {
    if (houseStepWords(s) case final words?) return words;
    if (s['do'] is String) {
      return action(s['do'] as String, s['params'] as Map?);
    }
    if (s['toggle'] is String) {
      final (thing, key) = _split(s['toggle'] as String);
      final capability = _capability(thing, key);
      return capability?.type == CapabilityType.toggle
          ? 'toggle ${name(thing)}'
          : 'toggle ${name(thing)} ${_key(thing, key)}';
    }
    if (s.containsKey('wait')) return 'wait ${duration(s['wait'])}';
    if (s['waitFor'] is Map) {
      final w = Map<String, Object?>.from(s['waitFor'] as Map);
      return 'wait up to ${duration(w['timeoutMs'])} for ${_on(w)}';
    }
    if (s['if'] is List) {
      return 'if ${[for (final c in s['if'] as List) condition(Map<String, Object?>.from(c as Map))].join(' and ')}…';
    }
    if (s['together'] is List) {
      return [
        for (final group in s['together'] as List)
          [
            for (final inner in group as List)
              step(Map<String, Object?>.from(inner as Map)),
          ].join(' then '),
      ].join(' and ');
    }
    if (s['try'] is List) {
      String list(Object? steps) => [
        for (final inner in steps as List? ?? const [])
          step(Map<String, Object?>.from(inner as Map)),
      ].join(' then ');
      final otherwise = s['otherwise'];
      return otherwise is List && otherwise.isNotEmpty
          ? 'try ${list(s['try'])}, if that fails ${list(otherwise)}'
          : 'try ${list(s['try'])}, and go on if it fails';
    }
    if (s['repeat'] is Map) {
      final r = Map<String, Object?>.from(s['repeat'] as Map);
      final until = r['until'] as List?;
      final how = [
        if (r['times'] != null)
          until == null ? '${r['times']} times' : 'up to ${r['times']} times',
        if (r['every'] case final int ms when ms > 0) 'every ${duration(ms)}',
        if (until != null)
          'until ${[for (final c in until) condition(Map<String, Object?>.from(c as Map))].join(' and ')}',
      ];
      final body = [
        for (final inner in r['do'] as List? ?? const [])
          step(Map<String, Object?>.from(inner as Map)),
      ].join(' then ');
      return 'repeat ${how.join(', ')}: $body';
    }
    if (s['notify'] is Map) {
      final n = s['notify'] as Map;
      return 'notify ${_toWhom(n)}"${spoken('${n['title']}')}"';
    }
    if (s['http'] is Map) {
      final h = s['http'] as Map;
      final host = Uri.tryParse('${h['url']}')?.host ?? '${h['url']}';
      return 'send a web request to $host';
    }
    if (s['set'] is Map) {
      final set = s['set'] as Map;
      return 'set ${set['var']} to ${value(set['value'])}';
    }
    if (s['run'] is String) {
      return 'run ${automations[s['run']] ?? s['run']}';
    }
    if (s['ask'] is Map) {
      final a = s['ask'] as Map;
      final choices = a['choices'];
      return choices is List && choices.isNotEmpty
          ? 'ask ${_toWhom(a)}"${spoken('${a['title']}')}" (${choices.join(' or ')})'
          : 'ask ${_toWhom(a)}"${spoken('${a['title']}')}" for an answer';
    }
    if (s['get'] is Map) {
      final g = s['get'] as Map;
      return g['path'] == null
          ? 'get ${_valueWords(g['from'])}'
          : 'get ${g['path']} from ${_valueWords(g['from'])}';
    }
    if (s['text'] is Map) {
      final t = s['text'] as Map;
      final how = switch (t['op']) {
        'upper' => ' in capitals',
        'lower' => ' in small letters',
        'trim' => ' without spaces at the ends',
        _ => '',
      };
      return 'make the text "${spoken('${t['value']}')}"$how';
    }
    if (s['math'] is Map) {
      return 'work out ${spoken('${(s['math'] as Map)['expr']}')}';
    }
    if (s['date'] is Map) {
      final d = s['date'] as Map;
      final offset = d['offsetMinutes'];
      final when = offset is int && offset != 0
          ? '${duration(offset.abs() * 60000)} ${offset < 0 ? 'ago' : 'from now'}'
          : 'now';
      return 'write the time $when as ${d['format'] ?? 'HH:mm'}';
    }
    if (s['forEach'] is Map) {
      final f = Map<String, Object?>.from(s['forEach'] as Map);
      final source = f['in'];
      final over = source is String && source.startsWith('room:')
          ? 'each device in ${source.substring(5).trim()}'
          : 'each item of ${_valueWords(source)}';
      final body = [
        for (final inner in f['do'] as List? ?? const [])
          step(Map<String, Object?>.from(inner as Map)),
      ].join(' then ');
      return 'for $over: $body';
    }
    return '$s';
  }

  /// A value a step reads, in words: a list as its items, a template as
  /// it is written.
  static String _valueWords(Object? v) => v is List
      ? v.map(value).join(', ')
      : v is String
      ? spoken(v)
      : value(v);

  /// [text] with each `{{...}}` written as words: "Mood: {{%answer}}" reads
  /// "Mood: the answer", "{{%reply.body.name}}" reads "the web reply's
  /// name".
  static String spoken(String text) => text.replaceAllMapped(
    RegExp(r'\{\{\s*([^}]+?)\s*\}\}'),
    (m) => _tokenWords(m[1]!),
  );

  static String _tokenWords(String ref) {
    const named = {
      '%answer': 'the answer',
      '%reply': 'the web reply',
      '%value': 'the value',
      '%text': 'the text',
      '%result': 'the result',
      '%date': 'the time',
      '%state': 'the device state',
      '%item': 'the item',
      'msg.value': 'the new value',
      'msg.device': 'the device',
      'msg.shared.text': 'the shared text',
      'msg.shared.url': 'the shared link',
      'msg.iteration': 'the pass number',
      'msg.error': 'the error',
    };
    if (named[ref] case final words?) return words;
    for (final e in named.entries) {
      if (ref.startsWith('${e.key}.')) {
        final rest = ref.substring(e.key.length + 1).replaceAll('.', ' ');
        final base = e.key == '%reply' ? 'the web reply' : e.value;
        return "$base's ${rest.replaceFirst(RegExp(r'^body '), '')}";
      }
    }
    if (ref.startsWith(r'$') || ref.startsWith('%')) return ref.substring(1);
    return ref;
  }

  /// A rule as chips: its triggers, then its conditions, an arrow, then
  /// its steps. A keep step reads "Keep X on" with its while as a condition.
  List<Map<String, Object?>> rule(Map<String, Object?> rule) {
    final out = <Map<String, Object?>>[];
    void joined(List<Map<String, Object?>> chips, String word) {
      for (var i = 0; i < chips.length; i++) {
        if (i > 0) out.add(_chip('text', word));
        out.add(chips[i]);
      }
    }

    final when = [
      for (final t in (rule['when'] as List? ?? const []))
        _chip('when', trigger(Map<String, Object?>.from(t as Map))),
    ];
    for (var i = 1; i < when.length; i++) {
      when[i] = _chip('when', _lower(when[i]['text'] as String));
    }
    joined(when, 'or');
    joined([
      for (final c in (rule['onlyIf'] as List? ?? const []))
        _chip('if', condition(Map<String, Object?>.from(c as Map))),
    ], 'and');
    final steps = [
      for (final s in (rule['then'] as List? ?? const []))
        Map<String, Object?>.from(s as Map),
    ];
    final plain = steps.where((s) => !s.containsKey('keep')).toList();
    if (out.isNotEmpty && plain.isNotEmpty) out.add(_chip('text', '→'));
    joined([for (final s in plain) _chip('then', step(s))], 'then');
    for (final s in steps.where((s) => s.containsKey('keep'))) {
      if (out.isNotEmpty) out.add(_chip('text', 'and'));
      final k = Map<String, Object?>.from(s['keep'] as Map);
      out.add(
        _chip(
          'then',
          'Keep ${action('${k['target']}', {'value': k['value']})}',
        ),
      );
      out.add(
        _chip(
          'if',
          'while ${[for (final c in k['while'] as List) condition(Map<String, Object?>.from(c as Map))].join(' and ')}',
        ),
      );
    }
    return out;
  }

  List<Map<String, Object?>> scene(Map<String, Object?> scene) {
    final out = <Map<String, Object?>>[];
    final actions = scene['actions'] as List? ?? const [];
    for (var i = 0; i < actions.length; i++) {
      if (i > 0) out.add(_chip('text', 'and'));
      final a = Map<String, Object?>.from(actions[i] as Map);
      out.add(_chip('then', action('${a['do']}', a['params'] as Map?)));
    }
    return out;
  }

  List<Map<String, Object?>> link(Map<String, Object?> link) {
    final from = '${link['from']}';
    final to = '${link['to']}';
    final (target, action) = _split(to);
    switch (link['mode']) {
      case 'follow':
        return [
          _chip('then', '${name(target)} ${_key(target, action)}'),
          _chip('text', 'follows'),
          _chip('when', state(from)),
        ];
      case 'threshold':
        final above = link['above'];
        return [
          _chip(
            'when',
            'When ${state(from)} goes ${above != null ? 'above $above' : 'below ${link['below']}'}',
          ),
          _chip('text', '→'),
          _chip('then', this.action(to, {'value': link['set']})),
        ];
      default:
        final capability = _capability(target, action);
        return [
          _chip(
            'when',
            'When ${state(from)} turns ${value(link['onValue'] ?? true)}',
          ),
          _chip('text', '→'),
          _chip(
            'then',
            capability?.type == CapabilityType.toggle
                ? 'toggle ${name(target)}'
                : 'toggle ${name(target)} ${_key(target, action)}',
          ),
        ];
    }
  }

  /// A graph as its node labels: triggers, conditions, then actions.
  List<Map<String, Object?>> graph(Map<String, Object?> flow) {
    final nodes = [
      for (final n in (flow['nodes'] as List? ?? const []))
        Map<String, Object?>.from(n as Map),
    ];
    String label(Map<String, Object?> n) => '${n['label'] ?? n['id']}';
    NodeCategory? category(Map<String, Object?> n) =>
        builtInNodeTypes[n['type']]?.category;
    final out = <Map<String, Object?>>[];
    void add(String kind, Iterable<Map<String, Object?>> of, String word) {
      var first = true;
      for (final n in of) {
        if (!first) out.add(_chip('text', word));
        out.add(_chip(kind, label(n)));
        first = false;
      }
    }

    add('when', nodes.where((n) => category(n) == NodeCategory.trigger), 'or');
    add('if', nodes.where((n) => category(n) == NodeCategory.condition), 'and');
    final actions = nodes.where((n) => category(n) == NodeCategory.action);
    if (out.isNotEmpty && actions.isNotEmpty) out.add(_chip('text', '→'));
    add('then', actions, 'then');
    return out;
  }

  List<Map<String, Object?>> sentence(FlowRecord r) {
    final spec = r.spec;
    try {
      return switch (r.source) {
        FlowRecord.rule when spec != null => rule(spec),
        FlowRecord.scene when spec != null => scene(spec),
        FlowRecord.link when spec != null => link(spec),
        _ => graph(r.json),
      };
    } catch (_) {
      // A spec stored by an older engine may not have today's shape.
      return graph(r.json);
    }
  }

  static String _lower(String text) =>
      text.isEmpty ? text : text[0].toLowerCase() + text.substring(1);
}

/// The things a flow reads or drives: every device, trigger thing and
/// state it compares.
Set<String> thingsIn(Object? value) {
  final out = <String>{};
  void walk(Object? v) {
    switch (v) {
      case Map m:
        if (m['deviceId'] case final String id when !id.startsWith('{{')) {
          out.add(id);
        }
        if (m['thing'] case final String id) out.add(id);
        if (m['state'] case final String ref when ref.contains('.')) {
          out.add(ref.substring(0, ref.indexOf('.')));
        }
        m.values.forEach(walk);
      case List l:
        l.forEach(walk);
    }
  }

  walk(value);
  return out;
}

/// The things a flow's actions drive.
Set<String> thingsDriven(Map<String, Object?> flow) => {
  for (final n in (flow['nodes'] as List? ?? const []))
    if (n is Map &&
        builtInNodeTypes[n['type']]?.category == NodeCategory.action &&
        n['config'] is Map &&
        (n['config'] as Map)['deviceId'] is String &&
        !((n['config'] as Map)['deviceId'] as String).startsWith('{{'))
      (n['config'] as Map)['deviceId'] as String,
};

/// A run from the log as the automation list shows it: when, whether it
/// went well, how many steps ran, and the failure.
Map<String, Object?> lastRunOf(Map<String, Object?> trace) {
  final nodes = (trace['nodes'] as List? ?? const []).whereType<Map>();
  final steps = nodes.where((n) {
    final category = builtInNodeTypes[n['type']]?.category;
    return category != null &&
        category != NodeCategory.trigger &&
        category != NodeCategory.condition;
  }).length;
  final ok = trace['outcome'] == 'completed';
  return {
    'at': trace['startedAt'],
    'ok': ok,
    'steps': steps,
    'run': trace['run'],
    'outcome': trace['outcome'],
    if (!ok && trace['reason'] != null) 'error': trace['reason'],
  };
}
