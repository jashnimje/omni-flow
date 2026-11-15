import 'api_error.dart';
import 'automation_commands.dart';
import 'automation_view.dart';
import 'command_args.dart';
import 'conflicts.dart';
import 'engine_core.dart';
import 'flow_commands.dart';
import 'link_commands.dart';
import 'versions.dart';
import '../dag/canonical.dart';
import '../dag/people_triggers.dart' show personDriver;
import '../dag/skips.dart';
import '../storage/database.dart';

/// Why an automation did not run, which automations fight over a device,
/// and the earlier versions of each automation:
///
/// - `automation.skips {id}`: the triggers that fired without a run, newest
///   first, each with its words ("Front door turns on, but it was not
///   between 18:00 and 23:00").
/// - `automation.conflicts {id?}`: pairs of enabled automations that set a
///   device capability to different values on overlapping triggers.
/// - `automation.versions {id}`: the last 10 saved versions.
/// - `automation.restore {id, version, trusted?}`: saves that version
///   again. The user's own tools pass `trusted`, and a version an agent
///   wrote stays untrusted.
///
/// Every save through `automation.save`, `scene.save`, `flow.save` and
/// `link.create` keeps the version it replaces, so these commands take over
/// those names in the command table and pass each save on as it was.
/// `automation.list` passes through the same way, and adds to each row the
/// `conflicts` it is in, as their reasons.
class RulesCoreCommands {
  RulesCoreCommands(
    this._core,
    this._automations,
    this._flowCommands,
    this._links,
  );

  final EngineCore _core;
  final AutomationCommands _automations;
  final FlowCommands _flowCommands;
  final LinkCommands _links;

  AutomationVersionStore get _versions => AutomationVersionStore(_core.db);

  Map<String, CommandHandler> get commands => {
    'automation.skips': skips,
    'automation.conflicts': conflicts,
    'automation.list': withConflicts(_automations.list),
    'automation.versions': versions,
    'automation.restore': restore,
    'automation.save': keepingVersions(_automations.save),
    'scene.save': keepingVersions(_automations.saveSceneCommand),
    'flow.save': keepingVersions(_flowCommands.save),
    'link.create': keepingVersions(_links.create),
  };

  /// [save] that keeps the stored version it replaces, when it changed.
  CommandHandler keepingVersions(CommandHandler save) => (args) async {
    final store = DriftFlowStore(_core.db);
    final before = {for (final r in await store.all()) '${r.json['id']}': r};
    final saved = await save(args);
    final id = saved['id'];
    final old = id is String ? before[id] : null;
    if (old != null) {
      final now = await store.get(id as String);
      if (now == null || _content(now) != _content(old)) {
        await _versions.add(old, DateTime.now());
      }
    }
    return saved;
  };

  /// What a version is, without its on or off.
  static String _content(FlowRecord r) => canonicalJson({
    'flow': {...r.json}..remove('enabled'),
    'spec': r.spec,
    'source': r.source,
  });

  Future<Map<String, Object?>> versions(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final words = await _automations.sentenceContext();
    return {
      'versions': [
        for (final v in await _versions.of(id))
          {
            ...v.toJson(),
            'sentence': words.sentence(
              FlowRecord(
                v.flow,
                enabled: true,
                approved: true,
                source: v.form,
                spec: v.spec,
              ),
            ),
          },
      ],
    };
  }

  Future<Map<String, Object?>> restore(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final version = optIntArg(args, 'version');
    if (version == null) throw ApiError('invalid', 'version is required');
    final v = await _versions.get(id, version);
    if (v == null) {
      throw ApiError('not_found', '$id has no saved version $version');
    }
    final current = await DriftFlowStore(_core.db).get(id);
    final save = v.saveArgs();
    if (v.form == FlowRecord.graph) {
      save['spec'] = {
        ...v.flow,
        'enabled': current?.enabled ?? v.flow['enabled'] ?? true,
      };
    }
    // Trusted only when the user restores a version the user made: an
    // agent's version waits for approval again where it is high risk.
    save['trusted'] = args['trusted'] == true && v.byUser;
    final saved = await keepingVersions(_automations.save)(save);
    return {...saved, 'restored': version};
  }

  Future<Map<String, Object?>> skips(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final record = await DriftFlowStore(_core.db).get(id);
    final words = await _automations.sentenceContext();
    return {
      'skips': [
        for (final e in _core.flows.skips.of(id))
          {
            ...e.toJson(),
            'reason': skipReason(e, words, record),
            'text':
                '${_capital(e.triggerLabel ?? e.trigger)}, but '
                '${skipReason(e, words, record)}',
          },
      ],
    };
  }

