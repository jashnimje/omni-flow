import 'dart:convert';

import '../manifest/validation.dart';
import '../devices/device_service.dart' show stateKeyOf;
import 'flow.dart';
import 'node_types.dart';
import 'rule_shorthand.dart';

export 'rule_shorthand.dart' show RuleContext;

/// A rule: when one of these, only if all of these, then these steps.
///
/// ```json
/// {"name": "Evening lights",
///  "when": [{"on": "jade.home", "change": {"to": true}}, {"time": "18:00"}],
///  "onlyIf": [{"state": "lamp.power", "op": "==", "value": false}],
///  "then": [{"do": "lamp.power", "params": {"value": true}}, {"wait": 2000},
///           {"notify": {"title": "Welcome home"}}]}
/// ```
///
/// A `keep` step holds a value while conditions hold: `{"keep": {"target":
/// "fan.power", "value": true, "while": [{"state": "room.temp", "op": ">",
/// "value": 28}], "release"?: false}}`. Keep steps come last in `then`, and
/// a rule of keep steps alone needs no `when`. A failed step does not stop
/// the rest of the rule unless it sets `stopOnError: true`.
///
/// Each list item may also be a shorthand string (`home:entered`,
/// `lamp.power=true`, `wait:2s`), which [normalizeRule] expands, so the
/// stored rule is always the object form.
abstract final class RuleKeys {
  static const root = [
    'id',
    'name',
    'when',
    'onlyIf',
    'then',
    'mode',
    'cooldownSeconds',
    'enabled',
    'stopOnError',
  ];
  static const triggers = ['on', 'time', 'interval', 'manual'];
  static const onModes = ['event', 'change', 'crosses'];
  static const conditions = [
    'state',
    'var',
    'msg',
    'between',
    'days',
    'not',
    'anyOf',
    'allOf',
  ];
  static const steps = [
    'do',
    'toggle',
    'wait',
    'waitFor',
    'if',
    'together',
    'repeat',
    'try',
    'notify',
    'set',
    'run',
    'keep',
  ];

  /// The most passes a repeat step makes, and how many it makes when it
  /// only names when to stop.
  static const repeatMax = 1000;
  static const repeatDefault = 100;

  /// The run modes a rule with a keep step may use: a hold must answer
  /// every change, even while an earlier run is still going.
  static const keepModes = ['parallel', 'queued'];
}

final _id = RegExp(r'^[a-z][a-z0-9_]*$');
final _action = RegExp(r'^([a-z][a-z0-9_]*)\.([a-z][a-z0-9_]*)$');
final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final _variable = RegExp(r'^[$%][A-Za-z_][A-Za-z0-9_]*$');
final _msgKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*$');
const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// The id a rule named [name] is saved under when it gives none.
String ruleIdFor(String name) {
  var slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  // The slug drops every non-ASCII letter, so 'शाम' and '🌙' would share
  // one id and the second save would replace the first rule.
  if (name.runes.any((r) => r > 0x7f)) {
    slug = slug.isEmpty ? _nameHash(name) : '${slug}_${_nameHash(name)}';
  }
  return _id.hasMatch(slug) ? slug : 'rule_$slug'.replaceAll(RegExp(r'_$'), '');
}

/// A short FNV-1a hash of [name], the same on every run.
String _nameHash(String name) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(name.trim())) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36).padLeft(7, '0');
}

/// [json] as a rule in its stored form: shorthand expanded, `change: true`
/// as `{}`, `id` filled in, `enabled` left to the stored record. Throws a
/// [ValidationException] with every problem, each at its rule path
/// (`then[2].do`).
Map<String, Object?> normalizeRule(
  Object? json, {
  RuleContext context = const RuleContext(),
}) {
  final issues = IssueCollector();
  if (json is! Map) {
    throw ValidationException('rule', [
      const ValidationIssue('rule', 'must be an object'),
    ]);
  }
  final rule = Map<String, Object?>.from(json);
  for (final key in rule.keys) {
    if (!RuleKeys.root.contains(key)) {
      issues.add(key, 'is not a rule key (${RuleKeys.root.join(', ')})');
    }
  }
  final name = rule['name'];
  if (name is! String || name.trim().isEmpty) {
    issues.add('name', 'is required');
  }
  var id = rule['id'];
  if (id == null && name is String && name.trim().isNotEmpty) {
    id = ruleIdFor(name);
  }
  if (id != null && (id is! String || !_id.hasMatch(id))) {
    issues.add('id', 'must be lower snake case, like evening_lights');
  }
  final out = <String, Object?>{'id': id, 'name': name};
  final norm = _Normalizer(issues, context);
  final rawThen = rule['then'];
  final holds = rawThen is List && rawThen.any(_isKeep);
  final onlyHolds =
      rawThen is List && rawThen.isNotEmpty && rawThen.every(_isKeep);
  final noWhen =
      onlyHolds &&
      (rule['when'] == null ||
          (rule['when'] is List && (rule['when'] as List).isEmpty));
  out['when'] = noWhen
      ? const <Object?>[]
      : norm.list(rule['when'], 'when', norm.trigger, required: true);
  if (rule['onlyIf'] != null) {
    out['onlyIf'] = norm.list(rule['onlyIf'], 'onlyIf', norm.condition);
    if (noWhen && (out['onlyIf'] as List).isNotEmpty) {
      issues.add('onlyIf', 'needs a when: a keep step has its own while');
    }
  }
  out['then'] = norm.steps(rule['then'], 'then');
  if (rawThen is List) {
    final firstKeep = rawThen.indexWhere(_isKeep);
    for (var i = firstKeep + 1; firstKeep >= 0 && i < rawThen.length; i++) {
      if (!_isKeep(rawThen[i])) {
        issues.add('then[$i]', 'comes after a keep step: keep steps go last');
      }
    }
  }
  if (holds &&
      rule['mode'] != null &&
      !RuleKeys.keepModes.contains(rule['mode'])) {
    issues.add(
      'mode',
      'must be ${RuleKeys.keepModes.join(' or ')} for a rule with a keep '
          'step, so the hold answers every change',
    );
  }
  if (rule['stopOnError'] != null) {
    if (rule['stopOnError'] is! bool) {
      issues.add('stopOnError', 'must be true or false');
    } else if (rule['stopOnError'] == true) {
      out['stopOnError'] = true;
    }
  }
  if (rule['mode'] != null) {
    if (RunMode.fromWire(rule['mode']) == null) {
      issues.add(
        'mode',
        'must be one of ${RunMode.values.map((m) => m.name).join(', ')}',
      );
    }
    out['mode'] = rule['mode'];
  }
  if (rule['cooldownSeconds'] != null) {
    issues.optionalInt(rule, 'cooldownSeconds', r'$', min: 0);
    out['cooldownSeconds'] = rule['cooldownSeconds'];
  }
  if (rule['enabled'] != null && rule['enabled'] is! bool) {
    issues.add('enabled', 'must be true or false');
  }
  if (issues.hasIssues) {
    throw ValidationException('rule ${id is String ? id : ''}'.trim(), [
      for (final i in issues.issues) _strip(i),
    ]);
  }
  return out;
}

