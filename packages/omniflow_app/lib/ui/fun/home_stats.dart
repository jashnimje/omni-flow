import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show HomeStatsCalls;
import '../../api/engine_client.dart';
import '../../state/providers.dart';
import '../home/home_data.dart' show summariesProvider, scenesProvider;

/// The numbers of one period: today, or the whole week.
class StatsTotals {
  const StatsTotals({
    this.automationsRun = 0,
    this.stepsDone = 0,
    this.devicesChanged = 0,
    this.tapsSaved = 0,
  });

  factory StatsTotals.fromJson(Object? json) {
    final j = json is Map ? json : const {};
    int n(String key) => j[key] is int ? j[key] as int : 0;
    return StatsTotals(
      automationsRun: n('automationsRun'),
      stepsDone: n('stepsDone'),
      devicesChanged: n('devicesChanged'),
      tapsSaved: n('tapsSaved'),
    );
  }

  final int automationsRun;
  final int stepsDone;
  final int devicesChanged;
  final int tapsSaved;
}

/// One achievement as the engine reports it.
class Achievement {
  const Achievement({
    required this.id,
    required this.title,
    required this.how,
    required this.earned,
    this.earnedAt,
  });

  factory Achievement.fromJson(Json j) => Achievement(
    id: '${j['id']}',
    title: '${j['title'] ?? j['id']}',
    how: '${j['how'] ?? ''}',
    earned: j['earned'] == true,
    earnedAt: j['earnedAt'] is String
        ? DateTime.tryParse(j['earnedAt'] as String)?.toLocal()
        : null,
  );

  final String id;
  final String title;
  final String how;
  final bool earned;
  final DateTime? earnedAt;
}

/// A `home.stats` reply.
class HomeStats {
  const HomeStats({
    this.today = const StatsTotals(),
    this.week = const StatsTotals(),
    this.days = const [],
    this.streak = 0,
    this.bestStreak = 0,
    this.busiest,
    this.totalRuns = 0,
    this.achievements = const [],
    this.newlyEarned = const [],
  });

  factory HomeStats.fromJson(Json j) {
    final week = j['week'] is Map ? j['week'] as Map : const {};
    final streak = j['streak'] is Map ? j['streak'] as Map : const {};
    final busiest = j['busiest'];
    return HomeStats(
      today: StatsTotals.fromJson(j['today']),
      week: StatsTotals.fromJson(week),
      days: [
        for (final d in (week['days'] as List? ?? const []))
          if (d is Map)
            (
              date: DateTime.tryParse('${d['date']}') ?? DateTime(2000),
              runs: d['automationsRun'] is int ? d['automationsRun'] as int : 0,
            ),
      ],
      streak: streak['days'] is int ? streak['days'] as int : 0,
      bestStreak: streak['best'] is int ? streak['best'] as int : 0,
      busiest: busiest is Map
          ? (
              id: '${busiest['id']}',
              name: '${busiest['name'] ?? busiest['id']}',
              runs: busiest['runs'] is int ? busiest['runs'] as int : 0,
            )
          : null,
      totalRuns: j['totalRuns'] is int ? j['totalRuns'] as int : 0,
      achievements: [
        for (final a in (j['achievements'] as List? ?? const []))
          if (a is Map) Achievement.fromJson(Map<String, Object?>.from(a)),
      ],
      newlyEarned: [
        for (final id in (j['newlyEarned'] as List? ?? const [])) '$id',
      ],
    );
  }

  final StatsTotals today;
  final StatsTotals week;

  /// Runs per day, oldest first, ending today.
  final List<({DateTime date, int runs})> days;
  final int streak;
  final int bestStreak;
  final ({String id, String name, int runs})? busiest;
  final int totalRuns;
  final List<Achievement> achievements;

  /// Achievements earned since the last `home.stats`, to celebrate.
  final List<String> newlyEarned;

  int get earnedCount => achievements.where((a) => a.earned).length;

  Achievement? achievement(String id) =>
      achievements.where((a) => a.id == id).firstOrNull;
}

/// Asks the engine for the numbers. Null when it did not answer, or
/// answered without them (an engine from before `home.stats`).
Future<HomeStats?> loadHomeStats(EngineClient client, {int days = 7}) async {
  try {
    final r = await client.call(HomeStatsCalls.homeStats, {'days': days});
    return r['ok'] == true && r['today'] is Map ? HomeStats.fromJson(r) : null;
  } on Object {
    return null;
  }
}

/// The numbers, read again when an automation finishes a run or the
/// automations or scenes change, a moment later so a burst of runs reads
/// once.
class HomeStatsNotifier extends AsyncNotifier<HomeStats?> {
  Timer? _again;

  /// How long a run waits before the numbers are read again.
  static const settle = Duration(seconds: 2);

  @override
  Future<HomeStats?> build() async {
    final client = ref.watch(engineClientProvider);
    ref.watch(summariesProvider.select((s) => s.value?.length));
    ref.watch(scenesProvider.select((s) => s.value?.length));
    final sub = client.events.listen((e) {
      if (e['event'] == HomeStatsCalls.runFinishedEvent) {
        _again?.cancel();
        _again = Timer(settle, refresh);
      }
    });
    ref.onDispose(() {
      _again?.cancel();
      sub.cancel();
    });
    return loadHomeStats(client);
  }

  Future<void> refresh() async {
    final fresh = await loadHomeStats(ref.read(engineClientProvider));
    if (fresh != null) state = AsyncData(fresh);
  }
}

final homeStatsProvider = AsyncNotifierProvider<HomeStatsNotifier, HomeStats?>(
  HomeStatsNotifier.new,
);
