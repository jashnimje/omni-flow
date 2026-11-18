import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/rules/things.dart';
import 'package:omniflow_app/state/clock.dart' show hour12Provider;
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/rule_words.dart';
import 'package:omniflow_app/ui/theme.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

/// The fixes from the new-user usability review of design v2, items 1, 6,
/// 8 to 13, 17, 18 and 21 (~/scratch/design_v2/usability/report.md).

/// [page] in the app's theme with a 12-hour clock, as the review's phone
/// read the time.
Future<void> _pump(WidgetTester tester, FakeEngine engine, Widget page) async {
  tester.view.physicalSize = const Size(1236, 5400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        engineConnectionProvider.overrideWithValue(engine),
        hour12Provider.overrideWithValue(true),
      ],
      child: MaterialApp(
        theme: omniTheme(),
        scaffoldMessengerKey: messengerKey,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [page] pushed over a plain home, so it can pop.
Future<void> _pushed(WidgetTester tester, FakeEngine engine, Widget page) =>
    _pump(
      tester,
      engine,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open-page'),
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => page)),
            child: const Text('Open'),
          ),
        ),
      ),
    ).then((_) => tapKey(tester, 'open-page'));

const _lampAtSeven = <String, Object?>{
  'name': '',
  'when': [
    {
      'time': '19:00',
      'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
    },
  ],
  'then': [
    {
      'do': 'desk_lamp.power',
      'params': {'value': true},
    },
  ],
};

Map<String, Object?> _stored(Map<String, Object?> spec) => {
  'ok': true,
  'id': 'arrive_home',
  'name': spec['name'],
  'source': 'rule',
  'spec': spec,
  'approved': true,
  'revision': 'r1',
  'flow': {'nodes': []},
};

const _movieScene = {
  'id': 'movie',
  'name': 'Movie',
  'icon': 'movie',
  'actions': [
    {
      'do': 'desk_lamp.brightness',
      'params': {'value': 20},
    },
    {
      'do': 'hall_bulb.power',
      'params': {'value': false},
    },
  ],
  'enabled': true,
  'approved': true,
};