bool _isKeep(Object? step) => step is Map && step.containsKey('keep');

/// IssueCollector helpers write `$.key`, and rule paths have no root.
ValidationIssue _strip(ValidationIssue i) => i.path.startsWith(r'$.')
    ? ValidationIssue(i.path.substring(2), i.message)
    : i;

class _Normalizer {
  _Normalizer(this.issues, this.context);

  final IssueCollector issues;
  final RuleContext context;

  List<Object?> list(
    Object? value,
    String path,
    Map<String, Object?>? Function(Object? item, String path) each, {
    bool required = false,
  }) {
    if (value == null && !required) return const [];
    if (value is! List) {
      issues.add(path, 'must be a list');
      return const [];
    }
    if (required && value.isEmpty) {
      issues.add(path, 'needs at least one item');
      return const [];
    }
    return [
      for (var i = 0; i < value.length; i++) ?each(value[i], '$path[$i]'),
    ];
  }

  List<Object?> steps(Object? value, String path) =>
      list(value, path, step, required: true);

  /// [item] as a map, expanding a shorthand string with [expand].
  Map<String, Object?>? _object(
    Object? item,
    String path,
    Map<String, Object?> Function(String) expand,
    List<String> kinds,
    String what,
  ) {
    if (item is String) {
      try {
        return expand(item);
      } on ShorthandException catch (e) {
        issues.add(path, '"$item" ${e.message}');
        return null;
      }
    }
    if (item is! Map) {
      issues.add(path, 'must be an object or a shorthand string');
      return null;
    }
    final map = Map<String, Object?>.from(item);
    final found = [
      for (final k in kinds)
        if (map.containsKey(k)) k,
    ];
    if (found.length != 1) {
      issues.add(
        path,
        found.isEmpty
            ? 'a $what needs one of ${kinds.join(', ')}'
            : 'a $what takes one of ${found.join(' and ')}, not both',
      );
      return null;
    }
    return map;
  }

  void _only(
    Map<String, Object?> map,
    String path,
    Set<String> allowed,
    String what,
  ) {
    for (final k in map.keys) {
      if (!allowed.contains(k)) issues.add('$path.$k', 'is not a key of $what');
    }
  }

  Map<String, Object?>? trigger(Object? item, String path) {
    final map = _object(
      item,
      path,
      (s) => expandTrigger(s, context),
      RuleKeys.triggers,
      'trigger',
    );
    if (map == null) return null;
    if (map.containsKey('on')) return on(map, path, const {}, 'an on trigger');
    if (map.containsKey('time')) {
      _only(map, path, {'time', 'days'}, 'a time trigger');
      final time = map['time'];
      if (time is! String || !_hhmm.hasMatch(time)) {
        issues.add('$path.time', 'must be a 24-hour time like 18:00');
      }
      if (map['days'] != null) _dayList(map['days'], '$path.days');
      return {'time': time, 'days': ?map['days']};
    }
    if (map.containsKey('interval')) {
      _only(map, path, {'interval'}, 'an interval trigger');
      final seconds = map['interval'];
      if (seconds is! int || seconds < 1) {
        issues.add('$path.interval', 'must be whole seconds, at least 1');
      }
      return {'interval': seconds};
    }
    _only(map, path, {'manual'}, 'a manual trigger');
    if (map['manual'] != true) issues.add('$path.manual', 'must be true');
    return {'manual': true};
  }

  /// An `on` trigger, or the `on` part of a waitFor with [extra] keys.
  Map<String, Object?>? on(
    Map<String, Object?> map,
    String path,
    Set<String> extra,
    String what,
  ) {
    _only(map, path, {'on', ...RuleKeys.onModes, 'match', ...extra}, what);
    final ref = map['on'];
    if (ref is! String || !thingKeyPattern.hasMatch(ref)) {
      issues.add('$path.on', 'must be thing.key, like front_door.scanned');
    }
    final modes = [
      for (final m in RuleKeys.onModes)
        if (map[m] != null && map[m] != false) m,
    ];
    if (modes.length > 1) {
      issues.add(path, 'takes one of event, change or crosses, not both');
      return null;
    }
    final mode = modes.firstOrNull ?? 'change';
    if (map['match'] != null && mode != 'event') {
      issues.add('$path.match', 'is only for an event');
    }
    final out = <String, Object?>{'on': ref};
    switch (mode) {
      case 'event':
        if (map['event'] != true) issues.add('$path.event', 'must be true');
        final match = map['match'];
        if (match != null && match is! Map) {
          issues.add('$path.match', 'must be an object of payload values');
        }
        out['event'] = true;
        if (match != null) out['match'] = match;
      case 'change':
        final change = map['change'];
        if (change == null || change == true) {
          out['change'] = <String, Object?>{};
        } else if (change is Map && change.keys.every((k) => k == 'to')) {
          out['change'] = Map<String, Object?>.from(change);
        } else {
          issues.add('$path.change', 'must be true, {} or {"to": value}');
        }
      case 'crosses':
        final crosses = map['crosses'];
        if (crosses is! Map ||
            crosses.length != 1 ||
            !const {'above', 'below'}.contains(crosses.keys.single) ||
            crosses.values.single is! num) {
          issues.add(
            '$path.crosses',
            'must be {"above": number} or {"below": number}',
          );
        }
        out['crosses'] = crosses;
    }
    return out;
  }

