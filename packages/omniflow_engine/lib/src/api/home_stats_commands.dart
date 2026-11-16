import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'nfc_tags.dart' show nfcTagDriverId;
import '../dag/node_types.dart';
import '../devices/board.dart' show isBoardDriver;
import '../storage/database.dart';

/// One achievement: what it is called and how a person earns it.
typedef HomeAchievement = ({String id, String title, String how});

/// Every achievement, in the order the app shows them.
const homeAchievements = <HomeAchievement>[
  (id: 'first_device', title: 'First device', how: 'Add a device'),
  (id: 'first_automation', title: 'First automation', how: 'Save one'),
  (id: 'first_scene', title: 'First scene', how: 'Save a scene'),
  (id: 'first_tag', title: 'First NFC tag', how: 'Add an NFC tag'),
  (id: 'first_board', title: 'First board', how: 'Add a board'),
  (id: 'runs_10', title: '10 runs', how: 'Let automations run 10 times'),
  (id: 'runs_100', title: '100 runs', how: 'Let automations run 100 times'),
  (id: 'runs_1000', title: '1000 runs', how: 'Let automations run 1000 times'),
  (
    id: 'streak_7',
    title: 'A week in a row',
    how: 'Have an automation run every day for 7 days',
  ),
  (
    id: 'asks_you',
    title: 'It asked you',
    how: 'Run an automation that asks you something',
  ),
  (
    id: 'web_request',
    title: 'Web request',
    how: 'Run an automation that sends a web request',
  ),
  (
    id: 'sunset_rule',
    title: 'Sunset rule',
    how: 'Save a rule that starts at sunset',
  ),
  (id: 'tv_controlled', title: 'TV controlled', how: 'Control a TV'),
];

/// What `home.stats` keeps between calls, in `stats.json` next to the
/// database: when each achievement was earned, so it stays earned after
/// the capped run log forgets the run behind it, and the lifetime run
/// count the capped log cannot hold.
class HomeStatsRecord {
  HomeStatsRecord({
    Map<String, DateTime>? earned,
    this.runs = 0,
    this.lastLogId = 0,
  }) : earned = earned ?? {};

  final Map<String, DateTime> earned;

  /// Completed runs counted so far, up to the log row [lastLogId].
  int runs;
  int lastLogId;

  static HomeStatsRecord fromJson(Object? json) {
    if (json is! Map) return HomeStatsRecord();
    final earned = <String, DateTime>{};
    if (json['earned'] case final Map map) {
      for (final e in map.entries) {
        final at = e.value is String
            ? DateTime.tryParse(e.value as String)
            : null;
        if (at != null) earned['${e.key}'] = at;
      }
    }
    final runs = json['runs'];
    final last = json['lastLogId'];
    return HomeStatsRecord(
      earned: earned,
      runs: runs is int && runs >= 0 ? runs : 0,
      lastLogId: last is int && last >= 0 ? last : 0,
    );
  }

  Map<String, Object?> toJson() => {
    'earned': {
      for (final e in earned.entries) e.key: e.value.toUtc().toIso8601String(),
    },
    'runs': runs,
    'lastLogId': lastLogId,
  };
}

/// Where [HomeStatsRecord] lives. A null file keeps it in memory only, for
/// a database with no file.
class HomeStatsStore {
  HomeStatsStore(this._file);

  final File? _file;
  HomeStatsRecord? _memory;

  Future<HomeStatsRecord> read() async {
    if (_memory case final m?) return m;
    final file = _file;
    if (file == null) return _memory = HomeStatsRecord();
    try {
      return _memory = HomeStatsRecord.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on FileSystemException {
      // Never written.
    } on FormatException {
      // A damaged file starts again from what the logs show.
    }
    return _memory = HomeStatsRecord();
  }

  Future<void> write(HomeStatsRecord record) async {
    _memory = record;
    final file = _file;
    if (file == null) return;
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(record.toJson()), flush: true);
    await temp.rename(file.path);
  }
}

/// What the busiest automation is called once it has been removed, so
/// nobody sees its id.
const removedAutomationName = 'A removed automation';

/// A run from the log, reduced to what the numbers need.
class StatsRun {
  const StatsRun({
    required this.flowId,
    required this.at,
    required this.completed,
    required this.byHand,
    required this.steps,
    this.stepTypes = const {},
    this.devices = const {},
  });

  final String flowId;
  final DateTime at;
  final bool completed;

  /// Started by a tap (a manual trigger) rather than on its own.
  final bool byHand;

