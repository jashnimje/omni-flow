import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/automation_insights.dart'
    show AutomationInsights;
import 'package:omniflow_app/ui/automations/removed_page.dart' show RemovedPage;
import 'package:omniflow_app/ui/design/design.dart' show OmniRuleBlock;

import 'automations_fixtures.dart';
import 'fake_engine.dart';

/// Design v2: the Automations list as colour
/// cards, and the editor as stacked WHEN, ONLY IF and THEN blocks with
/// everything secondary in collapsed sections.

const _rule = <String, Object?>{
  'name': 'Evening TV',
  'when': [
    {'at': '19:30'},
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
  'id': 'evening_tv',
  'name': spec['name'],
  'source': 'rule',
  'spec': spec,
  'approved': true,
  'revision': 'r1',
  'flow': {'nodes': []},
};

double _top(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(ValueKey(key))).dy;

void main() {
  late FakeEngine engine;

  setUp(() => engine = automationsEngine());

  group('Automations list', () {
    testWidgets('cards sit two to a row, the switch is All, Rules and '
        'Scenes, and Ideas and Recently removed start collapsed at the end', (
      tester,
    ) async {
      await pumpPage(tester, engine, const AutomationsScreen());
      final a = tester.getRect(
        find.byKey(const ValueKey('automation-arrive_home')),
      );
      final b = tester.getRect(
        find.byKey(const ValueKey('automation-bulb_away')),
      );
      expect(a.top, b.top, reason: 'side by side');
      expect(b.left, greaterThan(a.right));
      expect(find.byKey(const ValueKey('automation-filters')), findsOneWidget);
      // Collapsed: the header and its summary show, the content does not.
      expect(find.text('Ideas for you'), findsOneWidget);
      expect(find.text('Recently removed'), findsOneWidget);
      expect(find.byKey(const ValueKey('ideas-templates')), findsNothing);
      expect(
        find.byKey(const ValueKey('automations-removed-open')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('type-it')), findsNothing);
      // They come after every card.
      expect(
        _top(tester, 'automations-ideas'),
        greaterThan(_top(tester, 'scene-movie')),
      );
      expect(
        _top(tester, 'automations-removed'),
        greaterThan(_top(tester, 'automations-ideas')),
      );

      await tapKey(tester, 'automations-ideas');
      expect(find.byKey(const ValueKey('ideas-templates')), findsOneWidget);
      await tapKey(tester, 'automations-removed');
      await tapKey(tester, 'automations-removed-open');
      expect(find.byType(RemovedPage), findsOneWidget);
    });

    testWidgets('a card tap opens the automation, and a scene card has Run', (
      tester,
    ) async {
      engine.answers['automation.get'] = _stored(_rule);
      await pumpPage(tester, engine, const AutomationsScreen());
      await tapKey(tester, 'scene-run-movie');
      expect(engine.callsOf('scene.run').single.$2['id'], 'movie');
      await tapText(tester, 'Arrive home');
      expect(find.byType(RuleEditorPage), findsOneWidget);
    });

    testWidgets('at 200% text the cards stack in one column and nothing '
        'overflows', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(tester, engine, const AutomationsScreen());
      final a = tester.getRect(
        find.byKey(const ValueKey('automation-arrive_home')),
      );
      final b = tester.getRect(
        find.byKey(const ValueKey('automation-bulb_away')),
      );
      expect(b.top, greaterThan(a.bottom - 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('New starts with Type what you want', (tester) async {
      await pumpPage(
        tester,
        engine,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('new'),
                onPressed: () => openNewAutomation(context),
                child: const Text('New'),
              ),
            ),
          ),
        ),
      );
      await tapKey(tester, 'new');
      expect(_top(tester, 'type-it'), lessThan(_top(tester, 'new-blank-rule')));
    });
  });

  group('editor', () {
    testWidgets('the blocks read WHEN then THEN, an empty Only if is not '
        'shown, and Options starts collapsed', (tester) async {
      await pumpPushed(tester, engine, RuleEditorPage(initial: _rule));
      expect(find.byType(OmniRuleBlock), findsNWidgets(2));
      expect(find.byKey(const ValueKey('block-onlyIf')), findsNothing);
      expect(_top(tester, 'block-when'), lessThan(_top(tester, 'block-then')));
      expect(
        _top(tester, 'rule-add-a-step'),
        greaterThan(_top(tester, 'block-then')),
      );
      // No add link on each block: one Add a step does it.
      expect(find.text('Add trigger'), findsNothing);
      expect(find.text('Add step'), findsNothing);
      // Options collapsed: its rows are not built until it opens.
      expect(find.byKey(const ValueKey('rule-options')), findsOneWidget);
      expect(find.byKey(const ValueKey('rule-ask-first')), findsNothing);
      expect(find.byKey(const ValueKey('rule-look')), findsNothing);
      expect(find.byKey(const ValueKey('rule-stop-on-error')), findsNothing);
      await tapKey(tester, 'rule-options');
      for (final k in [
        'rule-ask-first',
        'rule-notify-on-run',
        'rule-look',
        'rule-stop-on-error',
        'rule-diagram-view',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      // The Test run and Save stay at the bottom.
      expect(find.byKey(const ValueKey('rule-test')), findsOneWidget);
      expect(find.byKey(const ValueKey('rule-save')), findsOneWidget);
    });

    testWidgets('Add a step offers Only if, and the block shows between '
        'WHEN and THEN once it has a check', (tester) async {
      await pumpPushed(tester, engine, RuleEditorPage(initial: _rule));
      await tapKey(tester, 'rule-add-a-step');
      expect(find.byKey(const ValueKey('add-part-when')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-part-onlyIf')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-part-then')), findsOneWidget);
      await tapKey(tester, 'add-part-onlyIf');
      await tapKey(tester, 'pick-between');
      await tapKey(tester, 'form-done');
      expect(find.byKey(const ValueKey('block-onlyIf')), findsOneWidget);
      expect(
        _top(tester, 'block-onlyIf'),
        greaterThan(_top(tester, 'block-when')),
      );
      expect(
        _top(tester, 'block-onlyIf'),
        lessThan(_top(tester, 'block-then')),
      );
    });

    testWidgets('a new rule offers one big target in each empty block', (
      tester,
    ) async {
      await pumpPushed(tester, engine, const RuleEditorPage());
      expect(find.text('Choose what starts it'), findsOneWidget);
      expect(find.text('Choose what it does'), findsOneWidget);
      await tapText(tester, 'Choose what starts it');
      await tapKey(tester, 'pick-home');
      await tapKey(tester, 'form-done');
      expect(find.text('I get home'), findsOneWidget);
      expect(find.text('Choose what starts it'), findsNothing);
    });

    testWidgets('a saved rule keeps its runs in a collapsed Activity, and '
        'Duplicate and Runs in the menu', (tester) async {
      engine.answers['automation.get'] = _stored(_rule);
      await pumpPushed(tester, engine, const RuleEditorPage(id: 'evening_tv'));
      expect(find.byKey(const ValueKey('rule-activity')), findsOneWidget);
      expect(find.byType(AutomationInsights), findsNothing);
      await tapKey(tester, 'rule-activity');
      expect(find.byType(AutomationInsights), findsOneWidget);
      await tapKey(tester, 'rule-menu');
      expect(find.byKey(const ValueKey('rule-duplicate')), findsOneWidget);
      expect(find.text('Runs'), findsOneWidget);
    });
  });
}
