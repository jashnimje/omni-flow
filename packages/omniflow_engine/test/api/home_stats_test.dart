@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/home_stats_commands.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

void main() {
  group('homeStatsOf', () {
    final now = DateTime(2026, 11, 12, 18);

    StatsRun run(
      DateTime at, {
      String flow = 'evening',
      bool byHand = false,
      int steps = 2,
      bool completed = true,
      Set<String> types = const {'device_capability'},
      Set<String> devices = const {},
    }) => StatsRun(
      flowId: flow,
      at: at,
      completed: completed,
      byHand: byHand,
      steps: steps,
      stepTypes: types,
      devices: devices,
    );

    Map<String, Object?> stats({
      List<StatsRun> runs = const [],
      List<StatsChange> changes = const [],
      List<StatsThing> things = const [],
      List<StatsFlow> flows = const [],
      HomeStatsRecord? record,
      int? totalRuns,
      int days = 7,
    }) => homeStatsOf(
      runs: runs,
      changes: changes,
      things: things,
      flows: flows,
      record: record ?? HomeStatsRecord(),
      totalRuns: totalRuns ?? runs.length,
      now: now,
      days: days,
    );

    Map<String, Object?> achievement(Map<String, Object?> s, String id) =>
        (s['achievements'] as List).cast<Map<String, Object?>>().firstWhere(
          (a) => a['id'] == id,
        );

    test('an empty home has zeros, no streak and nothing earned', () {
      final s = stats();
      expect(s['today'], {
        'date': '2026-11-12',
        'automationsRun': 0,
        'stepsDone': 0,
        'devicesChanged': 0,
        'tapsSaved': 0,
      });
      expect((s['week'] as Map)['days'], hasLength(7));
      expect(s['streak'], {'days': 0, 'best': 0});
      expect(s['busiest'], isNull);
      expect(s['newlyEarned'], isEmpty);
      expect(
        (s['achievements'] as List).every((a) => (a as Map)['earned'] == false),
        isTrue,
      );
      expect((s['achievements'] as List), hasLength(homeAchievements.length));
    });

    test('taps saved counts every automatic step and all but the tap of a '
        'run by hand', () {
      final s = stats(
        runs: [
          run(now.subtract(const Duration(hours: 1)), steps: 3),
          run(now.subtract(const Duration(hours: 2)), steps: 4, byHand: true),
          run(now.subtract(const Duration(hours: 3)), steps: 1, byHand: true),
          // A failed run is not counted as ran.
          run(now.subtract(const Duration(hours: 4)), completed: false),
          // Yesterday counts in the week only.
          run(now.subtract(const Duration(days: 1)), steps: 5),
        ],
        changes: [
          (deviceId: 'lamp', at: now),
          (deviceId: 'lamp', at: now),
          (deviceId: 'plug', at: now.subtract(const Duration(days: 2))),
        ],
      );
      final today = s['today'] as Map;
      expect(today['automationsRun'], 3);
      expect(today['stepsDone'], 8);
      expect(today['tapsSaved'], 3 + 3 + 0);
      expect(today['devicesChanged'], 1);
      final week = s['week'] as Map;
      expect(week['automationsRun'], 4);
      expect(week['tapsSaved'], 11);
      expect(week['devicesChanged'], 2);
      final days = (week['days'] as List).cast<Map>();
      expect(days.first['date'], '2026-11-06');
      expect(days.last, {'date': '2026-11-12', 'automationsRun': 3});
      expect(days[5]['automationsRun'], 1);
    });

    test('the busiest automation has the most runs in the window', () {
      final s = stats(
        runs: [
          run(now, flow: 'a'),
          run(now, flow: 'b'),
          run(now, flow: 'b'),
          run(now.subtract(const Duration(days: 10)), flow: 'a'),
          run(now.subtract(const Duration(days: 10)), flow: 'a'),
        ],
        flows: [(id: 'b', name: 'Bedtime', source: 'rule', sunset: false)],
      );
      expect(s['busiest'], {'id': 'b', 'name': 'Bedtime', 'runs': 2});
    });

    test('a removed automation is never the busiest', () {
      final s = stats(
        runs: [
          run(now, flow: 'call_test'),
          run(now, flow: 'call_test'),
          run(now, flow: 'b'),
        ],
        flows: [(id: 'b', name: 'Bedtime', source: 'rule', sunset: false)],
      );
      expect(s['busiest'], {'id': 'b', 'name': 'Bedtime', 'runs': 1});
      expect((s['week'] as Map)['automationsRun'], 3);
    });

    test(
      'a streak counts days in a row and survives a day with no run yet',
      () {
        final runs = [
          for (var d = 1; d <= 7; d++) run(now.subtract(Duration(days: d))),
        ];
        final s = stats(runs: runs);
        expect(s['streak'], {'days': 7, 'best': 7});
        expect(achievement(s, 'streak_7')['earned'], isTrue);

        final broken = stats(
          runs: [run(now), run(now.subtract(const Duration(days: 2)))],
        );
        expect(broken['streak'], {'days': 1, 'best': 1});
      },
    );

    test('achievements come from the home and the runs, with dates', () {
      final asked = now.subtract(const Duration(days: 3));
      final s = stats(
        runs: [
          run(asked, types: {'ask'}),
          run(now, types: {'http_request'}, devices: {'tv'}),
        ],
        things: [
          (id: 'lamp', kind: 'device'),
          (id: 'tv', kind: 'tv'),
          (id: 'tag1', kind: 'tag'),
          (id: 'esp', kind: 'board'),
        ],
        flows: [
          (id: 'evening', name: 'Evening', source: 'rule', sunset: true),
          (id: 'movie', name: 'Movie', source: 'scene', sunset: false),
        ],
        totalRuns: 12,
      );
      for (final id in [
        'first_device',
        'first_automation',
        'first_scene',
        'first_tag',
        'first_board',
        'runs_10',
        'asks_you',
        'web_request',
        'sunset_rule',
        'tv_controlled',
      ]) {
        expect(achievement(s, id)['earned'], isTrue, reason: id);
      }
      expect(achievement(s, 'runs_100')['earned'], isFalse);
      expect(achievement(s, 'runs_100')['how'], isNotEmpty);
      expect(
        DateTime.parse(achievement(s, 'asks_you')['earnedAt'] as String),
        asked.toUtc(),
      );
      expect(s['newlyEarned'], contains('asks_you'));
    });

    test('an earned achievement stays earned and is new only once', () {
      final record = HomeStatsRecord();
      final first = stats(
        things: [(id: 'lamp', kind: 'device')],
        record: record,
      );
      expect(first['newlyEarned'], ['first_device']);
      final again = stats(record: record);
      expect(again['newlyEarned'], isEmpty);
      expect(achievement(again, 'first_device')['earned'], isTrue);
      final restored = HomeStatsRecord.fromJson(record.toJson());
      expect(restored.earned.keys, ['first_device']);
    });

    test('a damaged record starts empty', () {
      final r = HomeStatsRecord.fromJson({
        'earned': {'x': 'not a date'},
        'runs': -3,
      });
      expect(r.earned, isEmpty);
      expect(r.runs, 0);
      expect(HomeStatsRecord.fromJson('nope').lastLogId, 0);
    });
  });

  group('home.stats', () {
    late Directory home;
    late OmniEngine engine;

    Future<OmniEngine> open() => OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_home_stats');
      engine = await open();
    });

    tearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });

    test('counts a run by hand, earns the first automation, and keeps it '
        'across a restart', () async {
      final empty = await engine.handle('home.stats', const {});
      expect(empty['ok'], isTrue, reason: '$empty');
      expect(empty['newlyEarned'], isEmpty);

      final saved = await engine.handle('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Hello',
          'when': ['manual'],
          'then': [
            {
              'notify': {'title': 'Hi'},
            },
            {
              'notify': {'title': 'Again'},
            },
          ],
        },
      });
      expect(saved['ok'], isTrue, reason: '$saved');
      final events = <Map<String, Object?>>[];
      final sub = engine.events.listen(events.add);
      final ran = await engine.handle('automation.run', {'id': saved['id']});
      expect(ran['ok'], isTrue, reason: '$ran');

      final s = await engine.handle('home.stats', {'days': 3});
      expect(s['ok'], isTrue, reason: '$s');
      final today = s['today'] as Map;
      expect(today['automationsRun'], 1);
      expect(today['stepsDone'], 2);
      expect(today['tapsSaved'], 1);
      expect((s['week'] as Map)['days'], hasLength(3));
      expect(s['totalRuns'], 1);
      expect((s['busiest'] as Map)['name'], 'Hello');
      expect(s['newlyEarned'], ['first_automation']);
      await pumpEventQueue();
      expect(
        events.where((e) => e['event'] == 'home.achievementEarned'),
        hasLength(1),
      );
      await sub.cancel();

      // Asking again counts nothing twice.
      final again = await engine.handle('home.stats', const {});
      expect(again['totalRuns'], 1);
      expect(again['newlyEarned'], isEmpty);

      await engine.close();
      expect(File('${home.path}/stats.json').existsSync(), isTrue);
      engine = await open();
      final reopened = await engine.handle('home.stats', const {});
      expect(reopened['totalRuns'], 1);
      expect(reopened['newlyEarned'], isEmpty);
    });

    test('a house counts its own runs, also of an automation removed since, '
        'and not the other house\'s', () async {
      expect(
        (await engine.handle('house.add', {'name': 'Bangalore'}))['ok'],
        isTrue,
      );
      final saved = await engine.handle('automation.save', {
        'form': 'rule',
        'trusted': true,
        'house': 'home',
        'spec': {
          'name': 'Ask test',
          'when': ['manual'],
          'then': [
            {
              'notify': {'title': 'Hi'},
            },
          ],
        },
      });
      expect(saved['ok'], isTrue, reason: '$saved');
      final ran = await engine.handle('automation.run', {'id': saved['id']});
      expect(ran['ok'], isTrue, reason: '$ran');

      Future<int> runsIn(String? house) async {
        final s = await engine.handle('home.stats', {'house': ?house});
        expect(s['ok'], isTrue, reason: '$s');
        return (s['week'] as Map)['automationsRun'] as int;
      }

      expect(await runsIn('home'), 1);
      expect(await runsIn('bangalore'), 0);

      final removed = await engine.handle('automation.remove', {
        'id': saved['id'],
      });
      expect(removed['ok'], isTrue, reason: '$removed');
      expect(await runsIn(null), 1);
      expect(await runsIn('home'), 1);
      expect(await runsIn('bangalore'), 0);
      final s = await engine.handle('home.stats', {'house': 'home'});
      expect(
        s['busiest'],
        isNull,
        reason: 'a removed automation is never the busiest',
      );
    });

    test('days out of range is invalid, and an agent may read it', () async {
      final bad = await engine.handle('home.stats', {'days': 0});
      expect((bad['error'] as Map)['type'], 'invalid');
      final agent = await engine.handle('agent.call', {
        'command': 'home.stats',
      });
      expect(agent['ok'], isTrue, reason: '$agent');
    });
  });
}