  Map<String, Object?>? condition(Object? item, String path) {
    final map = _object(
      item,
      path,
      expandCondition,
      RuleKeys.conditions,
      'condition',
    );
    if (map == null) return null;
    final kind = RuleKeys.conditions.firstWhere(map.containsKey);
    switch (kind) {
      case 'state' || 'var' || 'msg':
        _only(map, path, {kind, 'op', 'value'}, 'a compare');
        final ref = map[kind];
        _reference(kind, ref, '$path.$kind');
        final op = map['op'] == '=' ? '==' : map['op'] ?? '==';
        if (!compareOps.contains(op)) {
          issues.add('$path.op', 'must be one of ${compareOps.join(', ')}');
        }
        if (!map.containsKey('value')) issues.add('$path.value', 'is required');
        final value = map['value'];
        if (_isReference(value)) {
          final source = (value as Map).keys.single as String;
          _reference(source, value.values.single, '$path.value.$source');
        } else if (const {'<', '<=', '>', '>='}.contains(op) && value is! num) {
          issues.add('$path.value', 'must be a number for $op');
        }
        return {kind: ref, 'op': op, 'value': value};
      case 'between':
        _only(map, path, {'between'}, 'a time window');
        final b = map['between'];
        if (b is! List ||
            b.length != 2 ||
            b.any((t) => t is! String || !_hhmm.hasMatch(t))) {
          issues.add('$path.between', 'must be ["HH:MM", "HH:MM"]');
        }
        return {'between': b};
      case 'days':
        _only(map, path, {'days'}, 'a days condition');
        _dayList(map['days'], '$path.days');
        return {'days': map['days']};
      case 'not':
        _only(map, path, {'not'}, 'a not');
        final inner = condition(map['not'], '$path.not');
        return inner == null ? null : {'not': inner};
      default:
        _only(map, path, {kind}, 'an $kind');
        final rules = list(map[kind], '$path.$kind', condition, required: true);
        return {kind: rules};
    }
  }

  static final _topLevelStep = RegExp(r'^then\[\d+\]$');

  Map<String, Object?>? step(Object? item, String path) {
    final map = _object(item, path, expandStep, RuleKeys.steps, 'step');
    if (map == null) return null;
    final kind = RuleKeys.steps.firstWhere(map.containsKey);
    switch (kind) {
      case 'keep':
        if (!_topLevelStep.hasMatch(path)) {
          issues.add(path, 'a keep step goes at the end of the rule\'s then');
          return null;
        }
        return keep(map, path);
      case 'do' || 'toggle':
        _only(map, path, {kind, if (kind == 'do') 'params'}, 'a $kind step');
        final ref = map[kind];
        if (ref is! String || !_action.hasMatch(ref)) {
          issues.add('$path.$kind', 'must be thing.action, like lamp.power');
        }
        final params = map['params'];
        if (params != null && params is! Map) {
          issues.add('$path.params', 'must be an object');
        }
        return {kind: ref, 'params': ?params};
      case 'wait':
        _only(map, path, {'wait'}, 'a wait');
        final ms = map['wait'];
        if (ms is! int || ms < 0 || ms > 86400000) {
          issues.add('$path.wait', 'must be milliseconds, 0 to 86400000');
        }
        return {'wait': ms};
      case 'waitFor':
        _only(map, path, {'waitFor'}, 'a waitFor step');
        final wait = map['waitFor'];
        if (wait is! Map) {
          issues.add('$path.waitFor', 'must be {on, timeoutMs, onTimeout?}');
          return null;
        }
        final w = Map<String, Object?>.from(wait);
        final at = '$path.waitFor';
        final out = on(w, at, const {'timeoutMs', 'onTimeout'}, 'a waitFor');
        final timeout = w['timeoutMs'];
        if (timeout is! int || timeout < 1 || timeout > 86400000) {
          issues.add('$at.timeoutMs', 'must be milliseconds, 1 to 86400000');
        }
        if (out == null) return null;
        return {
          'waitFor': {
            ...out,
            'timeoutMs': timeout,
            if (w['onTimeout'] != null)
              'onTimeout': steps(w['onTimeout'], '$at.onTimeout'),
          },
        };
      case 'if':
        _only(map, path, {'if', 'then', 'else'}, 'an if step');
        final single = map['if'] is Map || map['if'] is String;
        final conditions = single ? [map['if']] : map['if'];
        return {
          'if': list(conditions, '$path.if', condition, required: true),
          'then': steps(map['then'], '$path.then'),
          if (map['else'] != null) 'else': steps(map['else'], '$path.else'),
        };
      case 'together':
        _only(map, path, {'together'}, 'a together step');
        final groups = map['together'];
        if (groups is! List || groups.length < 2) {
          issues.add('$path.together', 'needs two or more lists of steps');
          return null;
        }
        return {
          'together': [
            for (var g = 0; g < groups.length; g++)
              steps(groups[g], '$path.together[$g]'),
          ],
        };
      case 'try':
        _only(map, path, {'try', 'otherwise'}, 'a try step');
        return {
          'try': steps(map['try'], '$path.try'),
          if (map['otherwise'] != null)
            'otherwise': steps(map['otherwise'], '$path.otherwise'),
        };
      case 'repeat':
        _only(map, path, {'repeat'}, 'a repeat step');
        final r = map['repeat'];
        final at = '$path.repeat';
        if (r is! Map) {
          issues.add(at, 'must be {do, times?, until?, every?}');
          return null;
        }
        _only(Map<String, Object?>.from(r), at, {
          'do',
          'times',
          'until',
          'every',
        }, 'a repeat');
        final times = r['times'];
        if (times != null &&
            (times is! int || times < 1 || times > RuleKeys.repeatMax)) {
          issues.add('$at.times', 'must be 1 to ${RuleKeys.repeatMax}');
        }
        if (times == null && r['until'] == null) {
          issues.add(at, 'needs times, until, or both, so it always ends');
        }
        final every = r['every'];
        if (every != null && (every is! int || every < 0 || every > 86400000)) {
          issues.add('$at.every', 'must be milliseconds, 0 to 86400000');
        }
        final until = r['until'];
        return {
          'repeat': {
            'do': steps(r['do'], '$at.do'),
            'times': ?times,
            if (until != null)
              'until': list(
                until is List ? until : [until],
                '$at.until',
                condition,
                required: true,
              ),
            'every': ?every,
          },
        };
      case 'notify':
        _only(map, path, {'notify'}, 'a notify step');
        final n = map['notify'];
        final payload = n is String ? {'title': n} : n;
        if (payload is! Map ||
            payload['title'] is! String ||
            (payload['title'] as String).trim().isEmpty) {
          issues.add('$path.notify', 'needs a title: "text" or {"title": ...}');
          return null;
        }
        return {'notify': Map<String, Object?>.from(payload)};
      case 'set':
        _only(map, path, {'set'}, 'a set step');
        final s = map['set'];
        if (s is! Map) {
          issues.add('$path.set', r'must be {"var": "$Name", "value": ...}');
          return null;
        }
        if (s['var'] is! String || !_variable.hasMatch(s['var'] as String)) {
          issues.add('$path.set.var', r'must be $Name (global) or %name (run)');
        }
        if (!s.containsKey('value')) {
          issues.add('$path.set.value', 'is required');
        }
        return {
          'set': {'var': s['var'], 'value': s['value']},
        };
      default:
        _only(map, path, {'run'}, 'a run step');
        final target = map['run'];
        if (target is! String || !_id.hasMatch(target)) {
          issues.add('$path.run', 'must be an automation id');
        }
        return {'run': target};
    }
  }

