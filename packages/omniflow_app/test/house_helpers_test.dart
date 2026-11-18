import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/house_calls.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/rule_words.dart';
import 'package:omniflow_app/ui/automations/timer_forms.dart';
import 'package:omniflow_app/ui/home/timer_strip.dart';
import 'package:omniflow_app/ui/settings/alerts_page.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

const _modes = {
  'ok': true,
  'mode': 'night',
  'name': 'Night',
  'modes': [
    {'id': 'home', 'name': 'Home', 'builtIn': true},
    {'id': 'away', 'name': 'Away', 'builtIn': true},
    {'id': 'night', 'name': 'Night', 'builtIn': true},
    {'id': 'vacation', 'name': 'Vacation', 'builtIn': true},
    {'id': 'guests', 'name': 'Guests', 'builtIn': false},
  ],
  'followPresence': false,
};

void main() {
  group('a room tile summary', () {
    RoomLights room(int lights, int on, {int offline = 0, int? level}) =>
        RoomLights(
          id: 'hall',
          name: 'Hall',
          lights: lights,
          lightsOn: on,
          offline: offline,
          brightness: level,
        );

    test('counts only the lights that answer', () {
      expect(
        room(2, 1, offline: 1, level: 80).summary,
        'All on, 80%, 1 not answering',
      );
      expect(room(3, 1, offline: 1).summary, '1 of 2 on, 1 not answering');
      expect(room(1, 0, offline: 1).summary, 'Not answering');
      expect(room(2, 0, offline: 2).summary, 'None answering');
      expect(room(2, 0).summary, 'All off');
    });
  });

  group('home', () {
    late FakeEngine engine;

    setUp(() {
      engine = FakeEngine();
      engine.answers['home.mode'] = _modes;
    });

    testWidgets('the mode chip shows the mode once, and the picker sets '
        'another', (tester) async {
      await pumpApp(tester, engine);
      expect(find.text('Mode: Night'), findsOneWidget);
      expect(find.textContaining('Night mode'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mode-chip')));
      await tester.pumpAndSettle();
      expect(find.text('Guests'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mode-away')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('home.mode.set').single.$2, {'mode': 'away'});
    });

    testWidgets('an engine with no modes shows no chip', (tester) async {
      engine.answers.remove('home.mode');
      await pumpApp(tester, engine);
      expect(find.byKey(const ValueKey('mode-chip')), findsNothing);
    });

    testWidgets('a room with lights is one tile: the icon turns them all off', (
      tester,
    ) async {
      engine.answers['room.list'] = {
        'ok': true,
        'rooms': [
          {'id': 'living', 'name': 'Living room', 'order': 0},
        ],
      };
      engine.answers['room.state'] = {
        'ok': true,
        'room': {'id': 'living', 'name': 'Living room'},
        'lights': 2,
        'lightsOn': 2,
        'anyOn': true,
        'brightness': 60,
      };
      engine.answers['room.invoke'] = {'ok': true, 'results': [], 'sent': 2};
      await pumpApp(tester, engine);
      expect(find.byKey(const ValueKey('room-tile-living')), findsOneWidget);
      expect(find.text('All on, 60%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room-power-living')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('room.invoke').single.$2, {
        'room': 'living',
        'capability': 'power',
        'params': {'value': false},
        'only': 'lights',
      });
    });
  });

  group('timers', () {
    testWidgets('a running timer counts down from its end time, and Cancel '
        'cancels it', (tester) async {
      final engine = FakeEngine();
      final now = DateTime.utc(2026, 11, 12, 18);
      engine.answers['timer.list'] = {
        'ok': true,
        'timers': [
          {
            'id': 'pasta',
            'name': 'Pasta',
            'durationMs': 1200000,
            'state': 'running',
            'endsAt': now
                .add(const Duration(minutes: 12, seconds: 5))
                .toIso8601String(),
          },
          {
            'id': 'tea',
            'name': 'Tea',
            'durationMs': 300000,
            'state': 'paused',
            'remainingMs': 90000,
          },
        ],
      };
      await pumpPage(
        tester,
        engine,
        Scaffold(body: TimerStrip(now: () => now)),
      );
      expect(find.text('12:05'), findsOneWidget);
      expect(find.text('1:30'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('timer-cancel-pasta')));
      await tester.pump();
      expect(engine.callsOf('timer.cancel').single.$2, {'name': 'Pasta'});
      await tester.tap(find.byKey(const ValueKey('timer-pause-tea')));
      await tester.pump();
      expect(engine.callsOf('timer.resume').single.$2, {'name': 'Tea'});
      engine.eventsOut.add({'event': 'timer.changed', 'timers': []});
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('timer-strip')), findsNothing);
    });

    test('countdown words', () {
      expect(countdownText(const Duration(minutes: 5)), '5:00');
      expect(countdownText(const Duration(hours: 1, seconds: 7)), '1:00:07');
    });
  });

  group('editor words', () {
    final words = RuleWords(const []);

    test('the mode and timer triggers, the mode check and the steps read in '
        'plain words', () {
      expect(
        words.trigger(
          OnTrigger(
            thing: 'house_mode',
            key: 'changed',
            mode: OnMode.event,
            match: {'mode': 'night'},
          ),
        ),
        'The mode changes to Night',
      );
      expect(
        words.trigger(
          OnTrigger(
            thing: 'timers',
            key: 'ended',
            mode: OnMode.event,
            match: {'timer': 'pasta'},
          ),
        ),
        'Timer Pasta ends',
      );
      expect(
        words.condition(
          CompareCondition('state', 'house_mode.mode', '==', 'away'),
        ),
        'The mode is Away',
      );
      expect(
        words.step(
          DoStep('timers', 'start', params: {'name': 'Pasta', 'ms': 1200000}),
        ),
        'Start a 20 min timer called Pasta',
      );
      expect(
        words.step(DoStep('timers', 'cancel', params: {'name': 'Pasta'})),
        'Cancel timer Pasta',
      );
      expect(
        words.step(DoStep('house_mode', 'set', params: {'mode': 'night'})),
        'Set the mode to Night',
      );
    });

    testWidgets('the timer step form builds a start step with its minutes', (
      tester,
    ) async {
      final engine = FakeEngine();
      DoStep? built;
      await pumpPage(
        tester,
        engine,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-form'),
              onPressed: () async => built = await timerStepForm(context),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-form')));
      await tester.pumpAndSettle();
      expect(buttonEnabled(tester, 'form-done'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('timer-step-name')),
        'Pasta',
      );
      await tester.enterText(
        find.byKey(const ValueKey('timer-step-minutes')),
        '20',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await tester.pumpAndSettle();
      expect(built?.toJson(), {
        'do': 'timers.start',
        'params': {'name': 'Pasta', 'ms': 1200000},
      });
    });

    testWidgets('the mode trigger form picks the mode it changes to', (
      tester,
    ) async {
      final engine = FakeEngine()..answers['home.mode'] = _modes;
      OnTrigger? built;
      await pumpPage(
        tester,
        engine,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-form'),
              onPressed: () async => built = await modeTriggerForm(context),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-form')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('house-mode-guests')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await tester.pumpAndSettle();
      expect(built?.toJson(), {
        'on': 'house_mode.changed',
        'event': true,
        'match': {'mode': 'guests'},
      });
    });
  });

  group('settings and scenes', () {
    testWidgets('alerts switch off, and a mode is added', (tester) async {
      final engine = FakeEngine()
        ..answers['home.mode'] = _modes
        ..answers['alerts.get'] = {
          'ok': true,
          'offline': true,
          'battery': true,
        };
      await pumpPushed(tester, engine, const AlertsPage());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('alert-offline')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.callsOf('alerts.set').single.$2, {'offline': false});
      await tapKey(tester, 'mode-add');
      await tester.enterText(
        find.byKey(const ValueKey('prompt-field')),
        'Movie night',
      );
      await tester.pump();
      await tapKey(tester, 'prompt-save');
      expect(engine.callsOf('home.mode.set').last.$2, {
        'modes': ['Guests', 'Movie night'],
      });
    });

    testWidgets('Save how things are now picks devices and saves a scene', (
      tester,
    ) async {
      final engine = automationsEngine();
      engine.answers['scene.capture'] = {'ok': true, 'id': 'evening'};
      await pumpPushed(tester, engine, const ScenesPage());
      await tapKey(tester, 'scene-capture');
      expect(buttonEnabled(tester, 'capture-save'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('capture-name')),
        'Evening',
      );
      await tapKey(tester, 'capture-desk_lamp');
      await tapKey(tester, 'capture-save');
      expect(engine.callsOf('scene.capture').single.$2, {
        'name': 'Evening',
        'devices': ['desk_lamp'],
        'trusted': true,
      });
    });
  });
}
