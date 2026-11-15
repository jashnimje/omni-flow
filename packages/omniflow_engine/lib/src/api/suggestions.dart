import 'dart:convert';
import 'dart:io';

import 'api_error.dart';
import 'automation_commands.dart';
import 'automation_view.dart';
import 'command_args.dart';
import 'device_history.dart' show changedByUser;
import 'engine_core.dart';
import 'nfc_tags.dart' show nfcTagDriverId;
import 'things_runtime.dart' show personDriverId, placeDriverId;
import '../dag/canonical.dart';
import '../dag/templates.dart' show powerActionsOf;
import '../devices/board.dart' show manifestFor;
import '../devices/device_service.dart' show stateKeyOf;
import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';

/// How far back suggestions look, and the gaps that make a habit.
abstract final class HabitRules {
  static const days = 28;

  /// A change at a similar time is within this many minutes of the
  /// habit's time either way, so the whole window is 30 minutes.
  static const windowMinutes = 15;

  /// A time habit holds on at least this many days of a week...
  static const daysPerWeek = 4;

  /// ...in at least this many of the four weeks.
  static const weeks = 2;

  /// A change "right after" a trigger comes this soon after it...
  static const afterMinutes = 5;

  /// ...at least this many times...
  static const afterTimes = 5;

  /// ...and after at least this share of the trigger's changes, so a busy
  /// motion sensor does not pair with everything.
  static const afterShare = 0.5;

  /// The most suggestions listed at once.
  static const most = 10;
}

/// One change from device history, at its local time.
class HabitChange {
  const HabitChange({
    required this.thing,
    required this.key,
    required this.value,
    required this.at,
    this.manual = false,
  });

  final String thing;
  final String key;
  final Object? value;
  final DateTime at;

  /// Made by a person, by hand or in the app, not by an automation run.
  final bool manual;
}

/// A repeated manual change: at a similar time ([time]) or right after a
/// trigger ([after]).
class Habit {
  const Habit({
    required this.thing,
    required this.key,
    required this.value,
    required this.count,
    required this.confidence,
    this.time,
    this.days,
    this.after,
  });

  final String thing;
  final String key;
  final Object? value;

  /// How many times it happened.
  final int count;

  /// 0 to 1: how often it happens when it could.
  final double confidence;

  /// `HH:MM`, for a time habit.
  final String? time;

  /// Weekdays only, or null for any day.
  final List<String>? days;

  /// The change it follows: `(thing, key, value)`.
  final (String, String, Object?)? after;
}

/// The repeated manual changes in [changes] as of [now]: the same device
/// set to the same value at a similar time on at least 4 days of a week
/// for 2 weeks, or right after the same trigger at least 5 times.
List<Habit> findHabits(
  List<HabitChange> changes, {
  required DateTime now,
  bool Function(HabitChange)? canTrigger,
}) {
  final since = now.subtract(const Duration(days: HabitRules.days));
  final recent = [
    for (final c in changes)
      if (c.at.isAfter(since) && !c.at.isAfter(now)) c,
  ]..sort((a, b) => a.at.compareTo(b.at));
  final groups = <String, List<HabitChange>>{};
  for (final c in recent) {
    if (!c.manual) continue;
    groups
        .putIfAbsent(canonicalJson([c.thing, c.key, c.value]), () => [])
        .add(c);
  }
  final out = <Habit>[];
  for (final group in groups.values) {
    out.addAll(_timeHabits(group, now));
    out.addAll(_afterHabits(group, recent, canTrigger ?? _canTrigger));
  }
  out.sort((a, b) => b.confidence.compareTo(a.confidence));
  return out;
}

bool _canTrigger(HabitChange c) => c.value is bool || c.value is String;

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

int _minuteOf(DateTime t) => t.hour * 60 + t.minute;

/// Minutes between two times of day, the short way round midnight.
int _apart(int a, int b) {
  final d = (a - b).abs();
  return d > 720 ? 1440 - d : d;
}

const _weekdays = ['mon', 'tue', 'wed', 'thu', 'fri'];