  /// Action steps that ran without an error.
  final int steps;

  /// The types of those steps.
  final Set<String> stepTypes;

  /// The devices those steps acted on.
  final Set<String> devices;
}

/// A change to a device that a person or an automation made.
typedef StatsChange = ({String deviceId, DateTime at});

/// A thing in the home, reduced to what the achievements need.
typedef StatsThing = ({String id, String kind});

/// A saved automation, reduced to what the numbers need.
typedef StatsFlow = ({String id, String name, String source, bool sunset});

/// The numbers and achievements of `home.stats`, from the runs, the device
/// changes, the things and the automations, as of [now] in local time.
/// [record] is updated in place with what is newly earned and returned in
/// `newlyEarned`. [days] is how many days the series covers.
Map<String, Object?> homeStatsOf({
  required List<StatsRun> runs,
  required List<StatsChange> changes,
  required List<StatsThing> things,
  required List<StatsFlow> flows,
  required HomeStatsRecord record,
  required int totalRuns,
  required DateTime now,
  int days = 7,
}) {
  final today = _day(now);
  final first = today.subtract(Duration(days: days - 1));
  bool inWindow(DateTime at, DateTime from) => !_day(at).isBefore(from);

  Map<String, Object?> totals(DateTime from) {
    final done = [
      for (final r in runs)
        if (r.completed && inWindow(r.at, from)) r,
    ];
    final steps = done.fold<int>(0, (n, r) => n + r.steps);
    final taps = done.fold<int>(
      0,
      (n, r) => n + (r.byHand ? (r.steps - 1).clamp(0, r.steps) : r.steps),
    );
    return {
      'automationsRun': done.length,
      'stepsDone': steps,
      'devicesChanged': {
        for (final c in changes)
          if (inWindow(c.at, from)) c.deviceId,
      }.length,
      'tapsSaved': taps,
    };
  }

  final perDay = <DateTime, int>{};
  for (final r in runs) {
    if (r.completed) perDay[_day(r.at)] = (perDay[_day(r.at)] ?? 0) + 1;
  }
  final names = {for (final f in flows) f.id: f.name};
  final byFlow = <String, int>{};
  for (final r in runs) {
    if (r.completed && inWindow(r.at, first)) {
      byFlow[r.flowId] = (byFlow[r.flowId] ?? 0) + 1;
    }
  }
  final busiest =
      (byFlow.entries.toList()..sort((a, b) {
            final byRuns = b.value.compareTo(a.value);
            return byRuns != 0 ? byRuns : a.key.compareTo(b.key);
          }))
          .firstOrNull;

  final streak = _streakEnding(perDay, today);
  final best = _bestStreak(perDay);

  final evidence = _evidence(
    runs: runs,
    things: things,
    flows: flows,
    totalRuns: totalRuns,
    bestStreak: best,
    now: now,
  );
  final newly = <String>[];
  for (final a in homeAchievements) {
    final at = evidence[a.id];
    if (at == null || record.earned.containsKey(a.id)) continue;
    record.earned[a.id] = at.isAfter(now) ? now : at;
    newly.add(a.id);
  }

  return {
    'today': {'date': _dateText(today), ...totals(today)},
    'week': {
      'from': _dateText(first),
      ...totals(first),
      'days': [
        for (var i = 0; i < days; i++)
          {
            'date': _dateText(first.add(Duration(days: i))),
            'automationsRun': perDay[first.add(Duration(days: i))] ?? 0,
          },
      ],
    },
    'streak': {'days': streak, 'best': best > streak ? best : streak},
    'busiest': busiest == null
        ? null
        : {
            'id': busiest.key,
            'name': names[busiest.key] ?? removedAutomationName,
            'runs': busiest.value,
          },
    'totalRuns': totalRuns,
    'achievements': [
      for (final a in homeAchievements)
        {
          'id': a.id,
          'title': a.title,
          'how': a.how,
          'earned': record.earned.containsKey(a.id),
          'earnedAt': ?record.earned[a.id]?.toUtc().toIso8601String(),
        },
    ],
    'newlyEarned': newly,
  };
}