  Future<Map<String, Object?>> conflicts(Map<String, Object?> args) async {
    final id = optStringArg(args, 'id');
    final records = await DriftFlowStore(_core.db).all();
    final flows = {
      for (final r in records)
        if (r.enabled || r.json['id'] == id) '${r.json['id']}': r.json,
    };
    final names = {
      for (final r in records) '${r.json['id']}': '${r.json['name']}',
    };
    final words = await _automations.sentenceContext();
    return {
      'conflicts': [
        for (final c in findConflicts(flows))
          if (id == null || c.a == id || c.b == id)
            {
              'automations': [c.a, c.b],
              'names': [names[c.a], names[c.b]],
              'thing': c.thing,
              'capability': c.capability,
              'reason': _conflictWords(c, names, words),
            },
      ],
    };
  }

  /// `automation.list` with each row's `conflicts`: the reason of every
  /// clash it is in, so a list shows its warnings without another call.
  CommandHandler withConflicts(CommandHandler list) => (args) async {
    final listed = await list(args);
    final found = (await conflicts(const {}))['conflicts'] as List;
    final reasons = <String, List<String>>{};
    for (final c in found.cast<Map<String, Object?>>()) {
      for (final id in (c['automations'] as List)) {
        reasons.putIfAbsent('$id', () => []).add('${c['reason']}');
      }
    }
    return {
      ...listed,
      'automations': [
        for (final a in (listed['automations'] as List? ?? const []))
          if (a is Map && reasons[a['id']] != null)
            {...a, 'conflicts': reasons[a['id']]}
          else
            a,
      ],
    };
  };

  static String _conflictWords(
    AutomationConflict c,
    Map<String, String> names,
    SentenceContext w,
  ) {
    final ref = '${c.thing}.${c.capability}';
    final label = c.triggerLabel;
    final when = RegExp(r'^(at |every |\d|sunrise|sunset)').hasMatch(label)
        ? label
        : 'when $label';
    return '${names[c.a]} sets ${w.action(ref, c.paramsA)} and '
        '${names[c.b]} sets ${w.action(ref, c.paramsB)}, both $when';
  }

  /// Why [e] did not run, in plain words, after "but".
  static String skipReason(
    SkipEntry e,
    SentenceContext w,
    FlowRecord? record,
  ) => switch (e.kind) {
    SkipKind.condition => _stopWords(e.stop, w),
    SkipKind.off => 'it was turned off',
    SkipKind.waitingApproval => 'it was waiting for your approval',
    SkipKind.cooldown =>
      'it had run in the last '
          '${SentenceContext.seconds(record?.json['cooldownSeconds'])} '
          '(its cooldown)',
    SkipKind.running => 'it was still running from before',
    SkipKind.busy => 'too many of its runs were going',
    SkipKind.queueFull => 'too many of its runs were waiting',
    SkipKind.asking => 'it was already asking you',
    SkipKind.declined => 'you chose not to run it',
    SkipKind.unanswered => 'nobody answered when it asked',
    _ => 'it was changed before it could run',
  };

  static String _stopWords(Map<String, Object?>? stop, SentenceContext w) {
    final rule = stop?['rule'];
    if (rule is! Map) return 'a condition said no';
    final r = Map<String, Object?>.from(rule);
    switch (r['type']) {
      case 'time_window':
        return 'it was not between ${r['start']} and ${r['end']}';
      case 'days':
        return 'it was not ${(r['days'] as List).join(', ')}';
      case 'people':
        return r['is'] == 'all_away' ? 'someone was home' : 'nobody was home';
      case 'compare':
        return _compareWords(r, stop!['actual'], w);
    }
    return 'a condition said no';
  }

  static const _notOp = {
    '>': 'above',
    '<': 'below',
    '>=': 'at least',
    '<=': 'at most',
  };

  static String _compareWords(
    Map<String, Object?> rule,
    Object? actual,
    SentenceContext w,
  ) {
    String side(Object? s) {
      if (s is! Map || s.length != 1) return '$s';
      final ref = '${s.values.single}';
      return switch (s.keys.single) {
        'literal' => SentenceContext.value(s.values.single),
        'state' => w.state(ref),
        'var' => ref.replaceFirst(RegExp(r'^[$%]'), ''),
        _ => 'the message $ref',
      };
    }

    final left = rule['left'];
    if (left is Map && left['state'] is String) {
      final ref = left['state'] as String;
      final dot = ref.indexOf('.');
      final thing = dot < 0 ? ref : ref.substring(0, dot);
      if (ref.substring(dot + 1) == 'home' &&
          actual is bool &&
          w.drivers[thing]?.id == personDriver) {
        final who = thing == w.person ? 'I was' : '${w.name(thing)} was';
        return '$who ${actual ? 'home' : 'away'}';
      }
    }
    final what = side(left);
    if (actual == null) return '$what was not known';
    final now = SentenceContext.value(actual);
    final op = rule['op'];
    if (op == '!=') return '$what was $now';
    final not = _notOp[op];
    return not == null
        ? '$what was $now, not ${side(rule['right'])}'
        : '$what was $now, not $not ${side(rule['right'])}';
  }

  static String _capital(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