  Map<String, Object?>? keep(Map<String, Object?> map, String path) {
    _only(map, path, {'keep'}, 'a keep step');
    final keep = map['keep'];
    final at = '$path.keep';
    if (keep is! Map) {
      issues.add(at, 'must be {target, value, while, release?}');
      return null;
    }
    final k = Map<String, Object?>.from(keep);
    _only(k, at, {'target', 'value', 'while', 'release'}, 'a keep');
    final target = k['target'];
    if (target is! String || !_action.hasMatch(target)) {
      issues.add('$at.target', 'must be thing.action, like hall_bulb.power');
    }
    if (!k.containsKey('value')) issues.add('$at.value', 'is required');
    final hold = list(k['while'], '$at.while', condition, required: true);
    if (_readsMsg(hold)) {
      issues.add('$at.while', 'cannot read the message: a hold has none');
    }
    return {
      'keep': {
        'target': target,
        'value': k['value'],
        'while': hold,
        if (k.containsKey('release')) 'release': k['release'],
      },
    };
  }

  static bool _readsMsg(Object? value) => switch (value) {
    Map m => m.containsKey('msg') || m.values.any(_readsMsg),
    List l => l.any(_readsMsg),
    _ => false,
  };

  /// Checks one side of a compare: a `state`, `var` or `msg` reference. A
  /// `literal` is taken as it is.
  void _reference(String kind, Object? ref, String path) {
    final ok = switch (kind) {
      'state' => ref is String && thingKeyPattern.hasMatch(ref),
      'var' => ref is String && _variable.hasMatch(ref),
      'msg' => ref is String && _msgKey.hasMatch(ref),
      _ => true,
    };
    if (ok) return;
    issues.add(path, switch (kind) {
      'state' => 'must be thing.key, like jade.home',
      'var' => r'must be $Name (global) or %name (run)',
      _ => 'must be a message key like value or payload.temp',
    });
  }

  void _dayList(Object? days, String path) {
    if (days is! List || days.isEmpty || days.any((d) => !_days.contains(d))) {
      issues.add(path, 'must be a non-empty list of ${_days.join(', ')}');
    }
  }
}

bool _isReference(Object? v) =>
    v is Map && v.length == 1 && compareSources.contains(v.keys.single);

/// A rule compiled to its flow, with where each node came from so graph
/// issues can be told at rule paths.
class RuleCompilation {
  RuleCompilation._(this.flow, this._origins);

  /// The flow JSON that runs the rule.
  final Map<String, Object?> flow;

  /// Per node id: the config path prefix to rule path, longest first wins.
  final Map<String, Map<String, String>> _origins;

  static final _nodePath = RegExp(r'^\$\.nodes\[(\d+)\](?:\.config)?\.?(.*)$');

  /// [issues] from `validateFlow` on [flow], at rule paths.
  List<ValidationIssue> toRulePaths(List<ValidationIssue> issues) {
    final nodes = (flow['nodes'] as List).cast<Map<String, Object?>>();
    return [
      for (final issue in issues)
        ValidationIssue(_rulePath(issue.path, nodes), issue.message),
    ];
  }

