import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/rule_words.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show normalizeRule;

import 'automations_fixtures.dart';
import 'fake_engine.dart';

/// Held state triggers, the household as one, aligned times and the
/// engine starting in the editor, and on an automation's page why it did
/// not run, its clashes, its history with Restore, and Try as if.
const _held = <String, Object?>{
  'name': 'Lamp left on',
  'when': [
    {
      'on': 'desk_lamp.state',
      'change': {'to': true},
      'for': 300000,
    },
  ],
  'then': [
    {
      'notify': {'title': 'The lamp is still on'},
    },
  ],
};

Map<String, Object?> _stored(Map<String, Object?> spec) => {
  'ok': true,
  'id': 'lamp_left_on',
  'name': spec['name'],
  'source': 'rule',
  'spec': spec,
  'approved': true,
  'revision': 'r1',
  'flow': {'nodes': []},
};

void main() {
  test('the builder writes the engine\'s stored form for the new shapes', () {
    final spec = RuleSpec(
      name: 'Everyone',
      when: [
        OnTrigger(
          thing: 'lamp',
          key: 'power',
          to: true,
          hasTo: true,
          forMs: 300000,
        ),
        OnTrigger(
          thing: 'room',
          key: 'temp',
          mode: OnMode.crosses,
          above: 28,
          forMs: 60000,
        ),
        PeopleTrigger(PeopleTrigger.firstArrives),
        const EngineStartTrigger(),
        IntervalTrigger(3600, offsetSeconds: 300),
        IntervalTrigger(900, between: ['09:00', '18:00']),
      ],
      onlyIf: [PeopleCondition(PeopleCondition.allAway)],
      then: [NotifyStep('hi')],
    ).toJson();
    final stored = normalizeRule(spec);
    expect({...stored}..remove('id'), spec);
    expect(RuleSpec.fromJson(stored).toJson(), stored);
    // Any change has no state to hold, so it keeps no for.
    expect(
      OnTrigger(thing: 'lamp', key: 'power', forMs: 1000).toJson(),
      isNot(contains('for')),
    );
  });

  test('plain words for each', () {
    final words = RuleWords(const []);
    expect(
      words.trigger(PeopleTrigger(PeopleTrigger.lastLeaves)),
      'The last person leaves',
    );
    expect(words.trigger(const EngineStartTrigger()), 'When OmniFlow starts');
    expect(
      words.trigger(IntervalTrigger(3600, offsetSeconds: 300)),
      'Every hour at :05',
    );
    expect(
      words.trigger(IntervalTrigger(900, between: ['09:00', '18:00'])),
      'Every 15 min from 09:00 to 18:00',
    );
    expect(
      words.trigger(
        OnTrigger(
          thing: 'front_door',
          key: 'open',
          to: true,
          hasTo: true,
          forMs: 300000,
        ),
      ),
      'front_door has been on for 5 min',
    );
    expect(
      words.condition(PeopleCondition(PeopleCondition.anyoneHome)),
      'Anyone is home',
    );
  });

  group('editor', () {
    late FakeEngine engine;

    setUp(() => engine = automationsEngine());

    testWidgets('a state trigger can wait for the state to hold', (
      tester,
    ) async {
      await pumpPushed(tester, engine, const RuleEditorPage());
      await tapText(tester, 'Add trigger');
      await tapKey(tester, 'pick-thing-desk_lamp');
      await tapKey(tester, 'opt-on-state');
      expect(find.text('Right away'), findsOneWidget);
      await tapText(tester, 'Once it stays');
      expect(find.byKey(const ValueKey('hold-for')), findsOneWidget);
      await tapKey(tester, 'form-done');
      expect(find.text('Desk lamp has been on for 5 min'), findsOneWidget);
    });

    testWidgets('the people triggers, engine start and an aligned interval '
        'come from the library', (tester) async {
      await pumpPushed(tester, engine, const RuleEditorPage());
      await tapText(tester, 'Add trigger');
      await tapKey(tester, 'pick-people');
      await tapKey(tester, 'people-last_leaves');
      await tapKey(tester, 'form-done');
      expect(find.text('The last person leaves'), findsOneWidget);

      await tapText(tester, 'Add trigger');
      await tapKey(tester, 'pick-engine-start');
      expect(find.text('When OmniFlow starts'), findsOneWidget);

      await tapText(tester, 'Add trigger');
      await tapKey(tester, 'pick-interval');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('interval-offset')),
          matching: find.byType(TextField),
        ),
        '5',
      );
      await tester.pump();
      await tapText(tester, 'Between two times');
      await tapKey(tester, 'form-done');
      expect(
        find.text(
          'Every 10 min at :05, :15, :25, :35, :45 and :55 from '
          '09:00 to 18:00',
        ),
        findsOneWidget,
      );

      await tapText(tester, 'Add condition');
      await tapKey(tester, 'pick-people');
      await tapKey(tester, 'form-done');
      expect(find.text('Everyone is away'), findsOneWidget);
    });

    testWidgets('Try as if runs the dry run from that trigger with a '
        'made-up event', (tester) async {
      engine.answers['automation.get'] = _stored(_held);
      engine.answers['automation.dry_run'] = {
        'ok': true,
        'run': {
          'run': 'dry-1',
          'flow': 'lamp_left_on',
          'trigger': 'when_0',
          'dryRun': true,
          'outcome': 'completed',
          'startedAt': DateTime.now().toUtc().toIso8601String(),
          'nodes': [
            {
              'node': 'when_0',
              'type': 'on',
              'label': 'Desk lamp has been on for 5 min',
              'port': 'out',
              'input': <String, Object?>{},
            },
            {
              'node': 'then_0',
              'type': 'notify',
              'label': 'notify "The lamp is still on"',
              'port': 'out',
              'input': <String, Object?>{},
            },
          ],
        },
      };
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(id: 'lamp_left_on'),
      );
      expect(find.text('Desk lamp has been on for 5 min'), findsOneWidget);
      await tapKey(tester, 'try-as-if-0');
      final call = engine.callsOf('automation.dry_run').single.$2;
      expect(call['trigger'], 'when_0');
      expect(call['msg'], containsPair('value', true));
      expect(call['msg'], containsPair('heldMs', 300000));
      expect(find.byType(TestRunPage), findsOneWidget);
    });
  });

  group('the automation page', () {
    late FakeEngine engine;

    setUp(() {
      engine = automationsEngine(
        automations: [
          {
            ...automationRows().first,
            'id': 'lamp_left_on',
            'name': 'Lamp left on',
            'conflicts': [
              'Lamp left on sets Desk lamp on and Night sets Desk lamp off, '
                  'both when Desk lamp turns on',
            ],
          },
        ],
      );
      engine.answers['automation.get'] = _stored(_held);
    });

    testWidgets('says why it did not run, or that nothing was stopped', (
      tester,
    ) async {
      engine.answers['automation.skips'] = {
        'ok': true,
        'skips': [
          {
            'at': DateTime.now().toUtc().toIso8601String(),
            'kind': 'condition',
            'text':
                'Front door turns on, but it was not between 18:00 and 23:00',
          },
        ],
      };
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(id: 'lamp_left_on'),
      );
      await tester.scrollUntilVisible(
        find.text('Why didn\'t it run?'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(
          'Front door turns on, but it was not between 18:00 and 23:00',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('skips-none')), findsNothing);
      expect(
        find.textContaining('This clashes with another automation.'),
        findsOneWidget,
      );
    });

    testWidgets('nothing stopped, and no history yet', (tester) async {
      engine.answers['automation.skips'] = {'ok': true, 'skips': []};
      engine.answers['automation.versions'] = {'ok': true, 'versions': []};
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(id: 'lamp_left_on'),
      );
      expect(find.byKey(const ValueKey('skips-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('versions-none')), findsOneWidget);
    });

    testWidgets('History lists the earlier versions and Restore brings one '
        'back after asking', (tester) async {
      engine.answers['automation.versions'] = {
        'ok': true,
        'versions': [
          {
            'id': 'lamp_left_on',
            'version': 3,
            'at': DateTime.now().toUtc().toIso8601String(),
            'form': 'rule',
            'source': 'agent',
            'name': 'Lamp left on',
            'sentence': [part('when', 'When Desk lamp turns on')],
          },
        ],
      };
      engine.answers['automation.restore'] = {
        'ok': true,
        'id': 'lamp_left_on',
        'approved': false,
        'restored': 3,
      };
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(id: 'lamp_left_on'),
      );
      expect(find.textContaining('made by an agent'), findsOneWidget);
      await tapKey(tester, 'restore-3');
      expect(find.text('Go back to this version?'), findsOneWidget);
      await tapKey(tester, 'confirm');
      final call = engine.callsOf('automation.restore').single.$2;
      expect(call, {'id': 'lamp_left_on', 'version': 3, 'trusted': true});
      expect(
        find.text('Restored. It runs once you approve it'),
        findsOneWidget,
      );
    });

    testWidgets('the card shows a clash warning', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPage(tester, engine, const AutomationsScreen());
      expect(
        find.byKey(const ValueKey('conflict-lamp_left_on')),
        findsOneWidget,
      );
      expect(find.text('Clashes with another automation'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp('Clashes with another automation: Lamp left on sets'),
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}
