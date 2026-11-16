import 'dart:math' as math;

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'houses.dart' show firstHouseId;
import 'error_of.dart';
import 'smart_lights.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../storage/database.dart';

/// Who the engine names as the sender of an away-lighting change, so its
/// own replays are never replayed again.
const awaylightBy = 'awaylight';

/// The furthest a replayed change moves from last week's time, in minutes.
const awayJitterMinutes = 20;

/// How many days of on and off changes away lighting keeps for itself,
/// beside the device history.
const _keepDays = 8;

/// A light turning on or off.
typedef LightChange = ({DateTime at, bool on});

/// One change away lighting makes.
typedef AwayAction = ({String light, DateTime at, bool on});

/// `YYYY-MM-DD` for [day].
String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

int _seed(String text) {
  var h = 0x811c9dc5;
  for (final c in text.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// What away lighting does on [date]: each light's changes from the same
/// weekday a week before ([lastWeek], local times on that day), at the same
/// time of day plus or minus up to [awayJitterMinutes] minutes. The offsets
/// come from the date and the light, so a preview shows what will run, and
/// a light's changes keep their order.
List<AwayAction> awayPlan(
  DateTime date,
  Map<String, List<LightChange>> lastWeek,
) {
  final actions = <AwayAction>[];
  for (final e in lastWeek.entries) {
    final changes = [...e.value]..sort((a, b) => a.at.compareTo(b.at));
    DateTime? previous;
    for (var i = 0; i < changes.length; i++) {
      final c = changes[i].at.toLocal();
      final random = math.Random(_seed('${dayKey(date)}|${e.key}|$i'));
      final offset =
          random.nextInt(2 * awayJitterMinutes + 1) - awayJitterMinutes;
      var at = DateTime(
        date.year,
        date.month,
        date.day,
        c.hour,
        c.minute,
        c.second,
      ).add(Duration(minutes: offset));
      if (previous != null && !at.isAfter(previous)) {
        at = previous.add(const Duration(minutes: 1));
      }
      previous = at;
      actions.add((light: e.key, at: at, on: changes[i].on));
    }
  }
  return actions..sort((a, b) => a.at.compareTo(b.at));
}

/// The actions of [plan] due after [from] and up to [to].
List<AwayAction> dueActions(
  List<AwayAction> plan,
  DateTime from,
  DateTime to,
) => [
  for (final a in plan)
    if (a.at.isAfter(from) && !a.at.isAfter(to)) a,
];

/// Away lighting: `awaylight.set`, `awaylight.get` and `awaylight.preview`.
/// While everyone is away, or the house is in Vacation mode, the picked
/// lights replay last week's same weekday, and it stops the moment someone
/// gets home.
class AwayLighting {
  AwayLighting(
    this._core,
    this._store,
    this._call, {
    this.house = firstHouseId,
  });

  final EngineCore _core;

  /// The house whose lights these are and whose people count.
  final String house;
  final JsonFileStore _store;

  /// Runs another engine command, to read the house mode where it exists.
  final Future<Map<String, Object?>> Function(String, Map<String, Object?>)
  _call;

  var enabled = false;
  final lights = <String>[];
  final _log = <String, List<LightChange>>{};
  var _dirty = false;

  /// When the replay started, or null while someone is home.
  DateTime? _cursor;

  Map<String, CommandHandler> get commands => {
    'awaylight.set': set,
    'awaylight.get': get,
    'awaylight.preview': preview,
  };

  Future<void> load() async {
    final json = await _store.read();
    enabled = json['enabled'] == true;
    lights
      ..clear()
      ..addAll([
        for (final l in (json['lights'] as List? ?? const []))
          if (l is String) l,
      ]);
    final log = json['log'];
    if (log is Map) {
      for (final e in log.entries) {
        _log['${e.key}'] = [
          for (final c in (e.value as List? ?? const []))
            if (c is List &&
                c.length == 2 &&
                c[0] is String &&
                c[1] is bool &&
                DateTime.tryParse(c[0] as String) != null)
              (at: DateTime.parse(c[0] as String), on: c[1] as bool),
        ];
      }
    }
  }

  Future<void> _save() async {
    _dirty = false;
    await _store.write({
      'enabled': enabled,
      'lights': lights,
      'log': {
        for (final e in _log.entries)
          e.key: [
            for (final c in e.value) [c.at.toUtc().toIso8601String(), c.on],
          ],
      },
    });
  }

  LightParts? _partsOf(Device d) => lightPartsOf(_core.registry[d.driverId]);

  /// A removed light leaves the picked lights and its log.
  Future<void> forgetLight(String id) async {
    final picked = lights.remove(id);
    final logged = _log.remove(id) != null;
    if (picked || logged) await _save();
  }

  /// `{lights: [id], enabled}`.
  Future<Map<String, Object?>> set(Map<String, Object?> args) async {
    final picked = args['lights'];
    final on = args['enabled'];
    if (picked != null &&
        (picked is! List || picked.any((l) => l is! String))) {
      throw ApiError('invalid', 'lights must be a list of light ids');
    }
    if (on != null && on is! bool) {
      throw ApiError('invalid', 'enabled must be true or false');
    }
    if (picked is List) {
      final devices = {
        for (final d in await DriftDeviceStore(_core.db).all()) d.id: d,
      };
      for (final id in picked.cast<String>()) {
        final d = devices[id];
        if (d == null) throw ApiError('not_found', 'no light $id');
        if (_partsOf(d) == null) {
          throw ApiError('invalid', '${d.name} is not a light');
        }
      }
      lights
        ..clear()
        ..addAll({...picked.cast<String>()});
      _log.removeWhere((k, _) => !lights.contains(k));
    }
    if (on is bool) enabled = on;
    if (!enabled) _cursor = null;
    await _save();
    return get(const {});
  }

  Future<Map<String, Object?>> get(Map<String, Object?> _) async {
    final why = await _awayReason();
    return {
      'enabled': enabled,
      'lights': lights,
      'away': why != null,
      'reason': ?why,
      'running': _cursor != null,
    };
  }

  /// `{date?}` (`YYYY-MM-DD`, today by default): what away lighting would
  /// do that day.
  Future<Map<String, Object?>> preview(Map<String, Object?> args) async {
    final raw = optStringArg(args, 'date');
    final now = DateTime.now();
    var date = DateTime(now.year, now.month, now.day);
    if (raw != null) {
      final parsed = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)
          ? DateTime.tryParse(raw)
          : null;
      if (parsed == null) throw ApiError('invalid', 'date must be YYYY-MM-DD');
      date = parsed;
    }
    final names = {
      for (final d in await DriftDeviceStore(_core.db).all()) d.id: d.name,
    };
    final plan = awayPlan(date, await lastWeek(date));
    return {
      'date': dayKey(date),
      'from': dayKey(date.subtract(const Duration(days: 7))),
      'actions': [
        for (final a in plan)
          {
            'light': a.light,
            'name': names[a.light] ?? a.light,
            'at': a.at.toIso8601String(),
            'on': a.on,
          },
      ],
    };
  }

  /// Each picked light's on and off changes on [date]'s weekday a week
  /// before, from the device history and away lighting's own log, without
  /// the changes away lighting made itself.
  Future<Map<String, List<LightChange>>> lastWeek(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day - 7);
    final end = DateTime(date.year, date.month, date.day - 6);
    final devices = {
      for (final d in await DriftDeviceStore(_core.db).all()) d.id: d,
    };
    final out = <String, List<LightChange>>{};
    final history = DriftHistoryStore(_core.db);
    for (final id in lights) {
      final d = devices[id];
      final key = d == null ? null : _partsOf(d)?.powerKey;
      if (key == null) continue;
      final changes = <LightChange>[
        for (final h in await history.recent(
          id,
          key: key,
          limit: history.cap,
          since: start.subtract(const Duration(seconds: 1)),
        ))
          if (h.by != awaylightBy && h.value is bool && h.at.isBefore(end))
            (at: h.at.toLocal(), on: h.value as bool),
      ];
      for (final c in _log[id] ?? const <LightChange>[]) {
        final at = c.at.toLocal();
        if (at.isBefore(start) || !at.isBefore(end)) continue;
        if (changes.any(
          (h) => h.on == c.on && h.at.difference(at).inSeconds.abs() <= 2,
        )) {
          continue;
        }
        changes.add((at: at, on: c.on));
      }
      if (changes.isNotEmpty) out[id] = changes;
    }
    return out;
  }

  /// Why the home counts as empty, or null when someone is home or nobody
  /// is tracked: `vacation` for the house mode, else `everyone_away`.
  Future<String?> _awayReason() async {
    final mode = await _call('home.mode', const {});
    if (mode['ok'] == true) {
      final m = mode['mode'];
      final name = m is Map ? (m['id'] ?? m['name']) : m;
      if ('$name'.toLowerCase() == 'vacation') return 'vacation';
    }
    final people = [
      for (final d in await DriftDeviceStore(_core.db).all())
        if (d.driverId == 'person') d,
    ];
    if (people.isEmpty) return null;
    // Nobody is at this house: not home there, and at none of its places.
    return people.any((p) => _core.houses.personIn(p, house))
        ? null
        : 'everyone_away';
  }

  /// Runs from the engine's minute tick while the hub runs.
  Future<void> tick(DateTime now) async {
    if (_dirty) await _save();
    if (!enabled || lights.isEmpty) {
      _cursor = null;
      return;
    }
    if (await _awayReason() == null) {
      _cursor = null;
      return;
    }
    final from = _cursor;
    _cursor = now;
    if (from == null) return;
    final today = DateTime(now.year, now.month, now.day);
    final plan = [
      if (from.day != now.day)
        ...awayPlan(
          DateTime(from.year, from.month, from.day),
          await lastWeek(from),
        ),
      ...awayPlan(today, await lastWeek(today)),
    ];
    for (final a in dueActions(plan, from, now)) {
      if (_cursor == null) return;
      try {
        await _core.devices.invoke(
          a.light,
          'power',
          {'value': a.on},
          allowPairing: false,
          by: awaylightBy,
        );
      } catch (e) {
        _core.emit({
          'event': 'awaylight.failed',
          'device': a.light,
          ...errorFields(e),
        });
      }
    }
  }

  /// Records the picked lights' own changes, and stops the replay the
  /// moment a person gets home.
  void observe(DeviceStateChanged e, Map<String, Object?>? before) {
    final d = e.device;
    if (d.driverId == 'person' && d.state['home'] == true) {
      _cursor = null;
      return;
    }
    if (!lights.contains(d.id) || e.by == awaylightBy) return;
    final key = _partsOf(d)?.powerKey;
    if (key == null) return;
    final on = d.state[key];
    if (on is! bool || before == null || before[key] == on) return;
    final now = DateTime.now();
    final keepFrom = now.subtract(const Duration(days: _keepDays));
    (_log[d.id] ??= []).add((at: now.toUtc(), on: on));
    _log[d.id]!.removeWhere((c) => c.at.isBefore(keepFrom));
    _dirty = true;
  }

  Future<void> flush() async {
    if (_dirty) await _save();
  }
}
