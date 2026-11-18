import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/suggestion_calls.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/suggestions_page.dart';
import 'package:omniflow_app/ui/automations/type_it_page.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/home/suggestion_card.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

/// Suggestions from habits on Home and in Automations, and Type what you
/// want, against canned engine answers.

const _lampOn = {
  'name': 'Turn on Lamp at 19:05',
  'when': [
    {
      'time': '19:05',
      'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
    },
  ],
  'then': [
    {
      'do': 'lamp.power',
      'params': {'value': true},
    },
  ],
};

Map<String, Object?> suggestion(String id, String words) => {
  'id': id,
  'kind': 'time',
  'words': words,
  'confidence': 0.9,
  'count': 12,
  'thing': 'lamp',
  'spec': _lampOn,
  'sentence': [
    {'kind': 'when', 'text': 'At 19:05 on mon, tue, wed, thu, fri'},
    {'kind': 'text', 'text': '→'},
    {'kind': 'then', 'text': 'Lamp power on'},
  ],
};

/// [engine] offering [rows], and putting one away when it is dismissed.
void offer(FakeEngine engine, List<Map<String, Object?>> rows) {
  final shown = [...rows];
  engine.answerers['suggest.list'] = (_) => {
    'ok': true,
    'suggestions': [...shown],
  };
  engine.answerers['suggest.dismiss'] = (args) {
    shown.removeWhere((s) => s['id'] == args['id']);
    return {'ok': true, 'id': args['id'], 'dismissed': true};
  };
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: ListView(children: const [SuggestionCard()]));
}

/// Home has loaded the suggestions, as it has in the app by the time the
/// Automations tab opens.
class _HomeThenAutomations extends StatelessWidget {
  const _HomeThenAutomations();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Column(
      children: [
        SuggestionCard(),
        Expanded(child: AutomationsScreen()),
      ],
    ),
  );
}

/// A button that opens Type what you want, as the Automations row does.
class _TypeIt extends StatelessWidget {
  const _TypeIt();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('open-type-it'),
        onPressed: () => openTypeIt(context),
        child: const Text('Open'),
      ),
    ),
  );
}

