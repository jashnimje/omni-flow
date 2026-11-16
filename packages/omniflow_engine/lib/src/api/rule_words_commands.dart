import 'automation_commands.dart';
import 'automation_view.dart';
import 'command_args.dart';
import 'house_things.dart' show houseStepWords;
import '../dag/rules.dart' show andWords, daysWords;

/// `rule.words {rule}`: the words of every part of an unsaved rule, from the
/// same [SentenceContext] the automation cards and the diagram use, so the
/// app's sentence editor cannot word a part differently.
///
/// Returns `{parts, sentence, missing}`. Each of `parts` is `{path, kind,
/// part, text, words}`: `kind` is `trigger`, `condition` or `step`, `part`
/// is the part as it was sent (the app finds its row by it), `text` its
/// words as one line, and `words` the pieces a tap edits on their own,
/// each `{text, blank?, token?}`. `missing` says what still keeps the rule
/// from being saved, or is null when it can be saved.
class RuleWordsCommands {
  RuleWordsCommands(this._automations);

  final AutomationCommands _automations;

  Map<String, CommandHandler> get commands => {'rule.words': words};

  Future<Map<String, Object?>> words(Map<String, Object?> args) async {
    final rule = objectArg(args, 'rule');
    final context = await _automations.sentenceContext();
    final parts = RuleWordParts(context).of(rule);
    List<Map<String, Object?>> sentence;
    try {
      sentence = context.rule(rule);
    } catch (_) {
      sentence = const [];
    }
    return {'parts': parts, 'sentence': sentence, 'missing': ruleMissing(rule)};
  }
}

/// What still keeps [rule] from being saved, in words, or null when it can
/// be: a trigger and a step, and every group filled. A rule of keep steps
/// alone needs no trigger, since each keep watches its own conditions.
String? ruleMissing(Map<String, Object?> rule) {
  final when = rule['when'] is List ? rule['when'] as List : const [];
  final then = rule['then'] is List ? rule['then'] as List : const [];
  final onlyKeeps =
      then.isNotEmpty && then.every((s) => s is Map && s.containsKey('keep'));
  if (when.isEmpty && !onlyKeeps) {
    return then.isEmpty
        ? 'Add a trigger and a step to save.'
        : 'Add a trigger to save.';
  }
  if (then.isEmpty) return 'Add a step to save.';
  if (!stepsFilled(then)) {
    return 'A group needs filling in: each If needs a check and a step, '
        'each branch a step and each keep a while.';
  }
  return null;
}

/// Whether [steps] has a step, and each group in it is filled: an If has a
/// check and a step, a branch a step, a repeat a count or an until, a keep
/// a while.
bool stepsFilled(Object? steps) {
  if (steps is! List || steps.isEmpty) return false;
  bool optional(Object? list) =>
      list is! List || list.isEmpty || stepsFilled(list);
  bool nonEmpty(Object? list) => list is List && list.isNotEmpty;
  for (final s in steps) {
    if (s is! Map) continue;
    final ok = switch (s) {
      {'if': final conditions} =>
        nonEmpty(conditions) && stepsFilled(s['then']) && optional(s['else']),
      {'together': final List branches} => branches.every(stepsFilled),
      {'try': final body} => stepsFilled(body) && optional(s['otherwise']),
      {'repeat': final Map r} =>
        stepsFilled(r['do']) && (r['times'] != null || nonEmpty(r['until'])),
      {'forEach': final Map f} => stepsFilled(f['do']),
      {'waitFor': final Map w} => optional(w['onTimeout']),
      {'keep': final Map k} => nonEmpty(k['while']),
      _ => true,
    };
    if (!ok) return false;
  }
  return true;
}

/// Keep steps go last in a rule's steps, in their own order, so a move, an
/// add or an undo never leaves a plain step after one. [isKeep] says which
/// items are keeps, so the app's typed steps and JSON both use it.
void keepStepsLast<T>(List<T> steps, bool Function(T step) isKeep) {
  final keeps = steps.where(isKeep).toList();
  if (keeps.isEmpty) return;
  steps
    ..removeWhere(isKeep)
    ..addAll(keeps);
}

