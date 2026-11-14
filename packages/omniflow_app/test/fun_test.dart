import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/fun/breathing_mark.dart';
import 'package:omniflow_app/ui/fun/confetti.dart';
import 'package:omniflow_app/ui/fun/fun_prefs.dart';
import 'package:omniflow_app/ui/fun/home_stats.dart';
import 'package:omniflow_app/ui/fun/home_today_card.dart';
import 'package:omniflow_app/ui/fun/springy_press.dart';
import 'package:omniflow_app/ui/fun/your_home_page.dart';
import 'package:omniflow_app/ui/home/run_section.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

/// Home's fun touches: the today card, Your home, celebrations, Surprise
/// me and the springy run tiles. The engine answers follow `home.stats`.

Map<String, Object?> statsReply({
  int runsToday = 12,
  int tapsToday = 34,
  int streak = 3,
  int totalRuns = 40,
  List<String> newly = const [],
}) => {
  'ok': true,
  'today': {
    'date': '2026-11-12',
    'automationsRun': runsToday,
    'stepsDone': 40,
    'devicesChanged': 5,
    'tapsSaved': tapsToday,
  },
  'week': {
    'from': '2026-11-06',
    'automationsRun': 30,
    'stepsDone': 90,
    'devicesChanged': 8,
    'tapsSaved': 70,
    'days': [
      for (var d = 6; d <= 12; d++)
        {
          'date': '2026-11-${d.toString().padLeft(2, '0')}',
          'automationsRun': d,
        },
    ],
  },
  'streak': {'days': streak, 'best': 9},
  'busiest': {'id': 'evening', 'name': 'Evening desk', 'runs': 14},
  'totalRuns': totalRuns,
  'achievements': [
    {
      'id': 'first_automation',
      'title': 'First automation',
      'how': 'Save one',
      'earned': true,
      'earnedAt': '2026-11-10T09:00:00.000Z',
    },
    {
      'id': 'runs_100',
      'title': '100 runs',
      'how': 'Let automations run 100 times',
      'earned': false,
    },
  ],
  'newlyEarned': newly,
};

class _CardPage extends StatelessWidget {
  const _CardPage();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Padding(padding: EdgeInsets.all(14), child: HomeTodayCard()),
  );
}