void main() {
  group('suggestions', () {
    testWidgets('Home asks to make the best one automatic, and Not now puts '
        'it away', (tester) async {
      final engine = FakeEngine();
      offer(engine, [
        suggestion(
          'sg_aaaaaaaaaaaa',
          'You turn on Lamp around 19:05 most weekdays',
        ),
        suggestion(
          'sg_bbbbbbbbbbbb',
          'You turn off Lamp around 23:30 most days',
        ),
      ]);
      await pumpPage(tester, engine, const _Home());
      expect(find.text('Make it automatic?'), findsOneWidget);
      expect(
        find.text('You turn on Lamp around 19:05 most weekdays'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('suggestion-not-now-sg_aaaaaaaaaaaa')),
      );
      await tester.pumpAndSettle();
      expect(engine.callsOf('suggest.dismiss').single.$2, {
        'id': 'sg_aaaaaaaaaaaa',
      });
      expect(
        find.text('You turn off Lamp around 23:30 most days'),
        findsOneWidget,
      );
    });

    testWidgets('nothing shows when the engine has nothing to offer', (
      tester,
    ) async {
      await pumpPage(tester, FakeEngine(), const _Home());
      expect(find.byKey(const ValueKey('suggestion-card')), findsNothing);
    });

    testWidgets('Make it opens the rule in the editor, unsaved', (
      tester,
    ) async {
      final engine = FakeEngine();
      offer(engine, [
        suggestion(
          'sg_aaaaaaaaaaaa',
          'You turn on Lamp around 19:05 most weekdays',
        ),
      ]);
      await pumpPage(tester, engine, const _Home());
      await tester.tap(
        find.byKey(const ValueKey('suggestion-make-sg_aaaaaaaaaaaa')),
      );
      await tester.pumpAndSettle();
      final editor = tester.widget<RuleEditorPage>(find.byType(RuleEditorPage));
      expect(editor.initial, _lampOn);
      expect(editor.id, isNull);
      expect(engine.callsOf('automation.save'), isEmpty);
    });

    testWidgets('Automations keeps the suggestions in Ideas for you, and '
        'Type what you want in New', (tester) async {
      final engine = automationsEngine();
      offer(engine, [
        suggestion(
          'sg_aaaaaaaaaaaa',
          'You turn on Lamp around 19:05 most weekdays',
        ),
        suggestion(
          'sg_bbbbbbbbbbbb',
          'You turn off Lamp around 23:30 most days',
        ),
      ]);
      await pumpPage(tester, engine, const _HomeThenAutomations());
      expect(find.byKey(const ValueKey('type-it')), findsNothing);
      expect(find.text('2 automations you could add'), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestions-row')), findsNothing);
      await tapKey(tester, 'automations-ideas');
      expect(find.byKey(const ValueKey('suggestions-row')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('suggestions-row')));
      await tester.pumpAndSettle();
      expect(find.byType(SuggestionsPage), findsOneWidget);
      expect(find.text('Make it'), findsNWidgets(2));
    });

    testWidgets('with no suggestions Ideas for you offers the templates', (
      tester,
    ) async {
      await pumpPage(tester, automationsEngine(), const AutomationsScreen());
      await tapKey(tester, 'automations-ideas');
      expect(find.byKey(const ValueKey('ideas-templates')), findsOneWidget);
      expect(find.byKey(const ValueKey('suggestions-row')), findsNothing);
      expect(find.byType(AutomationHelpers), findsOneWidget);
    });
  });

  group('Type what you want', () {
    const spec = {
      'name': 'Turn off the lights when I leave',
      'when': [
        {
          'on': 'jade.home',
          'change': {'to': false},
        },
      ],
      'then': [
        {
          'do': 'lamp.power',
          'params': {'value': false},
        },
      ],
    };

    FakeEngine reader() {
      final engine = FakeEngine();
      engine.answerers['rule.parse'] = (args) {
        final text = '${args['text']}'.toLowerCase();
        if (text.contains('sauna')) {
          return {
            'ok': true,
            'spec': null,
            'sentence': <Object?>[],
            'unknown': ['sauna'],
            'problem': 'I do not know a device or room called "sauna"',
          };
        }
        return {
          'ok': true,
          'spec': spec,
          'sentence': [
            {'kind': 'when', 'text': 'When I leave'},
            {'kind': 'text', 'text': '→'},
            {'kind': 'then', 'text': 'Lamp power off'},
          ],
          'unknown': text.contains('quickly') ? ['quickly'] : <String>[],
          if (text.contains('lamp'))
            'alternatives': [
              {
                'text': 'lamp',
                'chosen': {'id': 'lamp', 'name': 'Lamp'},
                'options': [
                  {'id': 'floor', 'name': 'Floor lamp'},
                ],
              },
            ],
        };
      };
      return engine;
    }

    Future<void> open(WidgetTester tester, FakeEngine engine) async {
      await pumpPage(tester, engine, const _TypeIt());
      await tester.tap(find.byKey(const ValueKey('open-type-it')));
      await tester.pumpAndSettle();
    }

    testWidgets('reads the sentence once typing pauses, and opens it in the '
        'editor', (tester) async {
      final engine = reader();
      await open(tester, engine);
      expect(
        tester
            .widget<OmniButton>(find.byKey(const ValueKey('type-it-open')))
            .onPressed,
        isNull,
      );
      final field = find.byKey(const ValueKey('type-it-field'));
      await tester.enterText(field, 'turn off');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, 'turn off the lights when I leave');
      expect(find.byKey(const ValueKey('type-it-reading')), findsOneWidget);
      await tester.pump(typeItDebounce);
      await tester.pumpAndSettle();
      // One read for the whole burst of typing.
      expect(engine.callsOf('rule.parse').single.$2, {
        'text': 'turn off the lights when I leave',
      });
      expect(find.text('When I leave'), findsOneWidget);
      expect(find.text('Lamp power off'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('type-it-open')));
      await tester.pumpAndSettle();
      final editor = tester.widget<RuleEditorPage>(find.byType(RuleEditorPage));
      expect(editor.initial, spec);
      expect(engine.callsOf('automation.save'), isEmpty);
    });

    testWidgets('marks the words it could not place, and names the choice it '
        'made', (tester) async {
      await open(tester, reader());
      await tester.enterText(
        find.byKey(const ValueKey('type-it-field')),
        'turn off the lamp quickly when I leave',
      );
      await tester.pump(typeItDebounce);
      await tester.pumpAndSettle();
      final unknown = find.byKey(const ValueKey('type-it-unknown'));
      expect(unknown, findsOneWidget);
      expect(
        tester.getSemantics(find.byType(UnknownWords)).label,
        'Not understood: quickly',
      );
      expect(
        find.textContaining('"lamp" is Lamp. It could also be Floor lamp'),
        findsOneWidget,
      );
    });

    testWidgets('says plainly why it cannot make a rule, and Open in editor '
        'stays off', (tester) async {
      await open(tester, reader());
      await tester.enterText(
        find.byKey(const ValueKey('type-it-field')),
        'when I leave turn off the sauna',
      );
      await tester.pump(typeItDebounce);
      await tester.pumpAndSettle();
      expect(
        find.text('I do not know a device or room called "sauna"'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OmniButton>(find.byKey(const ValueKey('type-it-open')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('an example fills the field and is read', (tester) async {
      final engine = reader();
      await open(tester, engine);
      await tester.tap(find.text('Turn off the lights when I leave'));
      await tester.pump(typeItDebounce);
      await tester.pumpAndSettle();
      expect(engine.callsOf('rule.parse'), hasLength(1));
      expect(find.text('When I leave'), findsOneWidget);
    });

    testWidgets('an engine that does not answer says so', (tester) async {
      final engine = reader()..throwOn.add('rule.parse');
      await open(tester, engine);
      await tester.enterText(
        find.byKey(const ValueKey('type-it-field')),
        'turn off the lights when I leave',
      );
      await tester.pump(typeItDebounce);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('type-it-silent')), findsOneWidget);
    });
  });

  test('every rule the reader writes for the brief opens in the editor as '
      'it is', () {
    // The specs rule.parse returns for the sentences of the feature brief,
    // as the engine's own tests pin them.
    final specs = <Map<String, Object?>>[
      {
        'name': 'At 7 every weekday turn on the kettle plug',
        'when': [
          {
            'time': '07:00',
            'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
          },
        ],
        'then': [
          {
            'do': 'kettle_plug.power',
            'params': {'value': true},
          },
        ],
      },
      {
        'name': 'When the front door opens after sunset turn on the hall light',
        'when': [
          {
            'on': 'front_door.contact',
            'change': {'to': false},
          },
        ],
        'onlyIf': [
          {
            'between': ['21:21', '04:43'],
          },
        ],
        'then': [
          {
            'do': 'hall_light.power',
            'params': {'value': true},
          },
          {'wait': 300000},
          {
            'do': 'hall_light.power',
            'params': {'value': false},
          },
        ],
      },
      {
        'name': 'If it gets above 28 turn on the fan',
        'when': [
          {
            'on': 'thermometer.temperature',
            'crosses': {'above': 28},
          },
        ],
        'then': [
          {
            'do': 'fan.power',
            'params': {'value': true},
          },
        ],
      },
      {
        'name': 'Every day at sunset run Movie time',
        'when': [
          {'sun': 'sunset'},
        ],
        'then': [
          {'run': 'movie_time'},
        ],
      },
      {
        'name': 'When Jade gets home and it is after 18:00 turn on the room',
        'when': [
          {
            'on': 'jade.home',
            'change': {'to': true},
          },
        ],
        'onlyIf': [
          {
            'between': ['18:00', '00:00'],
          },
        ],
        'then': [
          {
            'do': 'desk_lamp.power',
            'params': {'value': true},
          },
          {'do': 'tv.wake'},
        ],
      },
    ];
    for (final s in specs) {
      expect(RuleSpec.fromJson(s).toJson(), s, reason: '${s['name']}');
    }
  });

  test('a parse reply reads into its parts', () {
    final p = ParsedRule.fromJson({
      'spec': null,
      'unknown': ['blorp', 3],
      'problem': 'no',
      'alternatives': [
        {
          'text': 'lamp',
          'chosen': {'id': 'a', 'name': 'A'},
          'options': [
            {'id': 'b', 'name': 'B'},
          ],
        },
      ],
      'notes': ['n'],
    });
    expect(p.spec, isNull);
    expect(p.unknown, ['blorp']);
    final c = p.choices.single;
    expect(c.text, 'lamp');
    expect(c.chosen, 'A');
    expect(c.others, ['B']);
    expect(p.notes, ['n']);
  });
}