List<Habit> _timeHabits(List<HabitChange> group, DateTime now) {
  final today = _day(now);
  final out = <Habit>[];
  final used = <HabitChange>{};
  // Each change in turn is a possible centre: the one that covers the most
  // days wins, and its days are not used again, so a lamp turned on at 7
  // and at 19 is two habits.
  while (true) {
    Map<DateTime, HabitChange>? best;
    for (final centre in group) {
      if (used.contains(centre)) continue;
      final m = _minuteOf(centre.at);
      final byDay = <DateTime, HabitChange>{};
      for (final c in group) {
        if (used.contains(c)) continue;
        if (_apart(_minuteOf(c.at), m) > HabitRules.windowMinutes) continue;
        final d = _day(c.at);
        final kept = byDay[d];
        if (kept == null ||
            _apart(_minuteOf(c.at), m) < _apart(_minuteOf(kept.at), m)) {
          byDay[d] = c;
        }
      }
      if (best == null || byDay.length > best.length) best = byDay;
    }
    if (best == null || best.isEmpty) break;
    used.addAll(best.values);
    final perWeek = List<int>.filled(4, 0);
    for (final d in best.keys) {
      final week = today.difference(d).inDays ~/ 7;
      if (week >= 0 && week < 4) perWeek[week]++;
    }
    final fullWeeks = perWeek.where((n) => n >= HabitRules.daysPerWeek).length;
    if (fullWeeks < HabitRules.weeks) continue;
    final weekdays = best.keys.where((d) => d.weekday <= 5).length;
    final onWeekdays = weekdays / best.length >= 0.9;
    final minutes = [for (final c in best.values) _minuteOf(c.at)]..sort();
    final median = minutes[minutes.length ~/ 2];
    final rounded = (median / 5).round() * 5 % 1440;
    final first = best.keys.reduce((a, b) => a.isBefore(b) ? a : b);
    var chances = 0;
    for (
      var d = first;
      !d.isAfter(today);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      if (!onWeekdays || d.weekday <= 5) chances++;
    }
    final c = group.first;
    out.add(
      Habit(
        thing: c.thing,
        key: c.key,
        value: c.value,
        count: best.length,
        confidence: _share(best.length, chances),
        time:
            '${(rounded ~/ 60).toString().padLeft(2, '0')}:'
            '${(rounded % 60).toString().padLeft(2, '0')}',
        days: onWeekdays ? _weekdays : null,
      ),
    );
  }
  return out;
}

List<Habit> _afterHabits(
  List<HabitChange> group,
  List<HabitChange> all,
  bool Function(HabitChange) canTrigger,
) {
  final first = group.first;
  final triggers = [
    for (final t in all)
      if (t.thing != first.thing && canTrigger(t)) t,
  ];
  final followed = <String, int>{};
  final seen = <String, (String, String, Object?)>{};
  for (final c in group) {
    final keys = <String>{};
    for (final t in triggers) {
      if (!t.at.isBefore(c.at)) break;
      if (c.at.difference(t.at).inMinutes >= HabitRules.afterMinutes) continue;
      final key = canonicalJson([t.thing, t.key, t.value]);
      seen[key] = (t.thing, t.key, t.value);
      keys.add(key);
    }
    for (final k in keys) {
      followed[k] = (followed[k] ?? 0) + 1;
    }
  }
  final out = <Habit>[];
  for (final MapEntry(:key, :value) in followed.entries) {
    if (value < HabitRules.afterTimes) continue;
    final fired = triggers
        .where((t) => canonicalJson([t.thing, t.key, t.value]) == key)
        .length;
    final share = _share(value, fired);
    if (share < HabitRules.afterShare) continue;
    out.add(
      Habit(
        thing: first.thing,
        key: first.key,
        value: first.value,
        count: value,
        confidence: share,
        after: seen[key],
      ),
    );
  }
  return out;
}

double _share(int n, int of) =>
    of == 0 ? 0 : ((n / of).clamp(0, 1) * 100).round() / 100;

