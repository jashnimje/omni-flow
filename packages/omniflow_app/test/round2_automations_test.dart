import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart' show RunRecord;
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/library_sheet.dart';
import 'package:omniflow_app/ui/automations/rule_editor.dart'
    show duplicateSpec;
import 'package:omniflow_app/ui/automations/run_words.dart';
import 'package:omniflow_app/ui/automations/scenes.dart'
    show sameSceneAction, sceneIconFor, sceneLookIcon;
import 'package:omniflow_app/ui/automations/sun_lighting_page.dart';
import 'package:omniflow_app/ui/automations/test_run.dart' show TestRunKind;
import 'package:omniflow_app/ui/design/automation_look.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/api/engine_calls.dart' show SceneAction;

import 'automations_fixtures.dart';
import 'fake_engine.dart';

/// The second fix round on the Automations screens: each finding of the
/// emulator recheck that lives there.

const _evening = <String, Object?>{
  'id': 'evening_tv',
  'name': 'Evening TV',
  'when': [
    {'time': '19:30'},
  ],
  'then': [
    {
      'do': 'desk_lamp.power',
      'params': {'value': true},
    },
  ],
};

Map<String, Object?> _dry({DateTime? at}) => {
  'run': 'dry',
  'flow': 'evening_tv',
  'dryRun': true,
  'outcome': 'completed',
  'startedAt': (at ?? DateTime(2026, 11, 17, 15, 48)).toIso8601String(),
  'nodes': [
    {
      'node': 'when',
      'type': 'time_of_day',
      'label': 'at 19:30 on weekdays',
      'port': 'out',
    },
    {
      'node': 'c',
      'type': 'time_window',
      'label': 'if between 18:00 and 23:00',
      'port': 'true',
    },
  ],
};