  String _rulePath(String path, List<Map<String, Object?>> nodes) {
    if (path == r'$.mode') return 'mode';
    if (path == r'$.cooldownSeconds') return 'cooldownSeconds';
    final m = _nodePath.firstMatch(path);
    if (m == null) return path.startsWith(r'$.') ? path.substring(2) : path;
    final index = int.parse(m.group(1)!);
    final origin = index < nodes.length ? _origins[nodes[index]['id']] : null;
    if (origin == null) return path;
    final rest = path.contains('.config') ? m.group(2)! : '';
    String? best;
    for (final key in origin.keys) {
      final hit =
          rest == key ||
          key.isEmpty ||
          rest.startsWith('$key.') ||
          rest.startsWith('$key[');
      if (hit && (best == null || key.length > best.length)) best = key;
    }
    if (best == null) return origin['']!;
    final tail = rest.substring(best.length);
    final base = origin[best]!;
    if (tail.isEmpty) return base;
    return best.isEmpty ? '$base.$tail' : '$base$tail';
  }
}

/// Compiles a rule [normalizeRule] returned to its flow: every trigger feeds
/// one chain, the onlyIf conditions gate it, and the steps run in order.
///
/// A state read through [refs] may name the capability instead of the state
/// key it reports under (`lamp.power` for a lamp that reports `state`).
/// The words a compiled node is labelled with: a trigger or a device step
/// in the names the user gave things. Null keeps the rule's own text.
typedef RuleWords = ({
  String Function(Map<String, Object?> trigger) trigger,
  String Function(Map<String, Object?> step) step,
  String Function(Map<String, Object?> condition) condition,
});

RuleCompilation compileRule(
  Map<String, Object?> rule, {
  bool enabled = true,
  FlowReferences refs = const FlowReferences(),
  RuleWords? words,
}) {
  final when = (rule['when'] as List).cast<Map<String, Object?>>();
  final c = _Compiler(when.length, refs, '${rule['id']}', words);
  var open = <(String, String)>[];
  for (var i = 0; i < when.length; i++) {
    open.add((c.trigger(when[i], 'when[$i]', row: i), 'out'));
  }
  final onlyIf = (rule['onlyIf'] as List?)?.cast<Map<String, Object?>>();
  if (onlyIf != null && onlyIf.isNotEmpty) {
    final id = c.conditions(
      onlyIf,
      'onlyIf',
      'only_if',
      label: 'only if',
      col: 1,
      row: 0,
    );
    c.connect(open, id);
    open = [(id, 'true')];
  }
  final then = (rule['then'] as List).cast<Map<String, Object?>>();
  c.steps(then, 'then', open, col: 2, row: 0);
  final holds = then.any((s) => s.containsKey('keep'));
  return RuleCompilation._({
    'schemaVersion': supportedFlowSchemaVersion,
    'id': rule['id'],
    'name': rule['name'],
    'enabled': enabled,
    'mode':
        rule['mode'] ?? (holds ? RunMode.parallel.name : RunMode.single.name),
    'cooldownSeconds': rule['cooldownSeconds'] ?? 0,
    if (rule['stopOnError'] != true) 'onError': 'continue',
    'nodes': c.nodes,
    'edges': c.edges,
  }, c.origins);
}

class _Compiler {
  _Compiler(this._rows, this._refs, this._ruleId, this._words);

  final FlowReferences _refs;
  final RuleWords? _words;
  final String _ruleId;

  final nodes = <Map<String, Object?>>[];
  final edges = <Map<String, Object?>>[];
  final origins = <String, Map<String, String>>{};

  /// The next free row on the canvas, below the triggers.
  int _rows;

  static String idOf(String path) => path
      .replaceAll(RegExp(r'[\[\].]+'), '_')
      .replaceAll(RegExp(r'_+$'), '')
      .replaceAllMapped(
        RegExp('[A-Z]'),
        (m) => '_${m.group(0)!.toLowerCase()}',
      );

  String add(
    String id,
    String type,
    String label,
    Map<String, Object?> config,
    Map<String, String> origin, {
    required int col,
    required int row,
  }) {
    nodes.add({
      'id': id,
      'type': type,
      'label': label,
      'config': config,
      'position': {'x': 220 * col, 'y': 140 * row},
    });
    origins[id] = origin;
    return id;
  }

  void connect(List<(String, String)> from, String to) {
    for (final (node, port) in from) {
      edges.add({
        'id': 'e${edges.length + 1}',
        'from': {'node': node, 'port': port},
        'to': {'node': to, 'port': 'in'},
      });
    }
  }

  static (String, String) thingKey(Object? ref) {
    final m = thingKeyPattern.firstMatch(ref as String)!;
    return (m.group(1)!, m.group(2)!);
  }

  /// The state key [thing] reports [key] under: [key] itself, or the state
  /// key of the capability [key]. A thing that takes any key still reports
  /// a capability under its declared state key.
  String stateKey(String thing, String key) {
    final known = _refs.stateKeysOf(thing);
    if (known != null && known.contains(key)) return key;
    return stateKeyOf(_refs.capabilityOf(thing, key)?.stateJsonPath) ?? key;
  }

  String stateRef(Object? ref) {
    final (thing, key) = thingKey(ref);
    return '$thing.${stateKey(thing, key)}';
  }

  /// The `on` config, and its origin under [path].
  (Map<String, Object?>, Map<String, String>) onConfig(
    Map<String, Object?> t,
    String path,
  ) {
    final (thing, raw) = thingKey(t['on']);
    final key = t['event'] == true ? raw : stateKey(thing, raw);
    return (
      {
        'thing': thing,
        'key': key,
        if (t['event'] == true) 'event': true,
        'match': ?t['match'],
        'change': ?t['change'],
        'crosses': ?t['crosses'],
      },
      {
        '': path,
        'thing': '$path.on',
        'key': '$path.on',
        'event': '$path.event',
        'match': '$path.match',
        'change': '$path.change',
        'crosses': '$path.crosses',
      },
    );
  }