Finder _inFilters(String label) => find.descendant(
  of: find.byKey(const ValueKey('automation-filters')),
  matching: find.text(label),
);

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = automationsEngine();
    engine.answers['scene.list'] = {
      'ok': true,
      'scenes': [_movieScene],
    };
  });

  group('1 Scenes can be found from an empty Automations list', () {
    testWidgets('with nothing saved, All, Rules and Scenes still show and '
        'the empty state offers a new automation and a new scene', (
      tester,
    ) async {
      engine.answers['automation.list'] = {'ok': true, 'automations': []};
      await _pump(tester, engine, const AutomationsScreen());
      for (final f in ['All', 'Rules', 'Scenes']) {
        expect(_inFilters(f), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('automations-empty')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('automations-empty-new')),
        findsOneWidget,
      );
      await tapKey(tester, 'automations-empty-new-scene');
      expect(find.byType(SceneEditorPage), findsOneWidget);
    });

    testWidgets('the Scenes switch with no scenes offers New scene', (
      tester,
    ) async {
      engine.answers['automation.list'] = {'ok': true, 'automations': []};
      await _pump(tester, engine, const AutomationsScreen());
      await tester.tap(_inFilters('Scenes'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scenes-empty')), findsOneWidget);
      await tapKey(tester, 'scenes-filter-new');
      expect(find.byType(SceneEditorPage), findsOneWidget);
    });
  });

  group('6 an offline device in a step', () {
    testWidgets('a rule step says the device is not answering and still '
        'saves', (tester) async {
      await _pushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Bulb on at 7 PM',
            'when': [
              {'time': '19:00'},
            ],
            'then': [
              {
                'do': 'hall_bulb.power',
                'params': {'value': true},
              },
            ],
          },
        ),
      );
      expect(find.text('Hall bulb is not answering right now'), findsOneWidget);
      expect(buttonEnabled(tester, 'rule-save'), isTrue);
      await tapKey(tester, 'rule-save');
      expect(engine.callsOf('automation.save'), hasLength(1));
    });

    testWidgets('a scene step says so too', (tester) async {
      await _pushed(tester, engine, const SceneEditorPage(id: 'movie'));
      expect(find.text('Hall bulb is not answering right now'), findsOneWidget);
      expect(find.text('Desk lamp is not answering right now'), findsNothing);
    });
  });

  group('8 the name suggests what the rule does', () {
    testWidgets('Save on an unnamed rule offers "Desk lamp on at 7 PM", '
        'never a template name', (tester) async {
      await _pushed(
        tester,
        engine,
        const RuleEditorPage(initial: _lampAtSeven),
      );
      await tapKey(tester, 'rule-save');
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('prompt-field')),
      );
      expect(field.controller!.text, 'Desk lamp on at 7 PM');
      expect(field.decoration?.hintText, isNot('Arrive home'));
      expect(find.text('Arrive home'), findsNothing);
      await tapKey(tester, 'prompt-save');
      expect(savedSpec(engine)['name'], 'Desk lamp on at 7 PM');
    });

    test('the suggestion reads the step, then when it runs', () {
      final words = RuleWords([Thing(FakeEngine.lamp())]);
      final spec = RuleSpec.fromJson(_lampAtSeven);
      expect(words.suggestedName(spec), 'Desk lamp on at 7 PM');
      expect(words.suggestedName(spec, hour12: false), 'Desk lamp on at 19:00');
      expect(words.suggestedName(RuleSpec.fromJson(const {})), '');
      expect(
        words.suggestedName(
          RuleSpec.fromJson(const {
            'when': [
              {'sun': 'sunset'},
            ],
            'then': [
              {
                'do': 'desk_lamp.power',
                'params': {'value': false},
              },
            ],
          }),
        ),
        'Desk lamp off at sunset',
      );
    });
  });

  group('9 one undo story', () {
    testWidgets('Recently removed stays on an empty list', (tester) async {
      engine.answers['automation.list'] = {'ok': true, 'automations': []};
      await _pump(tester, engine, const AutomationsScreen());
      expect(find.byKey(const ValueKey('automations-removed')), findsOneWidget);
    });

    testWidgets('removing a rule says it can be put back from Recently '
        'removed', (tester) async {
      engine.answers['automation.get'] = _stored({
        ..._lampAtSeven,
        'name': 'Arrive home',
      });
      await _pushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
      await tapKey(tester, 'rule-menu');
      await tapText(tester, 'Remove');
      expect(
        find.textContaining('You can put it back from Recently removed'),
        findsOneWidget,
      );
      expect(find.textContaining('for a moment'), findsNothing);
    });

    testWidgets('removing a scene says the same and Undo puts it back', (
      tester,
    ) async {
      await _pushed(tester, engine, const SceneEditorPage(id: 'movie'));
      await tapKey(tester, 'scene-menu');
      await tapKey(tester, 'scene-remove');
      expect(
        find.textContaining('You can put it back from Recently removed'),
        findsOneWidget,
      );
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('scene.remove').single.$2, {'id': 'movie'});
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('automation.unremove').single.$2, {'id': 'movie'});
    });
  });

  group('10 Remove sits in the ··· menu for scenes too', () {
    testWidgets('the scene editor has no Remove icon in its header', (
      tester,
    ) async {
      await _pushed(tester, engine, const SceneEditorPage(id: 'movie'));
      expect(find.byKey(const ValueKey('scene-remove')), findsNothing);
      expect(find.byTooltip('Remove Movie'), findsNothing);
      await tapKey(tester, 'scene-menu');
      expect(find.byKey(const ValueKey('scene-remove')), findsOneWidget);
    });
  });

  group('11 one set of words in the editor', () {
    testWidgets('the header hint shows only once there are words', (
      tester,
    ) async {
      await _pushed(tester, engine, const RuleEditorPage());
      expect(find.byKey(const ValueKey('rule-words-hint')), findsNothing);
      expect(find.text('Tap here to give it a name'), findsOneWidget);
      await tapText(tester, 'Choose what starts it');
      await tapKey(tester, 'pick-time');
      await tapKey(tester, 'form-done');
      expect(find.byKey(const ValueKey('rule-words-hint')), findsOneWidget);
    });

    testWidgets('WHEN and THEN words, with no "trigger"', (tester) async {
      await _pushed(tester, engine, const RuleEditorPage());
      expect(find.text('Choose a WHEN and a THEN to save.'), findsOneWidget);
      expect(find.textContaining('trigger'), findsNothing);
      await openSection(tester, 'Options');
      expect(find.textContaining('trigger'), findsNothing);
      expect(find.textContaining('When its WHEN happens'), findsOneWidget);
    });

    testWidgets('an empty THEN has one way to add a step', (tester) async {
      await _pushed(tester, engine, const RuleEditorPage());
      expect(find.text('Choose what it does'), findsOneWidget);
      expect(find.text('Add a step'), findsNothing);
      expect(find.text('Add an ONLY IF'), findsOneWidget);
      // With a WHEN, the end block adds another one or a check, not a step.
      await tapText(tester, 'Choose what starts it');
      await tapKey(tester, 'pick-time');
      await tapKey(tester, 'form-done');
      expect(find.text('Add a step'), findsNothing);
      await tapKey(tester, 'rule-add-a-step');
      expect(find.byKey(const ValueKey('add-part-when')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-part-onlyIf')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-part-then')), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      // Once THEN has a step its target goes and Add a step offers all.
      await tapText(tester, 'Choose what it does');
      await tapKey(tester, 'quick-desk_lamp-on');
      expect(find.text('Choose what it does'), findsNothing);
      expect(find.text('Add a step'), findsOneWidget);
    });

    testWidgets('the dry run from a WHEN reads apart from Test run', (
      tester,
    ) async {
      await _pushed(
        tester,
        engine,
        const RuleEditorPage(initial: _lampAtSeven),
      );
      expect(find.text('Pretend this just happened'), findsOneWidget);
      expect(find.textContaining('Try as if'), findsNothing);
      expect(find.text('Test run'), findsOneWidget);
    });

    testWidgets('the scene editor reads "Do these together" and "step"', (
      tester,
    ) async {
      await _pushed(tester, engine, const SceneEditorPage());
      expect(find.text('DO THESE TOGETHER'), findsOneWidget);
      expect(find.text('Add a step'), findsOneWidget);
      expect(find.textContaining('action'), findsNothing);
    });
  });

  group('12 Time first, with quick day choices', () {
    testWidgets('Time is the first WHEN choice', (tester) async {
      await _pushed(tester, engine, const RuleEditorPage());
      await tapText(tester, 'Choose what starts it');
      final chips = find.byKey(const ValueKey('library-categories'));
      final time = find.descendant(
        of: chips,
        matching: find.byKey(const ValueKey('category-Time')),
      );
      final me = find.descendant(
        of: chips,
        matching: find.byKey(const ValueKey('category-Me')),
      );
      expect(tester.getTopLeft(time).dx, lessThan(tester.getTopLeft(me).dx));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('pick-time'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('pick-home'))).dy),
      );
    });

    testWidgets('Every day, Weekdays and Weekends come before the single '
        'days, and none picked reads Every day', (tester) async {
      await _pushed(tester, engine, const RuleEditorPage());
      await tapText(tester, 'Choose what starts it');
      await tapKey(tester, 'pick-time');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('time-days'))).data,
        'Every day',
      );
      final quick = tester.getTopLeft(find.byKey(const ValueKey('day-quick')));
      expect(
        quick.dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('day-mon'))).dy),
      );
      await tapKey(tester, 'days-weekends');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('time-days'))).data,
        'On weekends',
      );
      await tapKey(tester, 'days-every');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('time-days'))).data,
        'Every day',
      );
      await tapKey(tester, 'form-done');
      // Every day adds no days to the rule.
      expect(find.textContaining('18:00', findRichText: true), findsOneWidget);
      expect(find.textContaining('every', findRichText: true), findsNothing);
    });
  });

  group('13 a time rule in few taps', () {
    testWidgets('"Desk lamp on at 7 PM weekdays" from New to Saved takes 11 '
        'taps, with one sheet at a time', (tester) async {
      engine.answers['automation.list'] = {'ok': true, 'automations': []};
      engine.answers['automation.save'] = {
        'ok': true,
        'id': 'desk_lamp_on_at_7_pm',
        'approved': true,
      };
      await _pump(tester, engine, const AutomationsScreen());
      var taps = 0;
      Future<void> key(String k) async {
        taps++;
        await tapKey(tester, k);
      }

      Future<void> text(String t) async {
        taps++;
        await tapText(tester, t);
      }

      await key('automations-empty-new');
      await key('new-blank-rule');
      await text('Choose what starts it');
      await key('pick-time');
      // Picking Time closed the library: the time sheet is the only one.
      expect(find.text('When…'), findsNothing);
      expect(find.byType(TimePickerDialog), findsNothing);
      await key('clock-hour-up');
      await key('days-weekdays');
      await key('form-done');
      await text('Choose what it does');
      await key('quick-desk_lamp-on');
      await key('rule-save');
      await key('prompt-save');
      expect(taps, 11);
      expect(savedSpec(engine), {
        'name': 'Desk lamp on at 7 PM',
        'when': [
          {
            'time': '19:00',
            'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
          },
        ],
        'then': [
          {
            'do': 'desk_lamp.power',
            'params': {'value': true},
          },
        ],
      });
      expect(find.byType(RuleEditorPage), findsNothing);
    });

    testWidgets('the time steps by hour and five minutes, with AM and PM', (
      tester,
    ) async {
      await _pushed(tester, engine, const RuleEditorPage());
      await tapText(tester, 'Choose what starts it');
      await tapKey(tester, 'pick-time');
      await tapKey(tester, 'clock-minute-up');
      await tapKey(tester, 'clock-am');
      await tapKey(tester, 'clock-hour-down');
      await tapKey(tester, 'form-done');
      expect(find.textContaining('05:05', findRichText: true), findsOneWidget);
    });
  });

  group('17 the On and Off on a card is a switch', () {
    testWidgets('it is a toggled button with a 48 dp target and a track', (
      tester,
    ) async {
      await _pump(tester, engine, const AutomationsScreen());
      final control = find.byKey(const ValueKey('enable-arrive_home'));
      final size = tester.getSize(control);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      final node = tester.getSemantics(control);
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isToggled, Tristate.isTrue);
      expect(
        find.byKey(const ValueKey('enable-switch-arrive_home')),
        findsOneWidget,
      );
      final off = tester.getSemantics(
        find.byKey(const ValueKey('enable-door_mute')),
      );
      expect(off.flagsCollection.isToggled, Tristate.isFalse);
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(engine.callsOf('automation.enable').single.$2, {
        'id': 'arrive_home',
        'enabled': false,
      });
    });
  });

  group('18 Save how things are now has words', () {
    testWidgets('the Scenes page shows it as a labelled button', (
      tester,
    ) async {
      await _pushed(tester, engine, const ScenesPage());
      final capture = find.byKey(const ValueKey('scene-capture'));
      expect(capture, findsOneWidget);
      expect(
        find.descendant(
          of: capture,
          matching: find.text('Save how things are now'),
        ),
        findsOneWidget,
      );
    });
  });

  group('21 a scene run says what ran', () {
    testWidgets('Run says "Ran Movie"', (tester) async {
      engine.answers['scene.run'] = {
        'ok': true,
        'runs': [
          {
            'run': 's1',
            'flow': 'movie',
            'outcome': 'completed',
            'startedAt': DateTime.now().toIso8601String(),
            'nodes': [],
          },
        ],
      };
      await _pushed(tester, engine, const ScenesPage());
      await tapKey(tester, 'scene-run-movie');
      expect(find.text('Ran Movie'), findsOneWidget);
      expect(find.textContaining('is set'), findsNothing);
    });
  });
}