/// What a person types as a value, read the same by the app, the CLI and an
/// agent: on and yes are true, off and no are false, true, false and null
/// are themselves, numbers are numbers, and the rest is the text.
Object? typedValue(String text) {
  final t = text.trim();
  return switch (t.toLowerCase()) {
    'on' || 'yes' || 'true' => true,
    'off' || 'no' || 'false' => false,
    'null' => null,
    _ => num.tryParse(t) ?? t,
  };
}

/// The words of each part of a rule, with the pieces a tap edits.
class RuleWordParts {
  RuleWordParts(this.words);

  final SentenceContext words;

  List<Map<String, Object?>> of(Map<String, Object?> rule) {
    final out = <Map<String, Object?>>[];
    _list(out, rule['when'], 'when', 'trigger');
    _list(out, rule['onlyIf'], 'onlyIf', 'condition');
    _steps(out, rule['then'], 'then');
    return out;
  }

  void _list(
    List<Map<String, Object?>> out,
    Object? list,
    String path,
    String kind,
  ) {
    if (list is! List) return;
    for (var i = 0; i < list.length; i++) {
      final part = list[i];
      if (part is! Map) continue;
      final map = Map<String, Object?>.from(part);
      final pieces = _guard(
        () => kind == 'trigger' ? trigger(map) : condition(map),
      );
      if (pieces != null) out.add(_entry('$path[$i]', kind, map, pieces));
    }
  }

  void _steps(List<Map<String, Object?>> out, Object? list, String path) {
    if (list is! List) return;
    for (var i = 0; i < list.length; i++) {
      final part = list[i];
      if (part is! Map) continue;
      final map = Map<String, Object?>.from(part);
      final at = '$path[$i]';
      final pieces = _guard(() => step(map));
      if (pieces != null) out.add(_entry(at, 'step', map, pieces));
      _inside(out, map, at);
    }
  }

  /// The parts inside a group step.
  void _inside(
    List<Map<String, Object?>> out,
    Map<String, Object?> s,
    String at,
  ) {
    if (s['if'] is List) {
      _list(out, s['if'], '$at.if', 'condition');
      _steps(out, s['then'], '$at.then');
      _steps(out, s['else'], '$at.else');
    }
    if (s['together'] case final List groups) {
      for (var g = 0; g < groups.length; g++) {
        _steps(out, groups[g], '$at.together[$g]');
      }
    }
    if (s['try'] is List) {
      _steps(out, s['try'], '$at.try');
      _steps(out, s['otherwise'], '$at.otherwise');
    }
    if (s['repeat'] case final Map r) {
      _steps(out, r['do'], '$at.repeat.do');
      _list(out, r['until'], '$at.repeat.until', 'condition');
    }
    if (s['forEach'] case final Map f) _steps(out, f['do'], '$at.forEach.do');
    if (s['waitFor'] case final Map w) {
      final until = Map<String, Object?>.from(w)
        ..remove('timeoutMs')
        ..remove('onTimeout');
      final pieces = _guard(() => trigger(until));
      if (pieces != null) {
        out.add(_entry('$at.waitFor', 'trigger', until, pieces));
      }
      _steps(out, w['onTimeout'], '$at.waitFor.onTimeout');
    }
    if (s['keep'] case final Map k) {
      _list(out, k['while'], '$at.keep.while', 'condition');
    }
  }

  static List<Map<String, Object?>>? _guard(
    List<Map<String, Object?>> Function() words,
  ) {
    try {
      return words();
    } catch (_) {
      // A part still being filled in has no words yet.
      return null;
    }
  }

  static Map<String, Object?> _entry(
    String path,
    String kind,
    Map<String, Object?> part,
    List<Map<String, Object?>> pieces,
  ) => {
    'path': path,
    'kind': kind,
    'part': part,
    'text': pieces.map((p) => p['text']).join(),
    'words': pieces,
  };

  static Map<String, Object?> _piece(
    String text, [
    String? blank,
    String? token,
  ]) => {'text': text, 'blank': ?blank, 'token': ?token};