  String trigger(Map<String, Object?> t, String path, {required int row}) {
    final id = idOf(path);
    if (t.containsKey('on')) {
      final (config, origin) = onConfig(t, path);
      final how = t['event'] == true
          ? 'happens'
          : t['crosses'] is Map
          ? 'goes ${(t['crosses'] as Map).keys.single} ${(t['crosses'] as Map).values.single}'
          : (t['change'] as Map).containsKey('to')
          ? 'turns ${(t['change'] as Map)['to']}'
          : 'changes';
      final label = _words?.trigger(t) ?? '${t['on']} $how';
      return add(id, 'on', label, config, origin, col: 0, row: row);
    }
    if (t.containsKey('time')) {
      return add(
        id,
        'time_of_day',
        'at ${t['time']}${t['days'] == null ? '' : ' on ${(t['days'] as List).join(', ')}'}',
        {'at': t['time'], 'days': ?t['days']},
        {'': path, 'at': '$path.time', 'days': '$path.days'},
        col: 0,
        row: row,
      );
    }
    if (t.containsKey('interval')) {
      return add(
        id,
        'interval',
        'every ${t['interval']} s',
        {'seconds': t['interval']},
        {'': path, 'seconds': '$path.interval'},
        col: 0,
        row: row,
      );
    }
    return add(id, 'manual', 'run by hand', {}, {'': path}, col: 0, row: row);
  }

  /// [conditions] as one rule a node can evaluate: the condition itself, or
  /// an all_of of them. Their paths go into [origin] under [prefix].
  Map<String, Object?> ruleOf(
    List<Map<String, Object?>> conditions,
    String path,
    String prefix,
    Map<String, String> origin,
  ) => conditions.length == 1
      ? condition(conditions.single, '$path[0]', prefix, origin)
      : {
          'type': 'all_of',
          'rules': [
            for (var j = 0; j < conditions.length; j++)
              condition(
                conditions[j],
                '$path[$j]',
                _join(prefix, 'rules[$j]'),
                origin,
              ),
          ],
        };

  /// One condition node for [conditions] at [path]: the condition itself, or
  /// an all_of of them.
  String conditions(
    List<Map<String, Object?>> conditions,
    String path,
    String id, {
    required String label,
    required int col,
    required int row,
  }) {
    final origin = <String, String>{'': path};
    final Map<String, Object?> rule;
    if (conditions.length == 1) {
      rule = condition(conditions.single, '$path[0]', '', origin);
    } else {
      rule = {
        'type': 'all_of',
        'rules': [
          for (var j = 0; j < conditions.length; j++)
            condition(conditions[j], '$path[$j]', 'rules[$j]', origin),
        ],
      };
    }
    final type = rule.remove('type') as String;
    return add(
      id,
      type,
      '$label ${conditions.map(_words?.condition ?? describe).join(' and ')}',
      rule,
      origin,
      col: col,
      row: row,
    );
  }

  static String _join(String prefix, String key) =>
      prefix.isEmpty ? key : '$prefix.$key';

  /// The condition rule for [cond], recording its rule paths in [origin]
  /// under the config path [at].
  Map<String, Object?> condition(
    Map<String, Object?> cond,
    String path,
    String at,
    Map<String, String> origin,
  ) {
    origin[at] = path;
    if (cond.containsKey('between')) {
      origin[_join(at, 'start')] = '$path.between[0]';
      origin[_join(at, 'end')] = '$path.between[1]';
      final b = cond['between'] as List;
      return {'type': 'time_window', 'start': b[0], 'end': b[1]};
    }
    if (cond.containsKey('days')) {
      origin[_join(at, 'days')] = '$path.days';
      return {'type': 'days', 'days': cond['days']};
    }
    if (cond.containsKey('not')) {
      return {
        'type': 'not',
        'rule': condition(
          cond['not'] as Map<String, Object?>,
          '$path.not',
          _join(at, 'rule'),
          origin,
        ),
      };
    }
    for (final group in ['anyOf', 'allOf']) {
      if (!cond.containsKey(group)) continue;
      final rules = (cond[group] as List).cast<Map<String, Object?>>();
      return {
        'type': group == 'anyOf' ? 'any_of' : 'all_of',
        'rules': [
          for (var j = 0; j < rules.length; j++)
            condition(
              rules[j],
              '$path.$group[$j]',
              _join(at, 'rules[$j]'),
              origin,
            ),
        ],
      };
    }
    final kind = ['state', 'var', 'msg'].firstWhere(cond.containsKey);
    final value = cond['value'];
    origin[_join(at, 'left')] = '$path.$kind';
    origin[_join(at, 'left.$kind')] = '$path.$kind';
    origin[_join(at, 'op')] = '$path.op';
    origin[_join(at, 'right')] = '$path.value';
    origin[_join(at, 'right.literal')] = '$path.value';
    Map<String, Object?> read(String kind, Object? ref) => {
      kind: kind == 'state' ? stateRef(ref) : ref,
    };
    return {
      'type': 'compare',
      'left': read(kind, cond[kind]),
      'op': cond['op'],
      'right': _isReference(value)
          ? read((value as Map).keys.single as String, value.values.single)
          : {'literal': value},
    };
  }

  static String describe(Map<String, Object?> cond) {
    if (cond.containsKey('between')) {
      return 'between ${(cond['between'] as List).join(' and ')}';
    }
    if (cond.containsKey('days')) {
      return 'on ${(cond['days'] as List).join(', ')}';
    }
    if (cond.containsKey('not')) {
      return 'not ${describe(cond['not'] as Map<String, Object?>)}';
    }
    for (final group in ['anyOf', 'allOf']) {
      if (cond.containsKey(group)) {
        return '(${(cond[group] as List).cast<Map<String, Object?>>().map(describe).join(group == 'anyOf' ? ' or ' : ' and ')})';
      }
    }
    final kind = ['state', 'var', 'msg'].firstWhere(cond.containsKey);
    final value = cond['value'];
    final right = value is Map && _isReference(value)
        ? '${value.values.single}'
        : '$value';
    return '${cond[kind]} ${cond['op']} $right';
  }