/// When each achievement the data proves was earned: the earliest run or
/// change behind it, or [now] when the data has no date.
Map<String, DateTime> _evidence({
  required List<StatsRun> runs,
  required List<StatsThing> things,
  required List<StatsFlow> flows,
  required int totalRuns,
  required int bestStreak,
  required DateTime now,
}) {
  DateTime? firstRun(bool Function(StatsRun r) test) {
    DateTime? at;
    for (final r in runs) {
      if (r.completed && test(r) && (at == null || r.at.isBefore(at))) {
        at = r.at;
      }
    }
    return at;
  }

  final tvs = {
    for (final t in things)
      if (t.kind == 'tv') t.id,
  };
  return {
    if (things.any((t) => t.kind != 'tag')) 'first_device': now,
    if (flows.any((f) => f.source != FlowRecord.scene)) 'first_automation': now,
    if (flows.any((f) => f.source == FlowRecord.scene)) 'first_scene': now,
    if (things.any((t) => t.kind == 'tag')) 'first_tag': now,
    if (things.any((t) => t.kind == 'board')) 'first_board': now,
    if (totalRuns >= 10) 'runs_10': now,
    if (totalRuns >= 100) 'runs_100': now,
    if (totalRuns >= 1000) 'runs_1000': now,
    if (bestStreak >= 7) 'streak_7': now,
    'asks_you': ?firstRun((r) => r.stepTypes.contains('ask')),
    'web_request': ?firstRun((r) => r.stepTypes.contains('http_request')),
    if (flows.any((f) => f.sunset)) 'sunset_rule': now,
    'tv_controlled': ?firstRun((r) => r.devices.any(tvs.contains)),
  };
}

DateTime _day(DateTime at) {
  final local = at.toLocal();
  return DateTime(local.year, local.month, local.day);
}