void main() {
  late FakeEngine engine;

  setUp(() => engine = automationsEngine());

  group('N1 Duplicate', () {
    test('the copy drops the id so it saves as a new rule', () {
      final copy = duplicateSpec(_evening);
      expect(copy.containsKey('id'), isFalse);
      expect(copy['name'], 'Evening TV copy');
      expect(copy['when'], _evening['when']);
      expect(
        duplicateSpec({'id': 'x', 'name': ' '})['name'],
        'New automation copy',
      );
    });

    testWidgets('Duplicate then Save sends a rule with no id', (tester) async {
      engine.answers['automation.get'] = {
        'ok': true,
        'id': 'evening_tv',
        'name': 'Evening TV',
        'source': 'rule',
        'spec': _evening,
        'approved': true,
        'flow': {'nodes': []},
      };
      engine.answers['automation.save'] = {
        'ok': true,
        'id': 'evening_tv_copy',
        'approved': true,
      };
      await pumpPushed(tester, engine, const RuleEditorPage(id: 'evening_tv'));
      await tapKey(tester, 'rule-menu');
      await tapKey(tester, 'rule-duplicate');
      expect(find.text('Evening TV copy'), findsWidgets);
      await tapKey(tester, 'rule-save');
      final call = engine.callsOf('automation.save').single.$2;
      expect(call.containsKey('id'), isFalse);
      expect((call['spec'] as Map).containsKey('id'), isFalse);
      expect((call['spec'] as Map)['name'], 'Evening TV copy');
    });
  });

  group('#36, N4, #3 each test page has its own purpose', () {
    testWidgets('Test run judges now and says so, with no run history', (
      tester,
    ) async {
      await pumpPushed(
        tester,
        engine,
        TestRunPage(
          name: 'Evening TV',
          id: 'evening_tv',
          dryRun: RunRecord.fromJson(_dry()),
          kind: TestRunKind.test,
        ),
      );
      expect(find.text('Evening TV · test run'), findsOneWidget);
      expect(find.textContaining('if it started now, at'), findsOneWidget);
      expect(find.text('pretended it happened now'), findsOneWidget);
      expect(find.text('Last runs'), findsNothing);
      expect(engine.callsOf('automation.log'), isEmpty);
      expect(find.byKey(const ValueKey('run-now')), findsOneWidget);
    });

    testWidgets('Try as if on a saved rule offers Run it now', (tester) async {
      await pumpPushed(
        tester,
        engine,
        TestRunPage(
          name: 'Evening TV',
          id: 'evening_tv',
          dryRun: RunRecord.fromJson(_dry()),
          kind: TestRunKind.tryAsIf,
        ),
      );
      expect(find.text('Evening TV · try as if'), findsOneWidget);
      expect(find.textContaining('if this happened: At'), findsOneWidget);
      expect(find.text('pretended it happened'), findsOneWidget);
      expect(find.byKey(const ValueKey('run-now')), findsOneWidget);
      expect(find.byKey(const ValueKey('save-to-run')), findsNothing);
      expect(find.text('Last runs'), findsNothing);
    });

    testWidgets('Runs lists the real runs only, with no test', (tester) async {
      engine.answers['automation.log'] = {'ok': true, 'runs': []};
      await pumpPushed(
        tester,
        engine,
        const TestRunPage(
          name: 'Evening TV',
          id: 'evening_tv',
          kind: TestRunKind.runs,
        ),
      );
      expect(find.text('Evening TV · runs'), findsOneWidget);
      expect(engine.callsOf('automation.dry_run'), isEmpty);
      expect(find.byKey(const ValueKey('dry-run-banner')), findsNothing);
      expect(find.byKey(const ValueKey('no-runs')), findsOneWidget);
    });

    testWidgets('the editor menu says Runs, not Runs and test', (tester) async {
      engine.answers['automation.get'] = {
        'ok': true,
        'id': 'evening_tv',
        'name': 'Evening TV',
        'source': 'rule',
        'spec': _evening,
        'approved': true,
        'flow': {'nodes': []},
      };
      await pumpPushed(tester, engine, const RuleEditorPage(id: 'evening_tv'));
      await tapKey(tester, 'rule-menu');
      expect(find.text('Runs and test'), findsNothing);
      await tester.tap(find.text('Runs'));
      await tester.pumpAndSettle();
      expect(find.text('Evening TV · runs'), findsOneWidget);
    });
  });

  group('#12, #55 run rows', () {
    test('step words are capitalised and read the phone clock', () {
      expect(
        stepWords('if between 18:00 and 23:00', hour12: true),
        'If between 6:00 PM and 11:00 PM',
      );
      expect(
        stepWords('at 19:30 on weekdays', hour12: false),
        'At 19:30 on weekdays',
      );
      expect(stepWords('wait 2 s', hour12: true), 'Wait 2 s');
      expect(stepWords('At 7:30 PM', hour12: true), 'At 7:30 PM');
    });
  });

  group('#27 Waiting for approval', () {
    testWidgets('lists what waits, each opening its review', (tester) async {
      await pumpPushed(tester, engine, const WaitingPage());
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.byKey(const ValueKey('waiting-movie_night')), findsOneWidget);
      expect(find.byKey(const ValueKey('waiting-arrive_home')), findsNothing);
    });

    testWidgets('says so when nothing waits, on its own page', (tester) async {
      engine.answers['automation.list'] = {'ok': true, 'automations': []};
      await pumpPushed(tester, engine, const WaitingPage());
      expect(find.byKey(const ValueKey('waiting-empty')), findsOneWidget);
    });
  });

  group('#57 the filter chips', () {
    testWidgets('the filters are All, Rules and Scenes, and All lists the '
        'scenes', (tester) async {
      engine.answers['automation.list'] = {
        'ok': true,
        'automations': [
          for (final a in automationRows())
            if (a['enabled'] != false && a['source'] != 'link') a,
        ],
      };
      await pumpPage(tester, engine, const AutomationsScreen());
      final filters = find.byKey(const ValueKey('automation-filters'));
      for (final f in ['All', 'Rules', 'Scenes']) {
        expect(
          find.descendant(of: filters, matching: find.text(f)),
          findsOneWidget,
        );
      }
      expect(find.textContaining('Quick links'), findsNothing);
      expect(find.textContaining(RegExp(r'^Off \d')), findsNothing);
      expect(find.byKey(const ValueKey('scene-movie')), findsOneWidget);
    });

    testWidgets('the Scenes filter has no New scene of its own', (
      tester,
    ) async {
      await pumpPage(tester, engine, const AutomationsScreen());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('automation-filters')),
          matching: find.text('Scenes'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scene-new')), findsNothing);
      expect(find.text('New scene'), findsNothing);
    });
  });

  group('N6, N11, #42 scenes', () {
    test('an action left as it was is the same action', () {
      expect(
        sameSceneAction(
          const SceneAction('lamp.brightness', {'value': 55}),
          const SceneAction('lamp.brightness', {'value': 55.0}),
        ),
        isTrue,
      );
      expect(
        sameSceneAction(
          const SceneAction('lamp.power', {'value': true}),
          const SceneAction('lamp.power', {'value': false}),
        ),
        isFalse,
      );
    });

    test('scenes take the rule icons, and older scene names still draw', () {
      expect(sceneIconFor('moon'), AutomationLook.icons['moon']);
      expect(sceneIconFor('coffee'), isNotNull);
      expect(sceneLookIcon('bedtime'), 'moon');
      expect(sceneLookIcon('coffee'), 'coffee');
    });

    testWidgets('Done on a step left unchanged does not ask to discard', (
      tester,
    ) async {
      engine.answers['scene.list'] = {
        'ok': true,
        'scenes': [
          {
            'id': 'movie',
            'name': 'Movie',
            'actions': [
              {
                'do': 'desk_lamp.power',
                'params': {'value': false},
              },
            ],
          },
        ],
      };
      await pumpPushed(tester, engine, const SceneEditorPage(id: 'movie'));
      expect(find.text('Desk lamp · turn off'), findsOneWidget);
      await tester.tap(find.text('Desk lamp · turn off'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'form-done');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(SceneEditorPage), findsNothing);
    });

    testWidgets('the scene look is the shared picker with a ring', (
      tester,
    ) async {
      await pumpPushed(tester, engine, const SceneEditorPage());
      expect(find.byKey(const ValueKey('scene-icon-movie')), findsNothing);
      // Colour and icon wait in Options, collapsed.
      expect(find.byKey(const ValueKey('scene-look')), findsNothing);
      await tapKey(tester, 'scene-options');
      await tapKey(tester, 'scene-look');
      expect(find.byKey(const ValueKey('look-icon-bolt')), findsOneWidget);
      expect(find.byKey(const ValueKey('look-color-A78BFA')), findsOneWidget);
    });

    testWidgets('leaving a new scene asks to discard it, not its changes', (
      tester,
    ) async {
      await pumpPushed(tester, engine, const SceneEditorPage());
      await tester.enterText(find.byKey(const ValueKey('scene-name')), 'Sleep');
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard this new scene?'), findsOneWidget);
      expect(find.text('Discard changes?'), findsNothing);
    });
  });

  group('#56 a new rule', () {
    testWidgets('leaving it asks to discard the rule', (tester) async {
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {'name': 'Night', 'when': [], 'then': []},
        ),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard this new automation?'), findsOneWidget);
      expect(
        find.text('It has not been saved, so it will be lost.'),
        findsOneWidget,
      );
    });
  });

  group('N7, #38 the step library', () {
    testWidgets('opens with the list in view and one Wait', (tester) async {
      await pumpPage(
        tester,
        engine,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLibrary<void>(
                context,
                title: 'Add a step',
                hint: 'Search',
                categories: const ['Wait', 'Devices'],
                choices: [
                  LibraryChoice(
                    key: 'wait',
                    title: 'Wait',
                    icon: OmniIcons.wait,
                    category: 'Wait',
                    onTap: (_) async {},
                  ),
                ],
                suggestions: [
                  LibrarySuggestion(
                    key: 'suggest-kind-wait',
                    label: 'Wait',
                    icon: OmniIcons.wait,
                    onTap: (_) async {},
                  ),
                  LibrarySuggestion(
                    key: 'suggest-device-lamp',
                    label: 'Desk lamp',
                    icon: OmniIcons.light,
                    onTap: (_) async {},
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('picker-search')),
      );
      expect(field.autofocus, isFalse);
      expect(field.focusNode?.hasFocus ?? false, isFalse);
      expect(find.byKey(const ValueKey('suggest-kind-wait')), findsNothing);
      expect(find.byKey(const ValueKey('suggest-device-lamp')), findsOneWidget);
      expect(find.byKey(const ValueKey('category-Wait')), findsOneWidget);
    });
  });

  group('#51 New', () {
    testWidgets('the New sheet makes a scene too', (tester) async {
      engine.answers['automation.templates'] = {'ok': true, 'templates': []};
      await pumpPage(
        tester,
        engine,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openNewAutomation(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'new-scene');
      expect(find.byType(SceneEditorPage), findsOneWidget);
    });
  });

  group('N9, #25 Follow the sun', () {
    testWidgets('with no lights it says why the range cannot save, and the '
        'chart has a time axis', (tester) async {
      engine.devices = [];
      final start = DateTime(2026, 11, 17);
      engine.answers['sunlight.get'] = {
        'ok': true,
        'targets': [],
        'paused': [],
        'preview': [
          for (var i = 0; i < 48; i++)
            {
              'at': start.add(Duration(minutes: 30 * i)).toIso8601String(),
              'kelvin': 2700 + i * 20,
              'brightness': 10 + i,
            },
        ],
      };
      await pumpPushed(tester, engine, const SunLightingPage());
      expect(
        find.textContaining('Add a light with brightness or white'),
        findsOneWidget,
      );
      expect(find.text('No lights to follow the sun yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('sun-curve-axis')), findsOneWidget);
    });
  });
}
