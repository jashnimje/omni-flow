@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/rule_parse.dart';
import 'package:omniflow_engine/src/api/suggestions.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'automation_harness.dart';

/// Thursday evening.
final now = DateTime(2026, 11, 12, 20);

DateTime daysAgo(int days, int hour, int minute) =>
    DateTime(now.year, now.month, now.day - days, hour, minute);

HabitChange change(
  DateTime at, {
  String thing = 'lamp',
  String key = 'state',
  Object? value = true,
  bool manual = true,
}) => HabitChange(thing: thing, key: key, value: value, at: at, manual: manual);

/// The lamp turned on by hand on each weekday of the last [weeks] weeks,
/// at 19:00 plus a few minutes.
List<HabitChange> weekdayEvenings({int weeks = 3, bool manual = true}) => [
  for (var d = 1; d <= weeks * 7; d++)
    if (daysAgo(d, 0, 0).weekday <= 5)
      change(daysAgo(d, 19, d % 9), manual: manual),
];

void main() {
  group('findHabits', () {
    test('the same change around the same time most weekdays', () {
      final habits = findHabits(weekdayEvenings(), now: now);
      final h = habits.single;
      expect(h.time, '19:05');
      expect(h.days, ['mon', 'tue', 'wed', 'thu', 'fri']);
      expect(h.count, 15);
      expect(h.confidence, greaterThan(0.9));
      expect(h.after, isNull);
    });

    test('every day reads as any day', () {
      final habits = findHabits([
        for (var d = 1; d <= 14; d++) change(daysAgo(d, 7, 0)),
      ], now: now);
      expect(habits.single.days, isNull);
      expect(habits.single.time, '07:00');
    });

    test('three days a week is not a habit', () {
      final changes = [
        for (var d = 1; d <= 21; d++)
          if (const {1, 3, 5}.contains(daysAgo(d, 0, 0).weekday))
            change(daysAgo(d, 19, 0)),
      ];
      expect(findHabits(changes, now: now), isEmpty);
    });

    test('one full week is not two', () {
      expect(findHabits(weekdayEvenings(weeks: 1), now: now), isEmpty);
    });

    test('changes an automation made do not count', () {
      expect(findHabits(weekdayEvenings(manual: false), now: now), isEmpty);
    });

    test('times more than 15 minutes apart are not the same time', () {
      final changes = [
        for (var d = 1; d <= 21; d++)
          if (daysAgo(d, 0, 0).weekday <= 5)
            change(daysAgo(d, d.isEven ? 18 : 19, d.isEven ? 30 : 30)),
      ];
      expect(findHabits(changes, now: now), isEmpty);
    });

    test('a morning and an evening habit are two', () {
      final changes = [
        ...weekdayEvenings(),
        for (var d = 1; d <= 21; d++)
          if (daysAgo(d, 0, 0).weekday <= 5) change(daysAgo(d, 7, 30)),
      ];
      final times = {for (final h in findHabits(changes, now: now)) h.time};
      expect(times, {'07:30', '19:05'});
    });

    test('older than 28 days is forgotten', () {
      final old = [for (var d = 29; d <= 50; d++) change(daysAgo(d, 19, 0))];
      expect(findHabits(old, now: now), isEmpty);
    });

    List<HabitChange> arrivals(int times, {int followed = 0, int gap = 2}) => [
      for (var d = 1; d <= times; d++) ...[
        change(
          daysAgo(d, 18, d * 3),
          thing: 'jade',
          key: 'home',
          manual: false,
        ),
        if (d <= followed)
          change(daysAgo(d, 18, d * 3 + gap), thing: 'hall', key: 'state'),
      ],
    ];

    test('right after the same trigger five times', () {
      final habits = findHabits(arrivals(6, followed: 6), now: now);
      final after = habits.where((h) => h.after != null).single;
      expect(after.thing, 'hall');
      expect(after.after, ('jade', 'home', true));
      expect(after.count, 6);
      expect(after.confidence, 1.0);
    });

    test('four times is not enough', () {
      final habits = findHabits(arrivals(4, followed: 4), now: now);
      expect(habits.where((h) => h.after != null), isEmpty);
    });

    test(
      'a trigger that fires far more often than it is followed is not one',
      () {
        final habits = findHabits(arrivals(20, followed: 5), now: now);
        expect(habits.where((h) => h.after != null), isEmpty);
      },
    );

    test('a change ten minutes later is not right after', () {
      final habits = findHabits(arrivals(6, followed: 6, gap: 10), now: now);
      expect(habits.where((h) => h.after != null), isEmpty);
    });
  });

  group('habitStep', () {
    final registry = DriverRegistry.withBuiltIns();

    test('a toggle state key becomes its capability', () {
      expect(habitStep('lamp', registry['philips_wiz_udp'], 'state', true), {
        'do': 'lamp.power',
        'params': {'value': true},
      });
      expect(habitStep('lamp', registry['philips_wiz_udp'], 'dimming', 40), {
        'do': 'lamp.brightness',
        'params': {'value': 40},
      });
    });

    test('a TV power sensor becomes wake and sleep', () {
      expect(habitStep('tv', registry['android_tv_adb'], 'power', 'on'), {
        'do': 'tv.wake',
      });
      expect(
        habitStep('tv', registry['android_tv_adb'], 'power', 'asleep'),
        isNull,
      );
    });

    test('a key nothing can set is not a step', () {
      expect(habitStep('jade', registry['person'], 'home', true), isNull);
    });
  });

  group('suggest.list and suggest.dismiss', () {
    late Directory home;
    late AutomationHarness h;
    late SuggestionCommands suggestions;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_suggest');
      h = await AutomationHarness.open(home);
      suggestions = SuggestionCommands(h.core, h.automations, clock: () => now);
    });

    tearDown(() async {
      await h.shutdown();
      await home.delete(recursive: true);
    });

    Future<void> record(
      List<HabitChange> changes, {
      String? by = 'user',
    }) async {
      for (final c in changes) {
        await DriftHistoryStore(h.db).add(c.thing, [
          HistoryEntry(
            c.at.toUtc(),
            c.key,
            c.value,
            by: c.manual ? by : 'evening',
          ),
        ]);
      }
    }

    Future<List<Map<String, Object?>>> listed() async =>
        ((await suggestions.list(const {}))['suggestions'] as List)
            .cast<Map<String, Object?>>();

    test('offers a rule in plain words that saves as it is', () async {
      await record(weekdayEvenings());
      final s = (await listed()).single;
      expect(s['words'], 'You turn on Lamp around 19:05 most weekdays');
      expect(s['kind'], 'time');
      expect(s['id'], matches(RegExp(r'^sg_[0-9a-f]{12}$')));
      expect(s['spec'], {
        'name': 'Turn on Lamp at 19:05',
        'when': [
          {
            'time': '19:05',
            'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
          },
        ],
        'then': [
          {
            'do': 'lamp.power',
            'params': {'value': true},
          },
        ],
      });
      expect(s['sentence'], isNotEmpty);

      // Saved, the habit is covered, so it is offered no more.
      final saved = await h.handle('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': s['spec'],
      });
      expect(saved['ok'], isTrue, reason: '$saved');
      expect(await listed(), isEmpty);
    });

    test('a wall switch reports with no author and still counts', () async {
      await record(weekdayEvenings(), by: null);
      expect(await listed(), hasLength(1));
    });

    test('what an automation did is not offered', () async {
      await record(weekdayEvenings(manual: false));
      expect(await listed(), isEmpty);
    });

    test('right after I get home', () async {
      for (var d = 1; d <= 6; d++) {
        await DriftHistoryStore(
          h.db,
        ).add('jade', [HistoryEntry(daysAgo(d, 18, d).toUtc(), 'home', true)]);
        await DriftHistoryStore(h.db).add('lamp', [
          HistoryEntry(
            daysAgo(d, 18, d + 1).toUtc(),
            'state',
            true,
            by: 'user',
          ),
        ]);
      }
      final s = (await listed()).where((s) => s['kind'] == 'after').single;
      expect(s['words'], 'You turn on Lamp soon after you get home');
      expect((s['spec'] as Map)['when'], [
        {
          'on': 'jade.home',
          'change': {'to': true},
        },
      ]);
    });

    test('a dismissed suggestion stays dismissed, across a restart', () async {
      await record(weekdayEvenings());
      final id = (await listed()).single['id'] as String;
      expect(await suggestions.dismiss({'id': id}), {
        'id': id,
        'dismissed': true,
      });
      expect(await listed(), isEmpty);
      final again = SuggestionCommands(h.core, h.automations, clock: () => now);
      expect((await again.list(const {}))['suggestions'], isEmpty);
    });

    test('dismiss refuses an id that is not a suggestion id', () async {
      expect(
        () => suggestions.dismiss({'id': '../agent'}),
        throwsA(isA<ApiError>().having((e) => e.type, 'type', 'invalid')),
      );
    });
  });

  group('rule.parse over the stored home', () {
    late Directory home;
    late AutomationHarness h;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_parse');
      h = await AutomationHarness.open(home);
    });

    tearDown(() async {
      await h.shutdown();
      await home.delete(recursive: true);
    });

    test('reads the home names and returns the sentence chips', () async {
      final r = await RuleParseCommands(
        h.core,
        h.automations,
      ).parse({'text': 'turn off the lamp when I leave'});
      expect(r['problem'], isNull);
      expect(r['spec'], {
        'name': 'Turn off the lamp when I leave',
        'when': [
          {
            'on': 'jade.home',
            'change': {'to': false},
          },
        ],
        'then': [
          {
            'do': 'lamp.power',
            'params': {'value': false},
          },
        ],
      });
      final chips = (r['sentence'] as List).cast<Map>();
      expect(chips.first, {'kind': 'when', 'text': 'When I leave'});
      expect(r['unknown'], isEmpty);
    });

    test('a refusal says why and lists the words', () async {
      final r = await RuleParseCommands(
        h.core,
        h.automations,
      ).parse({'text': 'when I leave turn off the sauna'});
      expect(r['spec'], isNull);
      expect(r['problem'], contains('sauna'));
      expect(r['unknown'], ['sauna']);
      expect(r['sentence'], isEmpty);
    });

    test(
      'a parser whose spec does not validate gets a problem, not a spec',
      () async {
        final r = await RuleParseCommands(
          h.core,
          h.automations,
          parser: const _BadParser(),
        ).parse({'text': 'anything'});
        expect(r['spec'], isNull);
        expect(r['problem'], startsWith('That does not make a rule yet'));
      },
    );

    test('text must be a string', () async {
      expect(
        () => RuleParseCommands(h.core, h.automations).parse({'text': 3}),
        throwsA(isA<ApiError>()),
      );
    });
  });

  group('in the engine', () {
    late Directory home;
    late OmniEngine engine;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_make_easy');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
    });

    tearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });

    test('the commands are in the table and never throw', () async {
      expect(
        engine.commandNames,
        containsAll(['rule.parse', 'suggest.list', 'suggest.dismiss']),
      );
      final parsed = await engine.handle('rule.parse', {'text': 'hello'});
      expect(parsed['ok'], isTrue);
      expect(parsed['spec'], isNull);
      expect(parsed['problem'], isNotNull);
      final listed = await engine.handle('suggest.list', const {});
      expect(listed, {'ok': true, 'suggestions': <Object?>[]});
      final bad = await engine.handle('suggest.dismiss', {'id': 'x'});
      expect(bad['ok'], isFalse);
    });

    test('agents may read and parse, and dismiss once set up', () {
      expect(agentRefusal('rule.parse', const {}, AgentAccess.read), isNull);
      expect(agentRefusal('suggest.list', const {}, AgentAccess.read), isNull);
      expect(
        agentRefusal('suggest.dismiss', const {}, AgentAccess.read),
        isNotNull,
      );
      expect(
        agentRefusal('suggest.dismiss', const {}, AgentAccess.setup),
        isNull,
      );
    });
  });
}

class _BadParser implements RuleParser {
  const _BadParser();

  @override
  Future<RuleParse> parse(String text, ParseHome home) async => const RuleParse(
    spec: {
      'name': 'Bad',
      'when': [
        {'time': '7 oclock'},
      ],
      'then': [
        {'do': 'lamp.power'},
      ],
    },
  );
}