String _dateText(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Days in a row with a run, ending today, or yesterday when nothing has
/// run yet today, so a streak is not lost before the day is over.
int _streakEnding(Map<DateTime, int> perDay, DateTime today) {
  var day = (perDay[today] ?? 0) > 0
      ? today
      : DateTime(today.year, today.month, today.day - 1);
  var n = 0;
  while ((perDay[day] ?? 0) > 0) {
    n++;
    day = DateTime(day.year, day.month, day.day - 1);
  }
  return n;
}

int _bestStreak(Map<DateTime, int> perDay) {
  final days = perDay.keys.toList()..sort();
  var best = 0;
  var run = 0;
  DateTime? last;
  for (final d in days) {
    final next = last == null
        ? null
        : DateTime(last.year, last.month, last.day + 1);
    run = next != null && d == next ? run + 1 : 1;
    if (run > best) best = run;
    last = d;
  }
  return best;
}

/// `home.stats {days?}`: today's and this week's numbers, the streak, the
/// busiest automation and the achievements. Read level: it only reads the
/// run log, the device history, the things and the automations, and keeps
/// earned dates in `stats.json`. Each newly earned achievement is also
/// raised as a `home.achievementEarned` event.
class HomeStatsCommands {
  HomeStatsCommands(this._core, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final EngineCore _core;
  final DateTime Function() _clock;

  /// The whole home's record, and each house's, by house id.
  HomeStatsStore? _store;
  final _houseStores = <String, HomeStatsStore>{};

  /// One call at a time, so two calls never count the same runs twice.
  Future<void> _turn = Future.value();

  Map<String, CommandHandler> get commands => {'home.stats': stats};

  Future<Map<String, Object?>> stats(Map<String, Object?> args) {
    final days = optIntArg(args, 'days') ?? 7;
    if (days < 1 || days > 31) {
      throw ApiError('invalid', 'days must be 1 to 31');
    }
    final house = _core.houses.resolve(args['house']);
    final result = _turn.then((_) => _stats(days, house));
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// The stats of the whole home, or with [house] of that house alone,
  /// each with its own record of runs and achievements.
  Future<Map<String, Object?>> _stats(int days, String? house) async {
    final store = house == null
        ? _store ??= HomeStatsStore(await _statsFile())
        : _houseStores[house] ??= HomeStatsStore(
            await _statsFile(name: 'stats.$house.json'),
          );
    final record = await store.read();
    final now = _clock();
    final db = _core.db;
    final houses = _core.houses;

    final flowRecords = [
      for (final f in await DriftFlowStore(db).all())
        if (house == null ||
            (houses.flowHouses['${f.json['id']}'] ?? house) == house)
          f,
    ];
    final flowNodes = {
      for (final f in flowRecords)
        '${f.json['id']}': {
          for (final n in (f.json['nodes'] as List? ?? const []))
            if (n is Map) '${n['id']}': n,
        },
    };
    final flows = [
      for (final f in flowRecords)
        (
          id: '${f.json['id']}',
          name: '${f.json['name'] ?? f.json['id']}',
          source: f.source,
          sunset: flowNodes['${f.json['id']}']!.values.any(
            (n) =>
                n['type'] == 'sun' &&
                n['config'] is Map &&
                (n['config'] as Map)['event'] == 'sunset',
          ),
        ),
    ];

    final rows = await db
        .customSelect('SELECT id, trace_json FROM execution_log ORDER BY id')
        .get();
    final runs = <StatsRun>[];
    var newRuns = 0;
    var lastId = record.lastLogId;
    for (final row in rows) {
      final id = row.read<int>('id');
      final Object? trace;
      try {
        trace = jsonDecode(row.read<String>('trace_json'));
      } on FormatException {
        continue;
      }
      if (trace is! Map || trace['dryRun'] == true) continue;
      if (house != null && !flowNodes.containsKey(trace['flow'])) continue;
      final run = _runOf(Map<String, Object?>.from(trace), flowNodes);
      if (run == null) continue;
      runs.add(run);
      if (id > record.lastLogId && run.completed) newRuns++;
      if (id > lastId) lastId = id;
    }
    record
      ..runs += newRuns
      ..lastLogId = lastId;

    final devices = [
      for (final d in await DriftDeviceStore(db).all())
        if (house == null || houses.thingIn(d.id, house)) d,
    ];
    final things = [
      for (final d in devices) (id: d.id, kind: _kindOf(d.driverId)),
    ];
    final since = DateTime(now.year, now.month, now.day - days);
    final history = DriftHistoryStore(db);
    final changes = <StatsChange>[];
    for (final d in devices) {
      for (final e in await history.recent(
        d.id,
        limit: history.cap,
        since: since.toUtc(),
      )) {
        if (e.by != null) changes.add((deviceId: d.id, at: e.at));
      }
    }

    final reply = homeStatsOf(
      runs: runs,
      changes: changes,
      things: things,
      flows: flows,
      record: record,
      totalRuns: record.runs,
      now: now,
      days: days,
    );
    await store.write(record);
    for (final id in reply['newlyEarned'] as List<String>) {
      final a = homeAchievements.firstWhere((a) => a.id == id);
      _core.emit({
        'event': 'home.achievementEarned',
        'id': a.id,
        'title': a.title,
        'house': ?house,
      });
    }
    return reply;
  }

  String _kindOf(String driverId) {
    if (driverId == nfcTagDriverId) return 'tag';
    final manifest = _core.registry[driverId];
    if (isBoardDriver(manifest)) return 'board';
    if (manifest?.category == 'media') return 'tv';
    return 'device';
  }

  /// The database's own file decides where `stats.json` goes, so it sits
  /// with the rest of the home. Null for a database in memory.
  Future<File?> _statsFile({String name = 'stats.json'}) async {
    try {
      final row = await _core.db
          .customSelect(
            "SELECT file FROM pragma_database_list WHERE name = 'main'",
          )
          .getSingleOrNull();
      final path = row?.read<String>('file') ?? '';
      if (path.isEmpty) return null;
      return File('${File(path).parent.path}/$name');
    } catch (_) {
      return null;
    }
  }
}

/// The run [trace] records, or null when it is not one.
StatsRun? _runOf(
  Map<String, Object?> trace,
  Map<String, Map<String, Map<Object?, Object?>>> flowNodes,
) {
  final flowId = trace['flow'];
  final startedAt = trace['startedAt'];
  final at = startedAt is String ? DateTime.tryParse(startedAt) : null;
  if (flowId is! String || at == null) return null;
  final nodes = flowNodes[flowId] ?? const {};
  final traced = [
    for (final n in (trace['nodes'] as List? ?? const []))
      if (n is Map) n,
  ];
  final triggerType =
      nodes['${trace['trigger']}']?['type'] ?? traced.firstOrNull?['type'];
  var steps = 0;
  final types = <String>{};
  final devices = <String>{};
  for (final n in traced) {
    final type = n['type'];
    if (type is! String || n['error'] != null) continue;
    if (builtInNodeTypes[type]?.category != NodeCategory.action) continue;
    steps++;
    types.add(type);
    final config = nodes['${n['node']}']?['config'];
    if (config is Map && config['deviceId'] is String) {
      devices.add(config['deviceId'] as String);
    }
  }
  return StatsRun(
    flowId: flowId,
    at: at,
    completed: trace['outcome'] == 'completed',
    byHand: triggerType == 'manual',
    steps: steps,
    stepTypes: types,
    devices: devices,
  );
}
