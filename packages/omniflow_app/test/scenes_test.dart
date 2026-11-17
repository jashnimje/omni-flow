import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/automations/automations.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

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

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = automationsEngine();
    engine.answers['scene.list'] = {
      'ok': true,
      'scenes': [_movieScene],
    };
  });

  testWidgets('the scenes list shows each scene with Run', (tester) async {
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
    await pumpPushed(tester, engine, const ScenesPage());
    expect(find.text('Movie'), findsOneWidget);
    expect(find.text('Arrive home'), findsNothing);
    await tapKey(tester, 'scene-run-movie');
    expect(engine.callsOf('scene.run').single.$2, {'id': 'movie'});
    expect(find.text('Movie is set'), findsOneWidget);
  });

  testWidgets('with no scenes it says what one is', (tester) async {
    engine.answers['automation.list'] = {'ok': true, 'automations': []};
    await pumpPushed(tester, engine, const ScenesPage());
    expect(find.byKey(const ValueKey('scenes-empty')), findsOneWidget);
  });

  testWidgets('when OmniFlow does not answer the list says so', (tester) async {
    engine.throwOn.add('automation.list');
    await pumpPushed(tester, engine, const ScenesPage());
    expect(find.byKey(const ValueKey('omni-error')), findsOneWidget);
  });

  testWidgets('a new scene picks devices and their actions, and saves as '
      'the user\'s own', (tester) async {
    engine.answers['scene.save'] = {'ok': true, 'id': 'sleep'};
    await pumpPushed(tester, engine, const SceneEditorPage());
    expect(find.text('New scene'), findsOneWidget);
    expect(buttonEnabled(tester, 'scene-save'), isFalse);
    await tester.enterText(find.byKey(const ValueKey('scene-name')), 'Sleep');
    await tester.pump();
    await tapKey(tester, 'scene-look');
    await tapKey(tester, 'look-icon-moon');
    await tapKey(tester, 'look-done');
    await tapText(tester, 'Add an action');
    await tapKey(tester, 'pick-device-desk_lamp');
    expect(find.byKey(const ValueKey('act-toggle-power')), findsNothing);
    await tapKey(tester, 'act-off-power');
    await tapKey(tester, 'form-done');
    await tapText(tester, 'Add an action');
    await tapKey(tester, 'pick-device-desk_lamp');
    await tapKey(tester, 'act-brightness');
    await tapKey(tester, 'form-done');
    expect(find.text('Desk lamp · turn off'), findsOneWidget);
    expect(find.text('Desk lamp · brightness 55%'), findsOneWidget);
    await tapKey(tester, 'scene-save');
    expect(engine.callsOf('scene.save').single.$2, {
      'name': 'Sleep',
      'icon': 'moon',
      'actions': [
        {
          'do': 'desk_lamp.power',
          'params': {'value': false},
        },
        {
          'do': 'desk_lamp.brightness',
          'params': {'value': 55},
        },
      ],
      'trusted': true,
    });
    expect(find.byType(SceneEditorPage), findsNothing);
    expect(find.text('Saved Sleep'), findsOneWidget);
  });

  testWidgets('a stored scene opens with its actions and saves under its id', (
    tester,
  ) async {
    await pumpPushed(tester, engine, const SceneEditorPage(id: 'movie'));
    expect(find.text('Desk lamp · brightness 20%'), findsOneWidget);
    expect(find.text('Hall bulb · turn off'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove Hall bulb · turn off'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'scene-save');
    final call = engine.callsOf('scene.save').single.$2;
    expect(call['id'], 'movie');
    expect((call['actions'] as List).length, 1);
  });

  testWidgets('an action the engine refuses is marked', (tester) async {
    engine.answers['scene.save'] = {
      'ok': false,
      'error': {
        'type': 'invalid',
        'message': 'scene movie',
        'issues': [
          {'path': 'actions[1].do', 'message': 'hall_bulb is offline'},
        ],
      },
    };
    await pumpPushed(tester, engine, const SceneEditorPage(id: 'movie'));
    await tester.enterText(find.byKey(const ValueKey('scene-name')), 'Movies');
    await tester.pump();
    await tapKey(tester, 'scene-save');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scene-action-1')),
        matching: find.text('hall_bulb is offline'),
      ),
      findsOneWidget,
    );
    expect(find.byType(SceneEditorPage), findsOneWidget);
  });

  testWidgets('Remove asks first, and Cancel keeps the scene', (tester) async {
    await pumpPushed(tester, engine, const SceneEditorPage(id: 'movie'));
    await tapKey(tester, 'scene-remove');
    expect(find.text('Remove Movie?'), findsOneWidget);
    await tapKey(tester, 'confirm-cancel');
    expect(engine.callsOf('scene.remove'), isEmpty);
    await tapKey(tester, 'scene-remove');
    await tapKey(tester, 'confirm');
    expect(engine.callsOf('scene.remove').single.$2, {'id': 'movie'});
    expect(find.byType(SceneEditorPage), findsNothing);
  });

  testWidgets('leaving a changed scene asks first', (tester) async {
    await pumpPushed(tester, engine, const SceneEditorPage(id: 'movie'));
    await tester.enterText(find.byKey(const ValueKey('scene-name')), 'Films');
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tapKey(tester, 'confirm');
    expect(find.byType(SceneEditorPage), findsNothing);
    expect(engine.callsOf('scene.save'), isEmpty);
  });

  testWidgets('a scene that is gone says so', (tester) async {
    engine.answers['scene.list'] = {'ok': true, 'scenes': []};
    await pumpPushed(tester, engine, const SceneEditorPage(id: 'movie'));
    expect(find.byKey(const ValueKey('scene-missing')), findsOneWidget);
  });
}