  static String _capital(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  /// A trigger as a row reads it, under the When heading: "Desk lamp turns
  /// on", "At 07:00 on weekdays".
  List<Map<String, Object?>> trigger(Map<String, Object?> t) {
    if (t['time'] is String && t['days'] is! Map) {
      final days = t['days'];
      return [
        _piece('At '),
        _piece('${t['time']}', 'time'),
        if (days is List && days.isNotEmpty) ...[
          _piece(' '),
          _piece(daysWords(days), 'days'),
        ],
      ];
    }
    final text = words.trigger(t);
    return [_piece(_capital(text.replaceFirst(RegExp(r'^When '), '')))];
  }

  /// A condition as a row reads it, under the Only if heading.
  List<Map<String, Object?>> condition(Map<String, Object?> c) {
    if (c['between'] case [final start, final end]) {
      return [
        _piece('Between '),
        _piece('$start', 'start'),
        _piece(' and '),
        _piece('$end', 'end'),
      ];
    }
    return [_piece(_capital(words.condition(c)))];
  }

  /// A step as a row reads it, with the device, the value, the time or the
  /// text a tap edits on its own.
  List<Map<String, Object?>> step(Map<String, Object?> s) {
    if (houseStepWords(s) case final words?) {
      return [_piece(_capital(words), 'form')];
    }
    if (s['do'] case final String ref) {
      final dot = ref.indexOf('.');
      final thing = dot < 0 ? ref : ref.substring(0, dot);
      final all = words.action(ref, s['params'] as Map?);
      final who = words.name(thing);
      if (thing.startsWith('{{') || !all.startsWith('$who ')) {
        return [_piece(_capital(all))];
      }
      return [
        _piece(who, 'device'),
        _piece(' '),
        _piece(all.substring(who.length + 1), 'value'),
      ];
    }
    if (s['toggle'] case final String ref) {
      final dot = ref.indexOf('.');
      final thing = dot < 0 ? ref : ref.substring(0, dot);
      final who = words.name(thing);
      final all = words.step(s);
      final rest = all.replaceFirst('toggle $who', '');
      return [_piece('Toggle '), _piece(who, 'device'), _piece(rest)];
    }
    if (s.containsKey('wait')) {
      return [
        _piece('Wait '),
        _piece(SentenceContext.duration(s['wait']), 'duration'),
      ];
    }
    if (s['notify'] case final Map n) {
      final to = n['to'] is String ? '${words.name(n['to'] as String)} ' : '';
      return [
        _piece('Notify $to"'),
        ..._template('${n['title']}', 'title'),
        _piece('"'),
      ];
    }
    if (s['run'] case final String id) {
      return [
        _piece('Run '),
        _piece(words.automations[id] ?? id, 'automation'),
      ];
    }
    if (s['set'] case final Map set) {
      final value = set['value'];
      return [
        _piece(
          'Set ${'${set['var']}'.replaceFirst(RegExp(r'^[$%]'), '')} to ',
          'form',
        ),
        if (value is String)
          ..._template(value, 'value')
        else
          _piece(SentenceContext.value(value), 'value'),
      ];
    }
    if (s['keep'] case final Map k) {
      final holds = [
        for (final c in k['while'] as List? ?? const [])
          if (c is Map) words.condition(Map<String, Object?>.from(c)),
      ];
      final target = words.action('${k['target']}', {'value': k['value']});
      return [
        _piece(
          'Keep $target${holds.isEmpty ? '…' : ' while ${andWords(holds)}'}',
        ),
      ];
    }
    final said = words.step(s);
    // A step the engine has no words for is left to the app.
    if (said == '$s') throw StateError('no words for $s');
    final text = _capital(said);
    const forms = {'ask', 'get', 'text', 'math', 'date', 'forEach', 'http'};
    return [_piece(text, s.keys.any(forms.contains) ? 'form' : null)];
  }

  static final _token = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');

  /// [text] as plain pieces and its `{{...}}` values in words, each marked
  /// as the [blank] it edits.
  List<Map<String, Object?>> _template(String text, String blank) {
    final out = <Map<String, Object?>>[];
    var at = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > at) out.add(_piece(text.substring(at, m.start), blank));
      final inside = m.group(1)!;
      out.add(_piece(SentenceContext.spoken('{{$inside}}'), blank, inside));
      at = m.end;
    }
    if (at < text.length || out.isEmpty) {
      out.add(_piece(text.substring(at), blank));
    }
    return out;
  }
}
