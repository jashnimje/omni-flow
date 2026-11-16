import 'dart:io' show Platform;

import 'api_error.dart';
import 'automation_commands.dart';
import 'automation_view.dart';
import 'command_args.dart';
import 'conflicts.dart';
import 'engine_core.dart';
import 'flow_commands.dart';
import 'houses.dart' show HouseKind;
import 'link_commands.dart';
import 'versions.dart';
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
///
/// Removing an automation keeps it, with its versions, in a recently
/// removed list for 30 days:
///
/// - `automation.remove {id}` (and `flow.remove`, `scene.remove`): the
///   reply says until when it can be put back.
/// - `automation.removed`: what can be put back, newest first.
/// - `automation.unremove {id}`: puts it back as it was, with its versions.
///   Turned on only when it was on and every thing it uses is still there.
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
    'automation.removed': removedList,
    'automation.unremove': unremove,
    'automation.remove': keepingRemoved(_flowCommands.remove),
    'flow.remove': keepingRemoved(_flowCommands.remove),
    'scene.remove': keepingRemoved(_automations.removeScene),
    'automation.enable': forgettingTurnedOff(_flowCommands.enable),
    'flow.enable': forgettingTurnedOff(_flowCommands.enable),
    'automation.skips': skips,
    'automation.conflicts': conflicts,
    'automation.list': withConflicts(_automations.list),
    'automation.versions': versions,
    'automation.restore': restore,
    'automation.save': warningLeave(keepingVersions(_automations.save)),
    'scene.save': keepingVersions(_automations.saveSceneCommand),
    'flow.save': keepingVersions(_flowCommands.save),
    'link.create': keepingVersions(_links.create),
  };

  /// [save] that keeps the stored version it replaces, when it changed.
  CommandHandler keepingVersions(CommandHandler save) =>
      (args) => keepingVersionsOf(_core.db, () => save(args));

  /// Whether this engine runs on a phone, where no hub runs the home's
  /// automations once the phone leaves. A hub's engine runs on a computer;
  /// a phone in hub mode saves to the hub, never here. Tests set it.
  static bool Function() onPhone = _isAndroid;

  static bool _isAndroid() => Platform.isAndroid;

  /// The words a save without a hub carries for a "when I leave" rule.
  static const leaveWithoutHub =
      'There is no hub, so once this phone leaves home only phone actions '
      'and web requests can run. Steps for devices at home fail until a '
      'hub runs this automation.';

  /// [save] that adds [leaveWithoutHub] to the reply's `warnings` when the
  /// rule starts on someone leaving and this engine is a phone's.
  CommandHandler warningLeave(CommandHandler save) => (args) async {
    final saved = await save(args);
    final spec = args['spec'];
    if (!onPhone() ||
        args['form'] != FlowRecord.rule ||
        spec is! Map ||
        !await _startsOnLeaving(spec['when'])) {
      return saved;
    }
    return {
      ...saved,
      'warnings': [...?(saved['warnings'] as List?), leaveWithoutHub],
    };
  };

  /// Whether a rule's [when] starts on the last person leaving, or on a
  /// person's `home` turning false.
  Future<bool> _startsOnLeaving(Object? when) async {
    if (when is! List) return false;
    final people = {
      for (final d in await DriftDeviceStore(_core.db).all())
        if (d.driverId == personDriver) d.id,
    };
    for (final t in when.whereType<Map>()) {
      if (t['people'] == 'last_leaves') return true;
      final on = t['on'];
      if (on is! String || !on.endsWith('.home')) continue;
      if (!people.contains(on.substring(0, on.length - '.home'.length))) {
        continue;
      }
      final change = t['change'];
      if (change is! Map || change['to'] != true) return true;
    }
    return false;
  }

  /// [remove] that keeps what it removes in the recently removed list,
  /// with its versions, and says so.
  CommandHandler keepingRemoved(CommandHandler remove) =>
      (args) => keepingVersionsOf(_core.db, () async {
        final id = stringArg(args, 'id');
        final record = await DriftFlowStore(_core.db).get(id);
        final house = await _core.houses.houseOf(HouseKind.flow, id);
        final versions = await _versions.of(id);
        final removed = await remove(args);
        if (record == null || removed['removed'] != true) return removed;
        final now = DateTime.now();
        await RemovedAutomationStore(_core.db)
            .add(record, versions, now, house: house);
        await _versions.removeOf(id);
        await TurnedOffByRemoval(_core.db).forgetFlow(id);
        final until = now.add(removedKeptFor);
        return {
          ...removed,
          'restorable': true,
          'keptUntil': until.toUtc().toIso8601String(),
          'message':
              'Removed. You can put it back from Recently removed for '
              '${removedKeptFor.inDays} days.',
        };
      });

  /// [enable] that forgets a device removal turned it off, since the user
  /// now chose.
  CommandHandler forgettingTurnedOff(CommandHandler enable) => (args) async {
    final result = await enable(args);
    await TurnedOffByRemoval(_core.db).forgetFlow(stringArg(args, 'id'));
    return result;
  };

  /// `automation.removed`: the automations that can be put back.
  /// `{house?}`: given a house, the ones removed from it.
  Future<Map<String, Object?>> removedList(Map<String, Object?> args) async => {
    'removed': [
      for (final r in await RemovedAutomationStore(
        _core.db,
      ).all(DateTime.now()))
        if (args['house'] == null ||
            r.house == null ||
            r.house == args['house'])
          r.toJson(),
    ],
    'keptDays': removedKeptFor.inDays,
  };

  /// `automation.unremove {id}`: puts a removed automation back.
  Future<Map<String, Object?>> unremove(Map<String, Object?> args) =>
      keepingVersionsOf(_core.db, () async {
        final id = stringArg(args, 'id');
        final store = RemovedAutomationStore(_core.db);
        final removed = await store.get(id, DateTime.now());
        if (removed == null) {
          throw ApiError(
            'not_found',
            'there is no removed automation $id to put back. Removed ones are '
                'kept for ${removedKeptFor.inDays} days',
          );
        }
        if (await DriftFlowStore(_core.db).get(id) != null) {
          throw ApiError(
            'exists',
            'an automation $id exists now. Rename or remove it first',
          );
        }
        final r = removed.record;
        await DriftFlowStore(_core.db).put(
          id,
          {...r.json, 'enabled': false},
          enabled: false,
          approved: r.approved,
          trusted: r.trusted,
          at: DateTime.now().toUtc(),
          source: r.source,
          spec: r.spec,
        );
        // Back into the house it was removed from, whatever house is shown.
        if (removed.house case final h? when _core.houses.byId(h) != null) {
          await _core.houses.put(HouseKind.flow, id, h);
        }
        await _versions.putBack(removed.versions);
        await store.forget(id);
        var enabled = false;
        String? offBecause;
        if (r.enabled) {
          try {
            await _flowCommands.enable({'id': id, 'enabled': true});
            enabled = true;
          } on ApiError catch (e) {
            offBecause = e.message;
          }
        }
        if (!enabled) await _flowCommands.enable({'id': id, 'enabled': false});
        _core.emit({
          'event': 'automation.changed',
          'command': 'automation.unremove',
          'id': id,
        });
        return {
          'id': id,
          'name': removed.name,
          'enabled': enabled,
          'versions': removed.versions.length,
          'offBecause': ?offBecause,
        };
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
        return 'it was not between ${w.clock(r['start'])} and ${w.clock(r['end'])}';
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