  /// Compiles [steps] after [open], and returns the open ends after them.
  List<(String, String)> steps(
    List<Map<String, Object?>> steps,
    String path,
    List<(String, String)> open, {
    required int col,
    required int row,
  }) {
    var ends = open;
    for (var k = 0; k < steps.length; k++) {
      ends = step(steps[k], '$path[$k]', ends, col: col + k, row: row);
    }
    return ends;
  }

  List<(String, String)> step(
    Map<String, Object?> s,
    String path,
    List<(String, String)> open, {
    required int col,
    required int row,
  }) {
    final id = idOf(path);
    String node(
      String type,
      String label,
      Map<String, Object?> config,
      Map<String, String> origin,
    ) {
      add(id, type, label, config, {'': path, ...origin}, col: col, row: row);
      connect(open, id);
      return id;
    }

    if (s.containsKey('do') || s.containsKey('toggle')) {
      final toggle = s.containsKey('toggle');
      final ref = (toggle ? s['toggle'] : s['do']) as String;
      final dot = ref.indexOf('.');
      final params = s['params'] as Map?;
      final label = _words != null
          ? _words.step(s)
          : toggle
          ? 'toggle $ref'
          : params == null || params.isEmpty
          ? 'do $ref'
          : params.length == 1 && params.containsKey('value')
          ? 'set $ref to ${params['value']}'
          : 'do $ref with ${params.entries.map((e) => '${e.key}=${e.value}').join(', ')}';
      node(
        toggle ? 'device_toggle' : 'device_capability',
        label,
        {
          'deviceId': ref.substring(0, dot),
          'capabilityId': ref.substring(dot + 1),
          if (!toggle) 'params': params ?? <String, Object?>{},
        },
        {
          'deviceId': toggle ? '$path.toggle' : '$path.do',
          'capabilityId': toggle ? '$path.toggle' : '$path.do',
          'params': '$path.params',
        },
      );
      return [(id, 'out')];
    }
    if (s.containsKey('wait')) {
      node(
        'delay',
        'wait ${_duration(s['wait'] as int)}',
        {'ms': s['wait']},
        {'ms': '$path.wait'},
      );
      return [(id, 'out')];
    }
    if (s.containsKey('waitFor')) {
      final w = Map<String, Object?>.from(s['waitFor'] as Map);
      final at = '$path.waitFor';
      final (config, origin) = onConfig(w, at);
      node(
        'wait_until',
        'wait up to ${_duration(w['timeoutMs'] as int)} for ${w['on']}',
        {...config, 'timeoutMs': w['timeoutMs']},
        {...origin, '': at, 'timeoutMs': '$at.timeoutMs'},
      );
      final onTimeout = (w['onTimeout'] as List?)?.cast<Map<String, Object?>>();
      if (onTimeout != null && onTimeout.isNotEmpty) {
        steps(
          onTimeout,
          '$at.onTimeout',
          [(id, 'timeout')],
          col: col + 1,
          row: _rows++,
        );
      }
      return [(id, 'matched')];
    }
    if (s.containsKey('if')) {
      final conds = (s['if'] as List).cast<Map<String, Object?>>();
      conditions(conds, '$path.if', id, label: 'if', col: col, row: row);
      connect(open, id);
      final thenEnds = steps(
        (s['then'] as List).cast(),
        '$path.then',
        [(id, 'true')],
        col: col + 1,
        row: row,
      );
      final elseSteps = (s['else'] as List?)?.cast<Map<String, Object?>>();
      final elseEnds = elseSteps == null || elseSteps.isEmpty
          ? [(id, 'false')]
          : steps(
              elseSteps,
              '$path.else',
              [(id, 'false')],
              col: col + 1,
              row: _rows++,
            );
      return [...thenEnds, ...elseEnds];
    }
    if (s.containsKey('together')) {
      final groups = (s['together'] as List).cast<List>();
      node('parallel', 'together', {}, {});
      for (var g = 0; g < groups.length; g++) {
        steps(
          groups[g].cast(),
          '$path.together[$g]',
          [(id, 'branch')],
          col: col + 1,
          row: g == 0 ? row : _rows++,
        );
      }
      return [(id, 'done')];
    }
    if (s.containsKey('try')) {
      // Every device step inside it sends a failure to `otherwise`, which
      // then takes the place of the rest of the try.
      final first = nodes.length;
      final tried = steps(
        (s['try'] as List).cast(),
        '$path.try',
        open,
        col: col,
        row: row,
      );
      final failed = [
        for (final n in nodes.skip(first))
          if (n['type'] == 'device_capability' || n['type'] == 'device_toggle')
            ('${n['id']}', 'error'),
      ];
      final otherwise = (s['otherwise'] as List?)?.cast<Map<String, Object?>>();
      if (otherwise == null || otherwise.isEmpty) return [...tried, ...failed];
      return [
        ...tried,
        ...steps(otherwise, '$path.otherwise', failed, col: col, row: _rows++),
      ];
    }
    if (s.containsKey('repeat')) {
      final r = Map<String, Object?>.from(s['repeat'] as Map);
      final at = '$path.repeat';
      final until = (r['until'] as List?)?.cast<Map<String, Object?>>();
      final origin = <String, String>{
        'maxIterations': '$at.times',
        'everyMs': '$at.every',
      };
      final label = _words?.step(s) ?? 'repeat';
      node('repeat', label, {
        'maxIterations': r['times'] ?? RuleKeys.repeatDefault,
        if (r['every'] != null) 'everyMs': r['every'],
        if (until != null && until.isNotEmpty)
          'until': ruleOf(until, '$at.until', 'until', origin),
      }, origin);
      steps(
        (r['do'] as List).cast(),
        '$at.do',
        [(id, 'body')],
        col: col + 1,
        row: row,
      );
      return [(id, 'done')];
    }
    if (s.containsKey('keep')) {
      keep(Map<String, Object?>.from(s['keep'] as Map), path, open, col: col);
      return const [];
    }
    if (s.containsKey('notify')) {
      final n = Map<String, Object?>.from(s['notify'] as Map);
      node('notify', 'notify ${n['title']}', n, {
        for (final k in n.keys) k: '$path.notify.$k',
      });
      return [(id, 'out')];
    }
    if (s.containsKey('set')) {
      final v = s['set'] as Map;
      node(
        'set_variable',
        'set ${v['var']} to ${v['value']}',
        {'name': v['var'], 'value': v['value']},
        {'name': '$path.set.var', 'value': '$path.set.value'},
      );
      return [(id, 'out')];
    }
    node(
      'run_flow',
      'run ${s['run']}',
      {'flowId': s['run']},
      {'flowId': '$path.run'},
    );
    return [(id, 'out')];
  }