void main() {
  group('words', () {
    test('the card line says what ran and the taps saved', () {
      final s = HomeStats.fromJson(statsReply());
      expect(todayLine(s), (
        title: '12 automations ran',
        detail: 'Saved you 34 taps',
      ));
      final quiet = HomeStats.fromJson(statsReply(runsToday: 0));
      expect(todayLine(quiet).title, 'Nothing has run yet today');
      expect(todayLine(quiet).detail, 'Saved you 70 taps this week');
    });

    test('a reply reads into stats, and a broken one into zeros', () {
      final s = HomeStats.fromJson(statsReply());
      expect(s.days, hasLength(7));
      expect(s.days.last.runs, 12);
      expect(s.busiest?.name, 'Evening desk');
      expect(s.earnedCount, 1);
      final empty = HomeStats.fromJson(const {'ok': true});
      expect(empty.today.automationsRun, 0);
      expect(empty.achievements, isEmpty);
    });

    test('what a celebration and the streak say', () {
      final one = HomeStats.fromJson(statsReply(newly: ['first_automation']));
      expect(
        earnedMessage(one, one.newlyEarned),
        'You earned First automation',
      );
      final two = HomeStats.fromJson(statsReply(newly: ['a', 'b']));
      expect(earnedMessage(two, two.newlyEarned), 'You earned 2 achievements');
      expect(streakLine(0, 0), startsWith('No streak yet'));
      expect(
        streakLine(3, 9),
        '3 days in a row with something running. '
        'Your best is 9 days.',
      );
    });
  });

  group('the today card', () {
    testWidgets('shows today and opens Your home', (tester) async {
      final engine = FakeEngine()..answers['home.stats'] = statsReply();
      await pumpScreen(tester, engine, const _CardPage());
      expect(find.text('12 automations ran'), findsOneWidget);
      expect(find.text('Saved you 34 taps'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('12 automations ran.*3 days in a row')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('home-today')));
      await tester.pumpAndSettle();
      expect(find.text('Your home'), findsOneWidget);
      expect(find.byKey(const ValueKey('your-home-busiest')), findsOneWidget);
      expect(find.textContaining('ran 14 times'), findsOneWidget);
      expect(find.text('Earned 10 Nov 2026'), findsOneWidget);
      expect(find.text('Let automations run 100 times'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('100 runs, not earned yet')),
        findsOneWidget,
      );
    });

    testWidgets('shows nothing when the engine has no numbers', (tester) async {
      final engine = FakeEngine()
        ..answers['home.stats'] = {
          'ok': false,
          'error': {'type': 'failed', 'message': 'no'},
        };
      await pumpScreen(tester, engine, const _CardPage());
      expect(find.byKey(const ValueKey('home-today')), findsNothing);
    });

    testWidgets('a run that finishes reads the numbers again', (tester) async {
      final engine = FakeEngine()..answers['home.stats'] = statsReply();
      await pumpScreen(tester, engine, const _CardPage());
      final before = engine.callsOf('home.stats').length;
      engine.answers['home.stats'] = statsReply(runsToday: 13);
      engine.eventsOut.add({'event': 'run.finished', 'flow': 'evening'});
      await tester.pump(HomeStatsNotifier.settle);
      await tester.pumpAndSettle();
      expect(engine.callsOf('home.stats').length, before + 1);
      expect(find.text('13 automations ran'), findsOneWidget);
    });
  });

  group('celebrations', () {
    testWidgets('a newly earned achievement bursts confetti and says so', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['home.stats'] = statsReply(newly: ['first_automation']);
      await pumpScreen(
        tester,
        engine,
        const _CardPage(),
        settle: false,
        overrides: [
          funPrefsStoreProvider.overrideWithValue(MemoryFunPrefsStore()),
        ],
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('confetti')), findsOneWidget);
      expect(find.text('You earned First automation'), findsWidgets);
      await tester.pump(ConfettiBurst.duration);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('confetti')), findsNothing);
    });

    testWidgets('celebrations off keeps only the message', (tester) async {
      final engine = FakeEngine()
        ..answers['home.stats'] = statsReply(newly: ['first_automation']);
      await pumpScreen(
        tester,
        engine,
        const _CardPage(),
        settle: false,
        overrides: [
          funPrefsStoreProvider.overrideWithValue(MemoryFunPrefsStore(false)),
        ],
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('confetti')), findsNothing);
      expect(find.text('You earned First automation'), findsWidgets);
      await tester.pumpAndSettle();
    });

    testWidgets('reduced motion keeps only the message', (tester) async {
      final engine = FakeEngine()
        ..answers['home.stats'] = statsReply(newly: ['first_automation']);
      await pumpScreen(
        tester,
        engine,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const _CardPage(),
          ),
        ),
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('confetti')), findsNothing);
      expect(find.text('You earned First automation'), findsWidgets);
      await tester.pumpAndSettle();
    });

    testWidgets('the Celebrations switch is kept on this phone', (
      tester,
    ) async {
      final prefs = MemoryFunPrefsStore();
      final engine = FakeEngine()..answers['home.stats'] = statsReply();
      await pumpScreen(
        tester,
        engine,
        const YourHomePage(),
        overrides: [funPrefsStoreProvider.overrideWithValue(prefs)],
      );
      final row = find.byKey(const ValueKey('celebrations-switch'));
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(prefs.celebrations, isFalse);
    });
  });

  testWidgets('Your home with nothing run shows the gentle empty state', (
    tester,
  ) async {
    final reply = statsReply(totalRuns: 0);
    reply['week'] = {...(reply['week'] as Map), 'automationsRun': 0};
    final engine = FakeEngine()..answers['home.stats'] = reply;
    await pumpScreen(
      tester,
      engine,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: const YourHomePage(),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('your-home-empty')), findsOneWidget);
    expect(find.byType(BreathingMark), findsOneWidget);
    expect(find.text('Nothing has run yet'), findsOneWidget);
  });

  group('run tiles', () {
    const movie = RunItem(
      id: 'movie',
      name: 'Movie night',
      icon: OmniIcons.scene,
      isScene: true,
    );
    const dinner = RunItem(
      id: 'dinner',
      name: 'Dinner',
      icon: OmniIcons.scene,
      isScene: true,
    );

    Widget section(List<RunItem> items) => Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: RunSection(items: items),
      ),
    );

    test('Surprise me needs two scenes that run on a tap', () {
      expect(surpriseScenes([movie]), isNull);
      expect(surpriseScenes([movie, dinner]), hasLength(2));
      const waiting = RunItem(
        id: 'w',
        name: 'W',
        icon: OmniIcons.scene,
        isScene: true,
        waiting: true,
      );
      expect(surpriseScenes([movie, waiting]), isNull);
    });

    testWidgets('Surprise me shows with two scenes and runs one of them', (
      tester,
    ) async {
      final engine = FakeEngine();
      await pumpScreen(tester, engine, section([movie, dinner]));
      expect(find.byKey(const ValueKey('run-surprise')), findsOneWidget);
      expect(find.text('A random scene'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run-surprise')));
      await tester.pump();
      await tester.pump();
      final ran = engine.callsOf('scene.run').single.$2['id'];
      expect(['movie', 'dinner'], contains(ran));
      expect(find.textContaining('Ran '), findsOneWidget);
      expect(find.byKey(const ValueKey('run-done-_surprise')), findsOneWidget);
      await tester.pump(RunTile.doneFor);
      await tester.pumpAndSettle();
    });

    testWidgets('Surprise me never picks the same scene twice in a row', (
      tester,
    ) async {
      final engine = FakeEngine();
      await pumpScreen(
        tester,
        engine,
        Scaffold(
          body: SurpriseTile(scenes: const [movie, dinner], random: Random(1)),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('run-surprise')));
        await tester.pump();
        await tester.pump();
        await tester.pump(RunTile.doneFor);
      }
      final ids = [for (final c in engine.callsOf('scene.run')) c.$2['id']];
      expect(ids, hasLength(4));
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i], isNot(ids[i - 1]));
      }
      await tester.pumpAndSettle();
    });

    testWidgets('one scene shows no Surprise me', (tester) async {
      await pumpScreen(tester, FakeEngine(), section([movie]));
      expect(find.byKey(const ValueKey('run-surprise')), findsNothing);
    });

    testWidgets('a tile sinks while pressed and springs back', (tester) async {
      await pumpScreen(tester, FakeEngine(), section([movie]));
      double scale() => tester
          .widget<AnimatedScale>(
            find.descendant(
              of: find.byType(SpringyPress),
              matching: find.byType(AnimatedScale),
            ),
          )
          .scale;
      expect(scale(), 1);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('scene-movie'))),
      );
      await tester.pump();
      expect(scale(), SpringyPress.pressedScale);
      await gesture.up();
      await tester.pump();
      expect(scale(), 1);
      await tester.pumpAndSettle();
    });
  });
}
