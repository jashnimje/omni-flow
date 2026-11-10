import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/automations/automations.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

/// The New button of the Automations tab, outside the shell.
class _WithNew extends StatelessWidget {
  const _WithNew();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: const AutomationsScreen(),
    floatingActionButton: Builder(
      builder: (context) => FloatingActionButton.extended(
        key: const ValueKey('new-rule'),
        onPressed: () => openNewAutomation(context),
        label: const Text('New'),
      ),
    ),
  );
}

void main() {
  late FakeEngine engine;

  setUp(() => engine = automationsEngine());

  testWidgets('each automation shows its sentence, switch and last run, '
      'scenes stay out, and the review waiting is flagged', (tester) async {
    await pumpPage(tester, engine, const AutomationsScreen());
    expect(find.text('Arrive home'), findsOneWidget);
    expect(find.text('When I get home'), findsOneWidget);
    expect(find.text('after 6 pm'), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-movie')), findsNothing);
    expect(find.text('All 5'), findsOneWidget);
    expect(find.text('Needs you 1'), findsOneWidget);
    expect(
      find.text('Claude made "Movie night". Review before it can run.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('last-run-arrive_home')))
          .data,
      startsWith('Ran today'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('last-failed-door_mute')))
          .data,
      'Last run failed: TV asleep',
    );
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('enable-door_mute')))
          .value,
      isFalse,
    );
  });

  testWidgets('the filter chips keep rules, links, the ones off and the ones '
      'that need you', (tester) async {
    await pumpPage(tester, engine, const AutomationsScreen());
    Set<String> shown() => {
      for (final e in find.byType(AutomationCard).evaluate())
        (e.widget as AutomationCard).automation.id,
    };
    await tapKey(tester, 'filter-links');
    expect(shown(), {'desk_button'});
    await tapKey(tester, 'filter-off');
    expect(shown(), {'door_mute'});
    await tapKey(tester, 'filter-needsYou');
    expect(shown(), {'movie_night'});
    await tapKey(tester, 'filter-rules');
    expect(shown(), {'arrive_home', 'bulb_away', 'door_mute', 'movie_night'});
    await tapKey(tester, 'filter-all');
    expect(shown().length, 5);
  });

  testWidgets('search keeps the automations whose name or sentence matches', (
    tester,
  ) async {
    await pumpPage(tester, engine, const AutomationsScreen());
    await tapKey(tester, 'automations-search');
    await tester.enterText(
      find.byKey(const ValueKey('automations-query')),
      'netflix',
    );
    await tester.pumpAndSettle();
    expect(find.byType(AutomationCard), findsOneWidget);
    expect(find.text('Movie night'), findsOneWidget);
  });

  testWidgets('the switch turns an automation on and reloads the list', (
    tester,
  ) async {
    await pumpPage(tester, engine, const AutomationsScreen());
    await tapKey(tester, 'enable-door_mute');
    expect(engine.callsOf('automation.enable').single.$2, {
      'id': 'door_mute',
      'enabled': true,
    });
    expect(engine.callsOf('automation.list').length, 2);
  });

  testWidgets('an automation waiting for review cannot be switched on', (
    tester,
  ) async {
    await pumpPage(tester, engine, const AutomationsScreen());
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('enable-movie_night')))
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('enable-movie_night')))
          .value,
      isFalse,
      reason: 'it is not loaded until approved, so it shows off',
    );
  });

  testWidgets('Retry runs a failed automation again and says how it went', (
    tester,
  ) async {
    engine.answers['automation.run'] = {
      'ok': true,
      'runs': [
        {
          'run': 'r9',
          'flow': 'door_mute',
          'outcome': 'failed',
          'startedAt': DateTime.now().toIso8601String(),
          'nodes': [
            {'node': 'mute', 'type': 'device_toggle', 'error': 'TV asleep'},
          ],
        },
      ],
    };
    await pumpPage(tester, engine, const AutomationsScreen());
    await tapKey(tester, 'retry-door_mute');
    expect(engine.callsOf('automation.run').single.$2, {'id': 'door_mute'});
    expect(
      find.text('Door tag mutes TV failed again: TV asleep'),
      findsOneWidget,
    );
  });

  testWidgets('with no automations it says how to make one', (tester) async {
    engine.answers['automation.list'] = {'ok': true, 'automations': []};
    await pumpPage(tester, engine, const AutomationsScreen());
    expect(find.byKey(const ValueKey('automations-empty')), findsOneWidget);
    expect(find.text('No automations yet'), findsOneWidget);
  });

  testWidgets('while loading it shows the shape of the list', (tester) async {
    engine.delay = const Duration(seconds: 1);
    await pumpPage(tester, engine, const AutomationsScreen());
    expect(find.byKey(const ValueKey('automations-loading')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(AutomationCard), findsWidgets);
  });

  testWidgets('when OmniFlow does not answer it says so, and Try again '
      'loads the list', (tester) async {
    engine.throwOn.add('automation.list');
    await pumpPage(tester, engine, const AutomationsScreen());
    expect(find.byKey(const ValueKey('automations-offline')), findsOneWidget);
    expect(find.textContaining('OmniFlow did not answer'), findsWidgets);
    engine.throwOn.clear();
    await tapText(tester, 'Try again');
    expect(find.byType(AutomationCard), findsNWidgets(5));
  });

  testWidgets('the review banner opens the review', (tester) async {
    engine.answers['automation.get'] = {
      'ok': true,
      'id': 'movie_night',
      'name': 'Movie night',
      'source': 'rule',
      'approved': false,
      'revision': 'r-movie',
      'flow': {'nodes': []},
    };
    await pumpPage(tester, engine, const AutomationsScreen());
    await tapText(tester, 'Review');
    expect(find.byType(ReviewPage), findsOneWidget);
    expect(find.text('Review "Movie night"'), findsOneWidget);
  });

  testWidgets('a card opens a rule in the editor and a link in its runs', (
    tester,
  ) async {
    engine.answerers['automation.get'] = (args) => {
      'ok': true,
      'id': args['id'],
      'name': 'Arrive home',
      'source': 'rule',
      'approved': true,
      'spec': {
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
        ],
      },
    };
    await pumpPage(tester, engine, const AutomationsScreen());
    await tapText(tester, 'Arrive home');
    expect(find.byType(RuleEditorPage), findsOneWidget);
    expect(find.text('I get home'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Desk button');
    expect(find.byType(TestRunPage), findsOneWidget);
    expect(engine.callsOf('automation.dry_run').last.$2, {'id': 'desk_button'});
  });

  testWidgets('removing a link asks first, and Cancel keeps it', (
    tester,
  ) async {
    await pumpPage(tester, engine, const AutomationsScreen());
    await tapText(tester, 'Desk button');
    await tapKey(tester, 'automation-remove');
    expect(find.text('Remove Desk button?'), findsOneWidget);
    await tapKey(tester, 'confirm-cancel');
    expect(engine.callsOf('automation.remove'), isEmpty);
    await tapKey(tester, 'automation-remove');
    await tapKey(tester, 'confirm');
    expect(engine.callsOf('automation.remove').single.$2, {
      'id': 'desk_button',
    });
    expect(find.byType(TestRunPage), findsNothing);
  });

  group('New', () {
    setUp(() {
      engine.answers['automation.templates'] = {
        'ok': true,
        'templates': [
          {
            'id': 'tag_toggle',
            'name': 'Tag toggle',
            'description': 'Scan an NFC tag to switch something on or off.',
            'placeholders': [
              {'key': 'tag', 'label': 'Tag', 'kind': 'tag'},
              {'key': 'target', 'label': 'Switch', 'kind': 'toggle'},
            ],
            'spec': {'name': 'Tag toggle'},
          },
          {
            'id': 'bedtime',
            'name': 'Bedtime',
            'description': 'At bedtime, turn things off.',
            'placeholders': [
              {
                'key': 'time',
                'label': 'At',
                'kind': 'time',
                'default': '23:00',
              },
              {'key': 'things', 'label': 'Turn off', 'kind': 'toggles'},
            ],
            'spec': {'name': 'Bedtime'},
          },
        ],
      };
    });

    testWidgets('offers a rule, a quick link and the templates', (
      tester,
    ) async {
      await pumpPage(tester, engine, const _WithNew());
      await tapKey(tester, 'new-rule');
      expect(find.text('New automation'), findsOneWidget);
      expect(find.text('A rule'), findsOneWidget);
      expect(find.text('A quick link'), findsOneWidget);
      expect(find.text('Tag toggle'), findsOneWidget);
      expect(find.text('Bedtime'), findsOneWidget);
      await tapKey(tester, 'new-blank-rule');
      expect(find.byType(RuleEditorPage), findsOneWidget);
      expect(find.text('New rule'), findsOneWidget);
    });

    testWidgets('a template is filled with picked things and opens in the '
        'editor', (tester) async {
      engine.answerers['automation.templates'] = (args) => args['id'] == null
          ? engine.answers['automation.templates']!
          : {
              'ok': true,
              'templates': [
                {
                  'id': 'tag_toggle',
                  'name': 'Tag toggle',
                  'filled': true,
                  'spec': {
                    'name': 'Tag toggle',
                    'when': [
                      {'on': 'front_door.scanned', 'event': true},
                    ],
                    'then': [
                      {'toggle': 'desk_lamp.power'},
                    ],
                  },
                },
              ],
            };
      await pumpPage(tester, engine, const _WithNew());
      await tapKey(tester, 'new-rule');
      await tapKey(tester, 'template-tag_toggle');
      expect(find.byType(TemplatePage), findsOneWidget);
      await tapKey(tester, 'tpl-tag-front_door');
      await tapKey(tester, 'tpl-target-desk_lamp.power');
      await tapKey(tester, 'template-continue');
      expect(engine.callsOf('automation.templates').last.$2, {
        'id': 'tag_toggle',
        'values': {'tag': 'front_door', 'target': 'desk_lamp.power'},
      });
      expect(find.byType(RuleEditorPage), findsOneWidget);
      expect(find.text('Front door tag is scanned'), findsOneWidget);
      expect(find.text('Toggle Desk lamp'), findsOneWidget);
    });

    testWidgets('a template that needs a tag says so when there is none', (
      tester,
    ) async {
      engine.devices = [FakeEngine.lamp()];
      await pumpPage(tester, engine, const _WithNew());
      await tapKey(tester, 'new-rule');
      await tapKey(tester, 'template-tag_toggle');
      expect(find.byKey(const ValueKey('tpl-missing-tag')), findsOneWidget);
      expect(buttonEnabled(tester, 'template-continue'), isFalse);
    });

    testWidgets('a TV counts as something a template can turn off', (
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
            for (final id in ['wake', 'sleep', 'power'])
              {'id': id, 'type': 'action', 'label': id, 'params': {}},
          ],
        },
      ];
      await pumpPage(tester, engine, const _WithNew());
      await tapKey(tester, 'new-rule');
      await tapKey(tester, 'template-bedtime');
      await tapKey(tester, 'tpl-things-tv.power');
      await tapKey(tester, 'template-continue');
      expect(engine.callsOf('automation.templates').last.$2, {
        'id': 'bedtime',
        'values': {
          'time': '23:00',
          'things': ['tv.power'],
        },
      });
    });

    testWidgets('a quick link is made from the New sheet', (tester) async {
      engine.answerers['link.options'] = (args) => {
        'ok': true,
        'modes': ['toggle', 'follow'],
        'targets': [
          {
            'to': 'hall_bulb.power',
            'modes': ['toggle'],
          },
        ],
      };
      engine.answers['link.create'] = {
        'ok': true,
        'id': 'link_x',
        'name': 'desk_lamp.state toggles hall_bulb.power',
      };
      await pumpPage(tester, engine, const _WithNew());
      await tapKey(tester, 'new-rule');
      await tapKey(tester, 'new-link');
      expect(find.text('Quick link'), findsOneWidget);
      await tapKey(tester, 'link-to');
      await tapText(tester, 'Hall bulb - Power');
      await tapKey(tester, 'link-create');
      expect(engine.callsOf('link.create').single.$2, {
        'from': 'desk_lamp.state',
        'to': 'hall_bulb.power',
        'mode': 'toggle',
        'trusted': true,
      });
      expect(
        find.text('Linked: desk_lamp.state toggles hall_bulb.power'),
        findsOneWidget,
      );
    });
  });

  testWidgets('the list meets the tap target, label and contrast guidelines', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPage(tester, engine, const AutomationsScreen());
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });
}