/// The step that sets [key] of [thing] to [value], or null when nothing
/// the person can command fills that key.
Map<String, Object?>? habitStep(
  String thing,
  DriverManifest? manifest,
  String key,
  Object? value,
) {
  final caps = manifest?.capabilities ?? const <CapabilitySpec>[];
  final commanded = caps
      .where(
        (c) =>
            stateKeyOf(c.stateJsonPath) == key &&
            const {
              CapabilityType.toggle,
              CapabilityType.level,
              CapabilityType.colorTemp,
            }.contains(c.type),
      )
      .firstOrNull;
  if (commanded != null) {
    if (commanded.type == CapabilityType.toggle && value is! bool) return null;
    if (commanded.type != CapabilityType.toggle && value is! num) return null;
    return {
      'do': '$thing.${commanded.id}',
      'params': {'value': value},
    };
  }
  final reported = caps
      .where((c) => stateKeyOf(c.stateJsonPath) == key)
      .firstOrNull;
  final power = powerActionsOf(manifest, 'power');
  if (reported != null && power != null && (value == 'on' || value == 'off')) {
    return {'do': '$thing.${value == 'on' ? power.on : power.off}'};
  }
  return null;
}

/// Whether a person changing [key] of a thing with [manifest] by hand
/// counts: a key some command sets, as a wall switch or a remote would.
bool _commandable(DriverManifest? manifest, String key) =>
    habitStep('x', manifest, key, true) != null ||
    habitStep('x', manifest, key, 1) != null ||
    habitStep('x', manifest, key, 'on') != null;