  /// A keep step: one check, entered from the rule's steps and from a
  /// trigger on every state its while reads, each time bound its while names
  /// and the target's own state. While the conditions hold it sets the
  /// target to the value whenever the target differs, and remembers it is
  /// holding in a global. When they stop holding it sends the release value
  /// once, so a target the user changed while nothing was held stays as it is.
  void keep(
    Map<String, Object?> k,
    String path,
    List<(String, String)> open, {
    required int col,
  }) {
    final id = idOf(path);
    final at = '$path.keep';
    final hold = (k['while'] as List).cast<Map<String, Object?>>();
    final ref = k['target'] as String;
    final dot = ref.indexOf('.');
    final thing = ref.substring(0, dot);
    final action = ref.substring(dot + 1);
    final targetKey = stateKeyOf(
      _refs.capabilityOf(thing, action)?.stateJsonPath,
    );
    final value = k['value'];
    final release = k.containsKey('release')
        ? k['release']
        : value is bool
        ? !value
        : null;
    final holdVar = '\$keep_${_ruleId}_$id';
    var row = _rows;
    _rows += 3;

    final triggers = <String>[];
    final seen = <String>{};
    void onState(String stateRef, String origin) {
      final (t, key) = thingKey(stateRef);
      final resolved = stateKey(t, key);
      if (!seen.add('$t.$resolved')) return;
      triggers.add(
        add(
          '${id}_on_${triggers.length}',
          'on',
          '$t.$resolved changes',
          {'thing': t, 'key': resolved, 'change': <String, Object?>{}},
          {'': origin},
          col: col,
          row: row++,
        ),
      );
    }

    void onTime(String hhmm, String origin) {
      if (!seen.add('time:$hhmm')) return;
      triggers.add(
        add(
          '${id}_on_${triggers.length}',
          'time_of_day',
          'at $hhmm',
          {'at': hhmm},
          {'': origin},
          col: col,
          row: row++,
        ),
      );
    }

    void watch(Map<String, Object?> cond, String origin) {
      if (cond['state'] case final String state) onState(state, origin);
      final value = cond['value'];
      if (value is Map && value['state'] is String) {
        onState(value['state'] as String, origin);
      }
      if (cond['between'] case [final String start, final String end]) {
        onTime(start, origin);
        onTime(end, origin);
      }
      if (cond.containsKey('days')) onTime('00:00', origin);
      if (cond['not'] case final Map<String, Object?> inner) {
        watch(inner, origin);
      }
      for (final group in ['anyOf', 'allOf']) {
        for (final inner in (cond[group] as List? ?? const [])) {
          watch(Map<String, Object?>.from(inner as Map), origin);
        }
      }
    }

    for (var j = 0; j < hold.length; j++) {
      watch(hold[j], '$at.while[$j]');
    }
    if (targetKey != null) onState('$thing.$targetKey', '$at.target');

    final check = conditions(
      hold,
      '$at.while',
      id,
      label: 'while',
      col: col + 1,
      row: _rows,
    );
    connect([...open, for (final t in triggers) (t, 'out')], check);

    String step(
      String suffix,
      String type,
      String label,
      Map<String, Object?> config,
      List<(String, String)> from,
    ) {
      final node = add(
        '${id}_$suffix',
        type,
        label,
        config,
        {'': at, 'deviceId': '$at.target', 'capabilityId': '$at.target'},
        col: col + 2,
        row: _rows,
      );
      connect(from, node);
      return node;
    }

    Map<String, Object?> send(Object? v) => {
      'deviceId': thing,
      'capabilityId': action,
      'params': {'value': v},
    };

    final holding = step(
      'hold',
      'set_variable',
      'holding $ref at $value',
      {'name': holdVar, 'value': true},
      [(check, 'true')],
    );
    var apply = [(holding, 'out')];
    if (targetKey != null) {
      final differs = step(
        'differs',
        'compare',
        'if $thing.$targetKey is not $value',
        {
          'left': {'state': '$thing.$targetKey'},
          'op': '!=',
          'right': {'literal': value},
        },
        apply,
      );
      apply = [(differs, 'true')];
    }
    step(
      'apply',
      'device_capability',
      'keep $ref at $value',
      send(value),
      apply,
    );
    final held = step(
      'held',
      'compare',
      'if $ref was held',
      {
        'left': {'var': holdVar},
        'op': '==',
        'right': {'literal': true},
      },
      [(check, 'false')],
    );
    final released = step(
      'unhold',
      'set_variable',
      'stop holding $ref',
      {'name': holdVar, 'value': false},
      [(held, 'true')],
    );
    if (release != null) {
      step(
        'release',
        'device_capability',
        'release $ref to $release',
        send(release),
        [(released, 'out')],
      );
    }
    _rows++;
  }

  static String _duration(int ms) => ms % 3600000 == 0 && ms > 0
      ? '${ms ~/ 3600000} h'
      : ms % 60000 == 0 && ms > 0
      ? '${ms ~/ 60000} min'
      : ms % 1000 == 0
      ? '${ms ~/ 1000} s'
      : '$ms ms';
}
