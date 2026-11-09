import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/ui/flows_screen.dart';
import 'package:omniflow_app/ui/rule_builder.dart';

import 'fake_engine.dart';
import 'things_fixtures.dart';

/// Opens [dropdown] and picks the item showing [text].
Future<void> pick(WidgetTester tester, String dropdown, String text) async {
  await tester.tap(find.byKey(ValueKey(dropdown)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

Future<void> openNewRule(WidgetTester tester) async {
  await tester.tap(find.text('Flows'));
  await tester.pumpAndSettle();
  await tapKey(tester, 'new-rule');
}

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = FakeEngine();
    engine.devices = [FakeEngine.lamp(), jade, frontDoorTag];
  });

  testWidgets('builds a rule with a trigger, a condition, steps, a wait and '
      'an if, reorders it and saves it as a trusted rule', (tester) async {
    await pumpApp(tester, engine);
    await openNewRule(tester);
    await tester.enterText(find.byKey(const ValueKey('rule-name')), 'Home');

    await tapKey(tester, 'add-when');
    await pick(tester, 'pick-thing', '  Jade');
    await pick(tester, 'pick-key-jade', 'At home');
    await tester.enterText(find.byKey(const ValueKey('trigger-to')), 'true');
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-ok');
    expect(find.text('Jade At home changes to true'), findsOneWidget);

    await tapKey(tester, 'add-only-if');
    await pick(tester, 'condition-kind', 'Between two times');
    await tester.enterText(
      find.byKey(const ValueKey('condition-start')),
      '18:00',
    );
    await tester.enterText(
      find.byKey(const ValueKey('condition-end')),
      '05:00',
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-ok');

    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-action');
    await pick(tester, 'action-thing', '  Desk lamp');
    await pick(tester, 'action-capability-desk_lamp', 'Brightness');
    await tester.enterText(find.byKey(const ValueKey('param-value')), '40');
    await tester.pumpAndSettle();
    await tapKey(tester, 'params-run-Brightness');

    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-wait');
    await tester.enterText(find.byKey(const ValueKey('wait-duration')), '5');
    await pick(tester, 'wait-duration-unit', 'min');
    await tapKey(tester, 'editor-ok');
    expect(find.text('Wait 5 min'), findsOneWidget);

    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-ifElse');
    await tapKey(tester, 'add-step-then.2.then');
    await tapKey(tester, 'step-kind-toggle');
    await pick(tester, 'toggle-thing', '  Desk lamp');
    await pick(tester, 'toggle-capability-desk_lamp', 'Power');
    await tapKey(tester, 'editor-ok');
    expect(find.text('Toggle Desk lamp Power'), findsOneWidget);
    await tapKey(tester, 'add-cond-then.2');
    await pick(tester, 'condition-kind', 'On some days');
    await tapKey(tester, 'day-sat');
    await tapKey(tester, 'editor-ok');
    expect(find.text('On sat'), findsOneWidget);

    await tapKey(tester, 'step-up-then.1');
    await tapKey(tester, 'rule-save');

    final save = engine.callsOf('automation.save').single.$2;
    expect(save, {
      'form': 'rule',
      'trusted': true,
      'spec': {
        'name': 'Home',
        'when': [
          {
            'on': 'jade.home',
            'change': {'to': true},
          },
        ],
        'onlyIf': [
          {
            'between': ['18:00', '05:00'],
          },
        ],
        'then': [
          {'wait': 300000},
          {
            'do': 'desk_lamp.brightness',
            'params': {'value': 40},
          },
          {
            'if': [
              {
                'days': ['sat'],
              },
            ],
            'then': [
              {'toggle': 'desk_lamp.power'},
            ],
          },
        ],
      },
    });
    expect(find.byType(RuleBuilderPage), findsNothing);
    expect(engine.callsOf('flow.list').length, greaterThan(1));
  });

  testWidgets('the add-step picker offers every kind of step', (tester) async {
    await pumpApp(tester, engine);
    await openNewRule(tester);
    await tapKey(tester, 'add-step-then');
    for (final kind in StepKind.values) {
      expect(find.byKey(ValueKey('step-kind-${kind.name}')), findsOneWidget);
    }
    expect(StepKind.values.map((k) => k.name), [
      'action',
      'toggle',
      'wait',
      'waitFor',
      'ifElse',
      'together',
      'setVariable',
      'notify',
      'run',
    ]);
  });

  testWidgets('a tag event starts a rule, and a wait until runs its own '
      'steps when the time runs out', (tester) async {
    await pumpApp(tester, engine);
    await openNewRule(tester);
    await tester.enterText(find.byKey(const ValueKey('rule-name')), 'Door');

    await tapKey(tester, 'add-when');
    await pick(tester, 'trigger-kind', 'A thing does something');
    await pick(tester, 'pick-thing', '  Front door tag');
    await pick(tester, 'pick-key-front_door-event', 'Scanned');
    await tapKey(tester, 'editor-ok');
    expect(find.text('Front door tag Scanned happens'), findsOneWidget);

    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-waitFor');
    await pick(tester, 'pick-thing', '  Jade');
    await pick(tester, 'pick-key-jade', 'At home');
    await tester.enterText(find.byKey(const ValueKey('trigger-to')), 'false');
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-ok');
    await tester.enterText(
      find.byKey(const ValueKey('wait-for-timeout')),
      '10',
    );
    await pick(tester, 'wait-for-timeout-unit', 'min');
    await tapKey(tester, 'editor-ok');
    expect(
      find.text('Wait until Jade At home changes to false, at most 10 min'),
      findsOneWidget,
    );
    await tapKey(tester, 'add-step-then.0.timeout');
    await tapKey(tester, 'step-kind-notify');
    await tester.enterText(
      find.byKey(const ValueKey('notify-title')),
      'Still out',
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-ok');

    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-notify');
    await tester.enterText(find.byKey(const ValueKey('notify-title')), 'Door');
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-ok');

    await tapKey(tester, 'rule-save');
    final spec = engine.callsOf('automation.save').single.$2['spec'] as Map;
    expect(spec['when'], [
      {'on': 'front_door.scanned', 'event': true},
    ]);
    expect(spec['then'], [
      {
        'waitFor': {
          'on': 'jade.home',
          'change': {'to': false},
          'timeoutMs': 600000,
          'onTimeout': [
            {
              'notify': {'title': 'Still out'},
            },
          ],
        },
      },
      {
        'notify': {'title': 'Door'},
      },
    ]);
  });

  testWidgets('Test run sends the rule to the dry run and shows what ran', (
    tester,
  ) async {
    engine.answers['automation.dry_run'] = {
      'ok': true,
      'run': {
        'run': 'morning-1',
        'dryRun': true,
        'outcome': 'failed',
        'nodes': [
          {'node': 'when_0', 'label': 'At 07:30', 'port': 'out'},
          {'node': 'then_0', 'error': 'desk_lamp did not answer'},
        ],
      },
    };
    await pumpApp(tester, engine);
    await openNewRule(tester);
    await tapKey(tester, 'add-when');
    await pick(tester, 'trigger-kind', 'At a time of day');
    await tester.enterText(find.byKey(const ValueKey('trigger-time')), '07:30');
    await tester.pumpAndSettle();
    await tapKey(tester, 'day-sat');
    await tapKey(tester, 'editor-ok');
    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-notify');
    await tester.enterText(
      find.byKey(const ValueKey('notify-title')),
      'Morning',
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-ok');

    await tapKey(tester, 'rule-test');

    expect(engine.callsOf('automation.dry_run').single.$2, {
      'form': 'rule',
      'spec': {
        'name': '',
        'when': [
          {
            'time': '07:30',
            'days': ['sat'],
          },
        ],
        'then': [
          {
            'notify': {'title': 'Morning'},
          },
        ],
      },
    });
    final shown = tester
        .widget<Text>(find.byKey(const ValueKey('dry-run-result')))
        .data!;
    expect(shown, contains('Outcome: failed'));
    expect(shown, contains('then_0: desk_lamp did not answer'));
    expect(shown, contains('At 07:30 -> out'));
    expect(engine.callsOf('automation.save'), isEmpty);
  });

  testWidgets('a rule the engine refuses shows each issue in the test run', (
    tester,
  ) async {
    engine.answers['automation.dry_run'] = {
      'ok': false,
      'error': {
        'type': 'invalid',
        'message': 'the rule is not valid',
        'issues': [
          {'path': 'then[0].do', 'message': 'no thing hall_lamp'},
        ],
      },
    };
    await pumpApp(tester, engine);
    await openNewRule(tester);
    await tapKey(tester, 'add-when');
    await pick(tester, 'trigger-kind', 'Every so often');
    await tester.enterText(find.byKey(const ValueKey('trigger-every')), '30');
    await pick(tester, 'trigger-every-unit', 's');
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-ok');
    expect(find.text('Every 30 s'), findsOneWidget);
    await tapKey(tester, 'rule-test');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('dry-run-result'))).data,
      'the rule is not valid\nthen[0].do: no thing hall_lamp',
    );
  });

  testWidgets('a new rule named like an existing rule asks before replacing '
      'it', (tester) async {
    engine.answers['flow.list'] = {
      'ok': true,
      'flows': [
        {
          'id': 'evening',
          'name': 'Evening',
          'source': 'rule',
          'enabled': true,
          'approved': true,
          'loaded': true,
        },
      ],
    };
    await pumpApp(tester, engine);
    await openNewRule(tester);
    await tester.enterText(find.byKey(const ValueKey('rule-name')), 'Evening');
    await tapKey(tester, 'add-when');
    await pick(tester, 'trigger-kind', 'Only when run by hand');
    await tapKey(tester, 'editor-ok');
    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-wait');
    await tapKey(tester, 'editor-ok');

    await tapKey(tester, 'rule-save');
    expect(find.text('Replace Evening?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.callsOf('automation.save'), isEmpty);
    expect(find.byType(RuleBuilderPage), findsOneWidget);

    await tapKey(tester, 'rule-save');
    await tapKey(tester, 'confirm');
    final save = engine.callsOf('automation.save').single.$2;
    expect((save['trusted'], save['replace']), (true, true));
  });

  testWidgets('an empty If or Do together branch is marked and keeps Save '
      'off', (tester) async {
    await pumpApp(tester, engine);
    await openNewRule(tester);
    await tester.enterText(find.byKey(const ValueKey('rule-name')), 'Branchy');
    await tapKey(tester, 'add-when');
    await pick(tester, 'trigger-kind', 'Only when run by hand');
    await tapKey(tester, 'editor-ok');
    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-ifElse');
    bool saveOn() =>
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('rule-save')))
            .onPressed !=
        null;

    expect(find.byKey(const ValueKey('missing-cond-then.0')), findsOneWidget);
    expect(find.byKey(const ValueKey('missing-then-then.0')), findsOneWidget);
    expect(saveOn(), isFalse);

    await tapKey(tester, 'add-cond-then.0');
    await pick(tester, 'condition-kind', 'On some days');
    await tapKey(tester, 'day-sat');
    await tapKey(tester, 'editor-ok');
    expect(saveOn(), isFalse);
    await tapKey(tester, 'add-step-then.0.then');
    await tapKey(tester, 'step-kind-wait');
    await tapKey(tester, 'editor-ok');
    expect(find.byKey(const ValueKey('missing-cond-then.0')), findsNothing);
    expect(saveOn(), isTrue);

    await tapKey(tester, 'add-step-then');
    await tapKey(tester, 'step-kind-together');
    expect(
      find.byKey(const ValueKey('missing-branch-then.1.0')),
      findsOneWidget,
    );
    expect(saveOn(), isFalse);
  });

  test('a rule is complete only when every If and branch is filled', () {
    RuleSpec rule(List<RuleStep> then) =>
        RuleSpec(name: 'r', when: [ManualTrigger()], then: then);
    expect(rule([WaitStep(1)]).complete, isTrue);
    expect(rule([]).complete, isFalse);
    expect(
      rule([
        IfStep(then: [WaitStep(1)]),
      ]).complete,
      isFalse,
    );
    expect(
      rule([
        IfStep(
          conditions: [
            DaysCondition(['sat']),
          ],
          then: [],
        ),
      ]).complete,
      isFalse,
    );
    expect(
      rule([
        IfStep(
          conditions: [
            DaysCondition(['sat']),
          ],
          then: [WaitStep(1)],
          otherwise: [TogetherStep()],
        ),
      ]).complete,
      isFalse,
    );
    expect(
      rule([
        TogetherStep([
          [WaitStep(1)],
          [WaitStep(2)],
        ]),
      ]).complete,
      isTrue,
    );
  });

  testWidgets('a Notify step that runs shows on the phone while the app is '
      'open', (tester) async {
    await pumpApp(tester, engine);
    engine.eventsOut.add({
      'event': 'flow.announce',
      'type': 'notify',
      'title': 'Door opened',
      'body': 'Front door',
    });
    await tester.pumpAndSettle();
    expect(find.text('Door opened: Front door'), findsOneWidget);
  });

  group('a stored rule', () {
    final stored = <String, Object?>{
      'id': 'arrive',
      'name': 'Arrive',
      'mode': 'restart',
      'when': [
        {'on': 'front_door.scanned', 'event': true},
      ],
      'onlyIf': [
        {'state': 'jade.home', 'op': '==', 'value': false},
        {
          'days': ['mon', 'tue'],
        },
        {
          'anyOf': [
            {r'var': r'$Guests', 'op': '==', 'value': true},
          ],
        },
      ],
      'then': [
        {
          'together': [
            [
              {
                'notify': {'title': 'Welcome', 'body': 'Lights on', 'tag': 1},
              },
            ],
            [
              {'toggle': 'desk_lamp.power'},
            ],
          ],
        },
        {
          'set': {'var': r'$Away', 'value': false},
        },
        {'run': 'evening'},
        {'future_step': 1},
      ],
    };

    setUp(() {
      engine.answers['flow.list'] = {
        'ok': true,
        'flows': [
          {
            'id': 'arrive',
            'name': 'Arrive',
            'source': 'rule',
            'enabled': true,
            'approved': true,
            'loaded': true,
          },
          {
            'id': 'evening',
            'name': 'Evening desk',
            'enabled': true,
            'approved': true,
            'loaded': true,
          },
          {
            'id': 'link_1a2b',
            'name': 'Button to lamp',
            'source': 'link',
            'enabled': true,
            'approved': true,
            'loaded': true,
          },
        ],
      };
      engine.answers['automation.get'] = {
        'ok': true,
        'id': 'arrive',
        'name': 'Arrive',
        'source': 'rule',
        'spec': stored,
        'approved': true,
        'highRisk': false,
        'revision': 'r1',
      };
    });

    testWidgets('an agent-written rule waiting for approval is saved '
        'untrusted, and saving opens its review instead of approving it', (
      tester,
    ) async {
      engine.answers['automation.get'] = {
        ...engine.answers['automation.get']!,
        'approved': false,
        'highRisk': true,
      };
      engine.answers['automation.save'] = {
        'ok': true,
        'id': 'arrive',
        'source': 'rule',
        'approved': false,
        'highRisk': true,
        'revision': 'r2',
      };
      engine.answers['flow.get'] = {
        'ok': true,
        'id': 'arrive',
        'revision': 'r2',
        'flow': {'nodes': <Object?>[]},
      };
      await pumpApp(tester, engine);
      await tester.tap(find.text('Flows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrive'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rule-needs-approval')), findsOneWidget);
      expect(
        find.textContaining('runs commands on a computer'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('rule-name')),
        'Arrive home',
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'rule-save');

      final save = engine.callsOf('automation.save').single.$2;
      expect(save['trusted'], false);
      expect(save['id'], 'arrive');
      expect(save['replace'], true);
      expect(engine.callsOf('flow.approve'), isEmpty);
      expect(engine.callsOf('automation.approve'), isEmpty);
      expect(find.byType(ApprovalPage), findsOneWidget);

      await tapKey(tester, 'approve');
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('flow.approve').single.$2, {
        'id': 'arrive',
        'revision': 'r2',
      });
    });

    testWidgets('reopens as written and saves back under its id', (
      tester,
    ) async {
      await pumpApp(tester, engine);
      await tester.tap(find.text('Flows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrive'));
      await tester.pumpAndSettle();

      expect(engine.callsOf('automation.get').single.$2, {'id': 'arrive'});
      expect(find.text('Edit rule'), findsOneWidget);
      expect(find.text('Front door tag Scanned happens'), findsOneWidget);
      expect(find.text('Jade At home == false'), findsOneWidget);
      expect(find.text('On mon, tue'), findsOneWidget);
      expect(find.text('Do together'), findsOneWidget);
      expect(find.text('Notify: Welcome'), findsOneWidget);
      expect(find.text('Toggle Desk lamp Power'), findsOneWidget);
      expect(
        find.text('A condition this app cannot edit: anyOf'),
        findsOneWidget,
      );
      expect(find.text(r'Set $Away to false'), findsOneWidget);
      expect(find.text('Run Evening desk'), findsOneWidget);
      expect(
        find.text('A step this app cannot edit: future_step'),
        findsOneWidget,
      );

      await tapKey(tester, 'add-branch-then.0');
      await tapKey(tester, 'remove-branch-then.0.2');
      await tapKey(tester, 'rule-save');

      final save = engine.callsOf('automation.save').single.$2;
      expect(save['id'], 'arrive');
      expect(save['trusted'], true);
      expect(save['replace'], true, reason: 'it saves over the rule it opened');
      expect(save['spec'], stored);
    });

    testWidgets('a link opens its card view, not the rule builder', (
      tester,
    ) async {
      await pumpApp(tester, engine);
      await tester.tap(find.text('Flows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Button to lamp'));
      await tester.pumpAndSettle();

      expect(engine.callsOf('flow.cards').single.$2, {'id': 'link_1a2b'});
      expect(engine.callsOf('automation.get'), isEmpty);
    });

    testWidgets('a reopened automation that is not a rule says so', (
      tester,
    ) async {
      engine.answers['automation.get'] = {
        'ok': true,
        'id': 'arrive',
        'source': 'graph',
        'spec': <String, Object?>{},
      };
      await pumpApp(tester, engine);
      await tester.tap(find.text('Flows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrive'));
      await tester.pumpAndSettle();
      expect(
        find.text('This automation is a graph, not a rule.'),
        findsOneWidget,
      );
    });
  });

  test('every step, trigger and condition survives a JSON round trip', () {
    final json = {
      'id': 'all',
      'name': 'All',
      'cooldownSeconds': 30,
      'when': [
        {
          'on': 'room.temp',
          'crosses': {'above': 28},
        },
        {
          'on': 'room.temp',
          'crosses': {'below': 18},
        },
        {
          'on': 'board.button.pressed',
          'event': true,
          'match': {'hold': true},
        },
        {'on': 'lamp.power', 'change': <String, Object?>{}},
        {'interval': 60},
        {'manual': true},
        {'time': '07:00'},
      ],
      'onlyIf': [
        {'var': r'$Mode', 'op': '!=', 'value': 'away'},
        {
          'msg': 'value',
          'op': '>',
          'value': {'state': 'room.target'},
        },
        {
          'not': {
            'days': ['sun'],
          },
        },
      ],
      'then': [
        {
          'do': 'tv.launch_app',
          'params': {'app': 'netflix'},
        },
        {'do': 'tv.wake'},
        {'toggle': 'lamp.power'},
        {'wait': 1500},
        {
          'waitFor': {
            'on': 'door.open',
            'change': {'to': null},
            'timeoutMs': 30000,
          },
        },
        {
          'if': [
            {
              'between': ['22:00', '06:00'],
            },
          ],
          'then': [
            {
              'notify': {'title': 'Late'},
            },
          ],
          'else': [
            {'run': 'other'},
          ],
        },
      ],
    };
    expect(RuleSpec.fromJson(json).toJson(), json);
  });
}
