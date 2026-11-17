import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/sentence_row.dart';
import 'package:omniflow_app/ui/design/design.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

const _arrive = <String, Object?>{
  'name': 'Arrive home',
  'when': [
    {
      'on': 'jade.home',
      'change': {'to': true},
    },
  ],
  'then': [
    {
      'do': 'desk_lamp.power',
      'params': {'value': true},
    },
    {'wait': 3000},
    {
      'do': 'hall_bulb.power',
      'params': {'value': true},
    },
  ],
};

Map<String, Object?> _stored(
  Map<String, Object?> spec, {
  bool approved = true,
}) => {
  'ok': true,
  'id': 'arrive_home',
  'name': spec['name'],
  'source': 'rule',
  'spec': spec,
  'approved': approved,
  'revision': 'r1',
  'flow': {'nodes': []},
};

Future<void> _name(WidgetTester tester, String name) async {
  await tester.enterText(find.byKey(const ValueKey('prompt-field')), name);
  await tester.pump();
  await tapKey(tester, 'prompt-save');
}

void main() {
  late FakeEngine engine;

  setUp(() => engine = automationsEngine());

  testWidgets('builds a rule from the pickers in plain words and saves it '
      'as a trusted rule', (tester) async {
    await pumpPushed(tester, engine, const RuleEditorPage());
    expect(find.text('New automation'), findsOneWidget);
    expect(buttonEnabled(tester, 'rule-save'), isFalse);
    expect(find.text('Add a trigger and a step to save.'), findsOneWidget);

    await tapText(tester, 'Add trigger');
    expect(find.text('When…'), findsOneWidget);
    expect(find.text('Me'), findsWidgets);
    expect(find.text('Things'), findsWidgets);
    expect(find.text('Time'), findsWidgets);
    await tapKey(tester, 'pick-home');
    await tapKey(tester, 'form-done');
    expect(find.text('I get home'), findsOneWidget);

    await tapText(tester, 'Add condition');
    await tapKey(tester, 'pick-between');
    await tapKey(tester, 'form-done');
    expect(find.text('Between 18:00 and 23:30'), findsOneWidget);

    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-device-desk_lamp');
    await tapKey(tester, 'act-on-power');
    await tapKey(tester, 'form-done');
    expect(find.text('Desk lamp · turn on'), findsOneWidget);

    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-wait');
    await tapKey(tester, 'form-done');
    expect(find.text('Wait 3 s'), findsOneWidget);

    await tapKey(tester, 'rule-save');
    await _name(tester, 'Evening lights');
    final call = engine.callsOf('automation.save').single.$2;
    expect(call['form'], 'rule');
    expect(call['trusted'], isTrue);
    expect(call.containsKey('replace'), isFalse);
    expect(savedSpec(engine), {
      'name': 'Evening lights',
      'when': [
        {
          'on': 'jade.home',
          'change': {'to': true},
        },
      ],
      'onlyIf': [
        {
          'between': ['18:00', '23:30'],
        },
      ],
      'then': [
        {
          'do': 'desk_lamp.power',
          'params': {'value': true},
        },
        {'wait': 3000},
      ],
    });
    expect(find.byType(RuleEditorPage), findsNothing);
    expect(find.text('Saved Evening lights'), findsOneWidget);
  });

  testWidgets('a variable is picked from the ones automations set', (
    tester,
  ) async {
    engine.answers['var.list'] = {
      'ok': true,
      'variables': {'Away': true, '_scheduled_x': 'internal', 'Mood': 'calm'},
    };
    await pumpPushed(
      tester,
      engine,
      const RuleEditorPage(
        initial: {
          'name': 'Mood check',
          'when': [
            {'manual': true},
          ],
          'then': [
            {
              'notify': {'title': 'Hi'},
            },
          ],
        },
      ),
    );
    await tapText(tester, 'Add condition');
    await tapKey(tester, 'pick-variable');
    expect(find.byKey(const ValueKey('known-var-_scheduled_x')), findsNothing);
    await tapKey(tester, 'known-var-Mood');
    await tester.enterText(find.byKey(const ValueKey('var-value')), 'calm');
    await tester.pump();
    await tapKey(tester, 'form-done');
    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine)['onlyIf'], [
      {'var': r'$Mood', 'op': '==', 'value': 'calm'},
    ]);
  });

  testWidgets('a TV state is checked by choosing its value, not typing it', (
    tester,
  ) async {
    engine.devices = [
      {
        'id': 'tv',
        'name': 'TV',
        'driver': 'android_tv_adb',
        'host': '192.168.1.60',
        'state': const {'power': 'on', 'app': 'com.netflix.ninja'},
        'capabilities': [
          {
            'id': 'power_state',
            'type': 'sensor',
            'label': 'Power (on, asleep or off)',
            'stateKey': 'power',
            'values': ['on', 'asleep', 'off'],
            'params': {},
          },
          {
            'id': 'current_app',
            'type': 'sensor',
            'label': 'App on screen',
            'stateKey': 'app',
            'params': {},
          },
        ],
      },
    ];
    engine.answers['tv.apps'] = {
      'ok': true,
      'apps': [
        {
          'package': 'com.netflix.ninja',
          'label': 'Netflix',
          'launchable': true,
        },
      ],
    };
    await pumpPushed(
      tester,
      engine,
      const RuleEditorPage(
        initial: {
          'name': 'TV check',
          'when': [
            {'manual': true},
          ],
          'then': [
            {
              'notify': {'title': 'Hi'},
            },
          ],
        },
      ),
    );
    await tapText(tester, 'Add condition');
    await tapKey(tester, 'pick-thing-tv');
    expect(find.text('Power is…'), findsOneWidget);
    await tapKey(tester, 'opt-isnot-power');
    expect(find.byKey(const ValueKey('opt-input')), findsNothing);
    await tapKey(tester, 'opt-choice-asleep');
    await tapKey(tester, 'form-done');

    await tapText(tester, 'Add condition');
    await tapKey(tester, 'pick-thing-tv');
    await tapKey(tester, 'opt-is-app');
    await tapKey(tester, 'opt-pick');
    await tapKey(tester, 'choice-com.netflix.ninja');
    await tapKey(tester, 'form-done');

    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine)['onlyIf'], [
      {'state': 'tv.power', 'op': '!=', 'value': 'asleep'},
      {'state': 'tv.app', 'op': '==', 'value': 'com.netflix.ninja'},
    ]);
  });

  testWidgets('a TV launch step picks the app from the TV app list', (
    tester,
  ) async {
    engine.devices = [
      {
        'id': 'tv',
        'name': 'TV',
        'driver': 'android_tv_adb',
        'host': '192.168.1.60',
        'state': const <String, Object?>{},
        'capabilities': [
          {
            'id': 'launch_app',
            'type': 'action',
            'label': 'Launch app',
            'params': {
              'package': {'type': 'string'},
            },
          },
        ],
      },
    ];
    engine.answers['tv.apps'] = {
      'ok': true,
      'apps': [
        {
          'package': 'com.android.tv.settings',
          'label': 'Settings',
          'system': true,
          'launchable': true,
        },
        {'package': 'com.android.shell', 'system': true},
        {
          'package': 'com.netflix.ninja',
          'label': 'Netflix',
          'launchable': true,
        },
      ],
    };
    await pumpPushed(tester, engine, const RuleEditorPage());
    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-device-tv');
    await tapKey(tester, 'act-launch_app');
    // The field and the sheet name the app, not the raw package param.
    expect(find.text('App'), findsOneWidget);
    expect(find.text('Package'), findsNothing);
    await tapKey(tester, 'param-package-pick');
    expect(find.text('Choose an app'), findsOneWidget);
    expect(engine.callsOf('tv.apps').single.$2, {'id': 'tv', 'filter': 'all'});
    expect(
      find.byKey(const ValueKey('choice-com.android.shell')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey('picker-search')).last,
      'sett',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('choice-com.netflix.ninja')),
      findsNothing,
    );
    await tapKey(tester, 'choice-com.android.tv.settings');
    await tapKey(tester, 'form-done');
    expect(find.textContaining('com.android.tv.settings'), findsOneWidget);
  });

  testWidgets('a number trigger reads as a short form in plain words', (
    tester,
  ) async {
    await pumpPushed(tester, engine, const RuleEditorPage());
    await tapText(tester, 'Add trigger');
    await tapKey(tester, 'pick-thing-room_temp');
    expect(find.text('When Room temperature…'), findsOneWidget);
    await tapKey(tester, 'opt-above-temp');
    expect(buttonEnabled(tester, 'form-done'), isFalse);
    await tester.enterText(find.byKey(const ValueKey('opt-input')), '28');
    await tester.pump();
    await tapKey(tester, 'form-done');
    expect(find.text('Room temperature goes above 28 °C'), findsOneWidget);
  });

  testWidgets('the trigger picker searches devices, places and tags', (
    tester,
  ) async {
    await pumpPushed(tester, engine, const RuleEditorPage());
    await tapText(tester, 'Add trigger');
    await tester.enterText(find.byKey(const ValueKey('picker-search')), 'temp');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pick-thing-room_temp')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-thing-desk_lamp')), findsNothing);
    expect(find.byKey(const ValueKey('pick-time')), findsNothing);
  });

  testWidgets('the step picker marks high-risk steps and says they need '
      'approval', (tester) async {
    await pumpPushed(tester, engine, const RuleEditorPage());
    await tapText(tester, 'Add step');
    // The device row stays plain; the warning sits on the risky step.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pick-device-living_tv')),
        matching: find.byIcon(OmniIcons.warning),
      ),
      findsNothing,
    );
    for (final kind in [
      'pick-wait',
      'pick-wait-until',
      'pick-if',
      'pick-together',
      'pick-keep',
      'pick-notify',
      'pick-set',
      'pick-run',
    ]) {
      expect(find.byKey(ValueKey(kind)), findsOneWidget, reason: kind);
    }
    await tester.enterText(
      find.byKey(const ValueKey('picker-search')),
      'run a command',
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pick-act-living_tv-shell')),
        matching: find.byIcon(OmniIcons.warning),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('picker-search')), '');
    await tester.pumpAndSettle();
    await tapKey(tester, 'pick-device-living_tv');
    expect(
      find.textContaining('High risk: runs commands on Living room TV'),
      findsOneWidget,
    );
  });

  testWidgets('Run a scene wears the scene\'s own icon, not the bolt', (
    tester,
  ) async {
    await pumpPushed(tester, engine, const RuleEditorPage());
    await tapText(tester, 'Add step');
    await tester.enterText(
      find.byKey(const ValueKey('picker-search')),
      'movie',
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('pick-scene-movie'));
    expect(
      find.descendant(of: row, matching: find.byIcon(Symbols.movie_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(OmniIcons.automations)),
      findsNothing,
    );
  });

  testWidgets('an engine error shows on the row its rule path names', (
    tester,
  ) async {
    engine.answers['automation.save'] = {
      'ok': false,
      'error': {
        'type': 'invalid',
        'message': 'rule arrive_home',
        'issues': [
          {'path': 'then[2].do', 'message': 'hall_bulb has no power'},
          {'path': 'mode', 'message': 'must be single, queued or parallel'},
        ],
      },
    };
    await pumpPushed(
      tester,
      engine,
      RuleEditorPage(initial: {..._arrive, 'name': 'Evening'}),
    );
    await tapKey(tester, 'rule-save');
    final row = find.byKey(const ValueKey('row-then[2]'));
    expect(
      find.descendant(of: row, matching: find.text('hall_bulb has no power')),
      findsOneWidget,
    );
    expect(tester.widget<SentenceRow>(row).error, 'hall_bulb has no power');
    expect(
      tester
          .widget<SentenceRow>(find.byKey(const ValueKey('row-then[0]')))
          .error,
      isNull,
    );
    expect(find.textContaining('Fix the rows marked in red.'), findsOneWidget);
    expect(
      find.textContaining('must be single, queued or parallel'),
      findsWidgets,
    );
    expect(find.byType(RuleEditorPage), findsOneWidget);
  });

  testWidgets('Test run sends the rule as it stands to the dry run and shows '
      'what each step would do', (tester) async {
    engine.answers['automation.dry_run'] = {
      'ok': true,
      'run': {
        'run': 'dry1',
        'flow': 'arrive_home',
        'dryRun': true,
        'outcome': 'completed',
        'startedAt': DateTime.now().toIso8601String(),
        'nodes': [
          {
            'node': 't',
            'type': 'on',
            'label': 'When I get home',
            'port': 'out',
          },
          {
            'node': 'c',
            'type': 'time_window',
            'label': 'Between 18:00 and 23:30',
            'port': 'true',
          },
          {
            'node': 'a',
            'type': 'device_capability',
            'label': 'desk_lamp.power',
            'port': 'out',
            'output': {
              'result': {
                'dryRun': true,
                'deviceId': 'desk_lamp',
                'capabilityId': 'power',
                'params': {'value': true},
              },
            },
          },
        ],
      },
    };
    await pumpPushed(tester, engine, const RuleEditorPage(initial: _arrive));
    await tapKey(tester, 'rule-test');
    expect(engine.callsOf('automation.dry_run').single.$2, {
      'form': 'rule',
      'spec': _arrive,
    });
    expect(find.byType(TestRunPage), findsOneWidget);
    // A test run is judged now, and says so.
    expect(find.textContaining('· test run'), findsWidgets);
    expect(
      find.textContaining('This is what would happen if it started now, at'),
      findsOneWidget,
    );
    expect(find.text('pretended it happened now'), findsOneWidget);
    expect(find.text('holds'), findsOneWidget);
    expect(find.text('pass'), findsOneWidget);
    expect(find.text('would send power on'), findsOneWidget);
    expect(find.text('Last runs'), findsNothing);
  });

  testWidgets('a stored rule reopens as written and saves back under its id', (
    tester,
  ) async {
    engine.answers['automation.get'] = _stored(_arrive);
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    expect(find.text('Arrive home'), findsOneWidget);
    expect(find.text('I get home'), findsOneWidget);
    expect(find.text('Wait 3 s'), findsOneWidget);
    expect(find.text('Hall bulb · turn on'), findsOneWidget);
    await tapKey(tester, 'rule-save');
    final call = engine.callsOf('automation.save').single.$2;
    expect(call['id'], 'arrive_home');
    expect(call['replace'], isTrue);
    expect(call['trusted'], isTrue);
    expect(savedSpec(engine), _arrive);
  });

  testWidgets('dragging a step by its handle moves it', (tester) async {
    engine.answers['automation.get'] = _stored(_arrive);
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    final handle = find.descendant(
      of: find.byKey(const ValueKey('row-then[2]')),
      matching: find.byIcon(OmniIcons.drag),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tapKey(tester, 'rule-save');
    expect((savedSpec(engine)['then'] as List).first, {
      'do': 'hall_bulb.power',
      'params': {'value': true},
    });
  });

  testWidgets('removing a row drops it from the rule', (tester) async {
    engine.answers['automation.get'] = _stored(_arrive);
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    await tester.tap(find.byTooltip('Remove Wait 3 s'));
    await tester.pumpAndSettle();
    expect(find.text('Step removed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tapKey(tester, 'rule-save');
    expect((savedSpec(engine)['then'] as List).length, 2);
  });

  testWidgets('Undo puts a removed step back where it was', (tester) async {
    engine.answers['automation.get'] = _stored(_arrive);
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    await tester.tap(find.byTooltip('Remove Wait 3 s'));
    await tester.pumpAndSettle();
    expect(find.text('Wait 3 s'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Wait 3 s'), findsOneWidget);
    await tapKey(tester, 'rule-save');
    expect((savedSpec(engine)['then'] as List)[1], {'wait': 3000});
  });

  testWidgets('an If opens its own page with its check, then and otherwise', (
    tester,
  ) async {
    await pumpPushed(
      tester,
      engine,
      const RuleEditorPage(
        initial: {
          'name': 'Evening',
          'when': [
            {'time': '18:00'},
          ],
          'then': [],
        },
      ),
    );
    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-if');
    expect(find.text('If… otherwise'), findsOneWidget);
    expect(find.text('IF · all of these hold'), findsOneWidget);
    expect(find.text('OTHERWISE · in order, or nothing'), findsOneWidget);
    await tapIn(tester, 'block-then[0].if', 'Add condition');
    await tapKey(tester, 'pick-presence');
    await tapKey(tester, 'form-done');
    await tapIn(tester, 'block-then[0].then', 'Add step');
    await tapKey(tester, 'pick-device-desk_lamp');
    await tapKey(tester, 'act-off-power');
    await tapKey(tester, 'form-done');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    final row = tester.widget<SentenceRow>(
      find.byKey(const ValueKey('row-then[0]')),
    );
    expect(row.text, 'If I am home…');
    expect(row.trailingText, '1');
    expect(row.style, StepRowStyle.flow);
    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine)['then'], [
      {
        'if': [
          {'state': 'jade.home', 'op': '==', 'value': true},
        ],
        'then': [
          {
            'do': 'desk_lamp.power',
            'params': {'value': false},
          },
        ],
      },
    ]);
  });

  Future<void> notifyIn(WidgetTester tester, String block, String title) async {
    await tapIn(tester, block, 'Add step');
    await tapKey(tester, 'pick-notify');
    await tester.enterText(find.byKey(const ValueKey('notify-title')), title);
    await tester.pump();
    await tapKey(tester, 'form-done');
  }

  Future<void> pumpBlank(WidgetTester tester) => pumpPushed(
    tester,
    engine,
    const RuleEditorPage(
      initial: {
        'name': 'Film night',
        'when': [
          {'manual': true},
        ],
        'then': [],
      },
    ),
  );

  testWidgets('a try step saves its steps and its fallback', (tester) async {
    await pumpBlank(tester);
    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-try');
    expect(find.text('Try, with a fallback'), findsWidgets);
    await notifyIn(tester, 'block-then[0].try', 'Prime');
    await notifyIn(tester, 'block-then[0].otherwise', 'Living room TV');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Try these, with a fallback'), findsOneWidget);
    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine)['then'], [
      {
        'try': [
          {
            'notify': {'title': 'Prime'},
          },
        ],
        'otherwise': [
          {
            'notify': {'title': 'Living room TV'},
          },
        ],
      },
    ]);
  });

  testWidgets('a repeat step saves how often, when to stop and its steps', (
    tester,
  ) async {
    await pumpBlank(tester);
    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-repeat');
    await tapKey(tester, 'repeat-how');
    await tester.enterText(find.byKey(const ValueKey('repeat-times')), '5');
    await tester.pump();
    await tapKey(tester, 'form-done');
    await tapIn(tester, 'block-then[0].repeat.until', 'Add condition');
    await tapKey(tester, 'pick-between');
    await tapKey(tester, 'form-done');
    await notifyIn(tester, 'block-then[0].repeat.do', 'Again');
    expect(
      find.textContaining('up to 5 times, every 3 s, until between'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine)['then'], [
      {
        'repeat': {
          'do': [
            {
              'notify': {'title': 'Again'},
            },
          ],
          'times': 5,
          'every': 3000,
          'until': [
            {
              'between': ['18:00', '23:30'],
            },
          ],
        },
      },
    ]);
  });

  testWidgets('a together group runs two branches and takes a third', (
    tester,
  ) async {
    await pumpPushed(
      tester,
      engine,
      const RuleEditorPage(
        initial: {
          'name': 'Both',
          'when': [
            {'manual': true},
          ],
          'then': [],
        },
      ),
    );
    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-together');
    for (final b in [0, 1]) {
      await tapIn(tester, 'block-then[0].together[$b]', 'Add step');
      await tapKey(tester, 'pick-notify');
      await tester.enterText(
        find.byKey(const ValueKey('notify-title')),
        'Branch $b',
      );
      await tester.pump();
      await tapKey(tester, 'form-done');
    }
    await tapKey(tester, 'add-branch');
    expect(
      find.text('BRANCH 3 · at the same time as the others'),
      findsOneWidget,
    );
    await tapText(tester, 'Remove branch 3');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine)['then'], [
      {
        'together': [
          [
            {
              'notify': {'title': 'Branch 0'},
            },
          ],
          [
            {
              'notify': {'title': 'Branch 1'},
            },
          ],
        ],
      },
    ]);
  });

  testWidgets('a keep step holds a value while its conditions hold, and a '
      'rule of keeps alone needs no trigger', (tester) async {
    await pumpPushed(
      tester,
      engine,
      const RuleEditorPage(initial: {'name': 'Bulb off while away'}),
    );
    await tapText(tester, 'Add step');
    await tapKey(tester, 'pick-keep');
    expect(find.text('Keep a value'), findsOneWidget);
    expect(buttonEnabled(tester, 'keep-done'), isFalse);
    await tapText(tester, 'Choose what to keep');
    await tapKey(tester, 'pick-keep-hall_bulb');
    await tapKey(tester, 'opt-off-power');
    await tapKey(tester, 'form-done');
    await tapText(tester, 'Add condition');
    await tapKey(tester, 'pick-presence');
    await tapText(tester, 'I am away');
    await tapKey(tester, 'form-done');
    await tapKey(tester, 'keep-done');
    expect(find.text('Keep Hall bulb off while I am away'), findsOneWidget);
    expect(buttonEnabled(tester, 'rule-save'), isTrue);
    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine), {
      'name': 'Bulb off while away',
      'when': [],
      'then': [
        {
          'keep': {
            'target': 'hall_bulb.power',
            'value': false,
            'while': [
              {'state': 'jade.home', 'op': '==', 'value': false},
            ],
          },
        },
      ],
    });
  });

  testWidgets('a new rule named like an existing one asks before replacing '
      'it', (tester) async {
    await pumpPushed(tester, engine, const RuleEditorPage(initial: _arrive));
    await tapKey(tester, 'rule-save');
    expect(find.text('Replace Arrive home?'), findsOneWidget);
    await tapKey(tester, 'confirm-cancel');
    expect(engine.callsOf('automation.save'), isEmpty);
    await tapKey(tester, 'rule-save');
    await tapKey(tester, 'confirm');
    expect(engine.callsOf('automation.save').single.$2['replace'], isTrue);
  });

  testWidgets('Stop at the first failed step sets stopOnError', (tester) async {
    await pumpPushed(
      tester,
      engine,
      RuleEditorPage(initial: {..._arrive, 'name': 'Evening'}),
    );
    await tapKey(tester, 'rule-menu');
    await tapText(tester, 'Stop at the first failed step');
    expect(find.text('Stops at the first step that fails.'), findsOneWidget);
    await tapKey(tester, 'rule-save');
    expect(savedSpec(engine)['stopOnError'], isTrue);
  });

  testWidgets('an agent rule opens with the review banner and saves '
      'untrusted, then opens the review', (tester) async {
    engine.answers['automation.get'] = _stored(_arrive, approved: false);
    engine.answers['automation.save'] = {
      'ok': true,
      'id': 'arrive_home',
      'approved': false,
    };
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    expect(find.byKey(const ValueKey('rule-needs-approval')), findsOneWidget);
    await tapKey(tester, 'rule-save');
    expect(engine.callsOf('automation.save').single.$2['trusted'], isFalse);
    expect(find.byType(ReviewPage), findsOneWidget);
  });

  testWidgets('Remove asks first, and Cancel keeps the rule', (tester) async {
    engine.answers['automation.get'] = _stored(_arrive);
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    await tapKey(tester, 'rule-menu');
    await tapText(tester, 'Remove');
    expect(find.text('Remove Arrive home?'), findsOneWidget);
    await tapKey(tester, 'confirm-cancel');
    expect(engine.callsOf('automation.remove'), isEmpty);
    await tapKey(tester, 'rule-menu');
    await tapText(tester, 'Remove');
    await tapKey(tester, 'confirm');
    expect(engine.callsOf('automation.remove').single.$2, {
      'id': 'arrive_home',
    });
    expect(find.byType(RuleEditorPage), findsNothing);
  });

  testWidgets('leaving with unsaved changes asks first', (tester) async {
    engine.answers['automation.get'] = _stored(_arrive);
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(RuleEditorPage), findsNothing);

    await tapKey(tester, 'open-page');
    await tester.tap(find.byTooltip('Remove Wait 3 s'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tapKey(tester, 'confirm-cancel');
    expect(find.byType(RuleEditorPage), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'confirm');
    expect(find.byType(RuleEditorPage), findsNothing);
    expect(engine.callsOf('automation.save'), isEmpty);
  });

  testWidgets('a rule that does not open says why, with Try again', (
    tester,
  ) async {
    engine.answers['automation.get'] = {
      'ok': false,
      'error': {'type': 'timeout', 'message': 'OmniFlow is busy'},
    };
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    expect(find.byType(OmniErrorState), findsOneWidget);
    engine.answers['automation.get'] = _stored(_arrive);
    await tapText(tester, 'Try again');
    expect(find.text('I get home'), findsOneWidget);
  });

  testWidgets('the editor meets the tap target, label and contrast '
      'guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    engine.answers['automation.get'] = _stored(_arrive);
    await pumpPushed(tester, engine, const RuleEditorPage(id: 'arrive_home'));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });
}