/// `suggest.list` and `suggest.dismiss`: automations offered from the
/// person's own habits in device history. Read level for the list: it only
/// reads history, the things and the automations. A dismissal is kept in
/// `suggestions.json` next to the database.
class SuggestionCommands {
  SuggestionCommands(
    this._core,
    this._automations, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final EngineCore _core;
  final AutomationCommands _automations;
  final DateTime Function() _clock;
  _DismissedStore? _store;

  Map<String, CommandHandler> get commands => {
    'suggest.list': list,
    'suggest.dismiss': dismiss,
  };

  Future<_DismissedStore> _dismissed() async =>
      _store ??= _DismissedStore(await _file());

  Future<Map<String, Object?>> list(Map<String, Object?> _) async {
    final now = _clock();
    final db = _core.db;
    final devices = await DriftDeviceStore(db).all();
    final manifests = {
      for (final d in devices) d.id: manifestFor(_core.registry, d),
    };
    final history = DriftHistoryStore(db);
    final since = now.subtract(const Duration(days: HabitRules.days)).toUtc();
    final changes = <HabitChange>[];
    for (final d in devices) {
      if (d.driverId == nfcTagDriverId) continue;
      for (final e in await history.recent(
        d.id,
        limit: history.cap,
        since: since,
      )) {
        final byHand =
            e.by == changedByUser ||
            (e.by == null && _commandable(manifests[d.id], e.key));
        changes.add(
          HabitChange(
            thing: d.id,
            key: e.key,
            value: e.value,
            at: e.at.toLocal(),
            manual: byHand,
          ),
        );
      }
    }
    final drivers = {for (final d in devices) d.id: d.driverId};
    bool canTrigger(HabitChange c) => switch (drivers[c.thing]) {
      personDriverId => c.key == 'home',
      placeDriverId => c.key == 'inside',
      _ => c.value is bool || c.value is String,
    };
    final covered = await _covered();
    final dismissed = (await (await _dismissed()).read()).toSet();
    final words = await _automations.sentenceContext();
    final out = <Map<String, Object?>>[];
    for (final h in findHabits(changes, now: now, canTrigger: canTrigger)) {
      final step = habitStep(h.thing, manifests[h.thing], h.key, h.value);
      if (step == null) continue;
      final target = '${step['do']}';
      if (covered.contains(target)) continue;
      final id = _idOf(h);
      if (dismissed.contains(id)) continue;
      if (out.any((s) => s['id'] == id)) continue;
      out.add(_suggestion(id, h, step, words));
      if (out.length >= HabitRules.most) break;
    }
    return {'suggestions': out};
  }

  /// `{id}`: the person said Not now, so it is not offered again.
  Future<Map<String, Object?>> dismiss(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    if (!RegExp(r'^sg_[0-9a-f]{12}$').hasMatch(id)) {
      throw ApiError('invalid', 'id must be a suggestion id from suggest.list');
    }
    final store = await _dismissed();
    final ids = await store.read();
    if (!ids.contains(id)) await store.write([...ids, id]);
    return {'id': id, 'dismissed': true};
  }

  static String _idOf(Habit h) =>
      'sg_${sha256Hex(canonicalJson({
        'thing': h.thing,
        'key': h.key,
        'value': h.value,
        // The hour, so a habit whose time drifts a few minutes keeps its id.
        if (h.time != null) 'hour': h.time!.substring(0, 2),
        'days': h.days,
        if (h.after != null) 'after': [h.after!.$1, h.after!.$2, h.after!.$3],
      })).substring(0, 12)}';

  Map<String, Object?> _suggestion(
    String id,
    Habit h,
    Map<String, Object?> step,
    SentenceContext words,
  ) {
    final name = words.name(h.thing);
    final what = switch (h.value) {
      true || 'on' => 'turn on $name',
      false || 'off' => 'turn off $name',
      final v =>
        'set ${words.state('${h.thing}.${h.key}')} to ${SentenceContext.value(v)}',
    };
    final Map<String, Object?> trigger;
    final String when;
    final String title;
    if (h.after case (final thing, final key, final value)) {
      trigger = {
        'on': '$thing.$key',
        'change': {'to': value},
      };
      final phrase = words
          .trigger(trigger)
          .replaceFirst(RegExp('^When '), '')
          .replaceFirst(RegExp(r'^I '), 'you ');
      when = 'soon after $phrase';
      title =
          '${_capital(what)} when ${words.trigger(trigger).replaceFirst(RegExp('^When '), '')}';
    } else {
      trigger = {'time': h.time, 'days': ?h.days};
      when =
          'around ${h.time} ${h.days == null ? 'most days' : 'most weekdays'}';
      title = '${_capital(what)} at ${h.time}';
    }
    final spec = {
      'name': title,
      'when': [trigger],
      'then': [step],
    };
    return {
      'id': id,
      'kind': h.after == null ? 'time' : 'after',
      'words': 'You $what $when',
      'confidence': h.confidence,
      'count': h.count,
      'thing': h.thing,
      'spec': spec,
      'sentence': words.rule(spec),
    };
  }

  static String _capital(String s) => s[0].toUpperCase() + s.substring(1);

  /// The `thing.action` targets an automation already sets on its own: an
  /// enabled one that does not only run by hand.
  Future<Set<String>> _covered() async {
    final out = <String>{};
    for (final f in await DriftFlowStore(_core.db).all()) {
      if (!f.enabled || f.source == FlowRecord.scene) continue;
      if (AutomationCommands.manualOnly(f.json)) continue;
      for (final n in (f.json['nodes'] as List? ?? const [])) {
        if (n is! Map || n['config'] is! Map) continue;
        final config = n['config'] as Map;
        final device = config['deviceId'];
        final capability = config['capabilityId'];
        if (device is! String || capability is! String) continue;
        out.add('$device.$capability');
        // Waking or sleeping a TV covers both.
        if (capability == 'wake' || capability == 'sleep') {
          out
            ..add('$device.wake')
            ..add('$device.sleep');
        }
      }
    }
    return out;
  }

  /// `suggestions.json` beside the database, or null for one in memory.
  Future<File?> _file() async {
    try {
      final row = await _core.db
          .customSelect(
            "SELECT file FROM pragma_database_list WHERE name = 'main'",
          )
          .getSingleOrNull();
      final path = row?.read<String>('file') ?? '';
      if (path.isEmpty) return null;
      return File('${File(path).parent.path}/suggestions.json');
    } catch (_) {
      return null;
    }
  }
}

/// The dismissed suggestion ids, newest last, at most [cap].
class _DismissedStore {
  _DismissedStore(this._file);

  static const cap = 200;

  final File? _file;
  List<String>? _memory;

  Future<List<String>> read() async {
    if (_memory case final m?) return m;
    final file = _file;
    if (file != null) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map && json['dismissed'] is List) {
          return _memory = [
            for (final id in json['dismissed'] as List)
              if (id is String) id,
          ];
        }
      } on FileSystemException {
        // Never written.
      } on FormatException {
        // A damaged file starts again.
      }
    }
    return _memory = [];
  }

  Future<void> write(List<String> ids) async {
    final kept = ids.length > cap ? ids.sublist(ids.length - cap) : ids;
    _memory = kept;
    final file = _file;
    if (file == null) return;
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode({'dismissed': kept}), flush: true);
    await temp.rename(file.path);
  }
}
