import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/rule_calls.dart';
import 'package:omniflow_app/rules/rule_spec.dart';
import 'package:omniflow_app/rules/things.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/pickers.dart' show StepCategories;
import 'package:omniflow_app/ui/automations/rule_words.dart';
import 'package:omniflow_app/ui/automations/sentence_row.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

final _tv = <String, Object?>{
  'id': 'tv',
  'name': 'TV',
  'driver': 'android_tv_adb',
  'host': '192.168.1.60',
  'room': 'Living room',
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
};

final _phone = <String, Object?>{
  'id': 'phone',
  'name': 'This phone',
  'driver': 'phone',
  'state': const {'charging': false},
  'capabilities': const [],
};

const _blank = <String, Object?>{
  'name': 'Film night',
  'when': [
    {'manual': true},
  ],
  'then': [],
};

const _answerToken = {
  'ok': true,
  'tokens': [
    {'token': '%answer', 'label': 'Answer', 'from': 'then[0]', 'kind': 'text'},
    {
      'token': 'msg.value',
      'label': 'Trigger · value',
      'from': 'trigger',
      'kind': 'any',
    },
  ],
};

void main() {
  group('rule spec', () {
    test('the data steps, ask and repeat with each keep every field, '
        'unknown ones too', () {
      final steps = <Map<String, Object?>>[
        {
          'ask': {
            'title': 'Which app?',
            'body': 'For the TV',
            'choices': ['Netflix', 'YouTube'],
            'input': false,
            'default': 'Netflix',
            'timeoutMs': 120000,
            'as': '%app',
            'newer': 1,
          },
        },
        {
          'get': {'from': '{{%reply.body}}', 'path': 'state.on', 'as': '%on'},
        },
        {
          'text': {'value': 'Hi {{%answer}}', 'op': 'upper'},
        },
        {
          'math': {'expr': '{{%reply.body.temp}} * 2 + 1'},
        },
        {
          'date': {'format': 'HH:mm', 'offsetMinutes': -30, 'as': '%when'},
        },
        {
          'forEach': {
            'in': 'room:Living room',
            'as': '%item',
            'do': [
              {
                'notify': {'title': '{{%item}}'},
              },
            ],
            'max': 10,
          },
        },
        {
          'do': 'tv.launch_app',
          'params': {'package': 'com.netflix.ninja'},
          'as': '%state',
        },
      ];
      for (final s in steps) {
        expect(RuleStep.fromJson(s).toJson(), s);
      }
      final each = RuleStep.fromJson(steps[5]) as ForEachStep;
      expect(each.room, 'Living room');
      expect(each.steps.single, isA<NotifyStep>());
    });

    test('colour, icon, ask first and notify on run are spec fields', () {
      final spec = RuleSpec.fromJson({
        'name': 'Evening',
        'when': [
          {'manual': true},
        ],
        'then': [
          {'wait': 1000},
        ],
        'color': '#F472B6',
        'askFirst': true,
      });
      expect(spec.color, '#F472B6');
      expect(spec.askFirst, isTrue);
      expect(spec.notifyOnRun, isFalse);
      spec
        ..notifyOnRun = true
        ..askFirst = false
        ..icon = 'moon';
      expect(spec.toJson(), {
        'color': '#F472B6',
        'notifyOnRun': true,
        'icon': 'moon',
        'name': 'Evening',
        'when': [
          {'manual': true},
        ],
        'then': [
          {'wait': 1000},
        ],
      });
    });
  });

  group('rule words', () {
    final words = RuleWords([Thing(_phone), Thing(_tv)]);

    test('new steps read as sentences with tokens in words', () {
      words.tokenLabels['%reply.body'] = 'Web reply · body';
      expect(
        words.step(AskStep('Which app?', choices: ['Netflix', 'YouTube'])),
        'Ask: Which app?, with Netflix or YouTube',
      );
      expect(
        words.step(AskStep('Your name?', input: true)),
        'Ask: Your name?, and wait for a reply',
      );
      expect(
        words.step(GetStep('{{%reply.body}}', path: 'name')),
        'Get name from Web reply · body',
      );
      expect(
        words.step(TextStep('Hi {{%answer}}', op: 'upper')),
        'Make text Hi Answer in capitals',
      );
      expect(
        words.step(MathStep('{{msg.value}} * 2')),
        'Work out Trigger · value * 2',
      );
      expect(
        words.step(DateStep('HH:mm', offsetMinutes: 30)),
        'Get the time 30 min from now as HH:mm',
      );
      expect(
        words.step(ForEachStep(over: 'room:Living room')),
        'Repeat with each device in Living room',
      );
    });

    test('the phone triggers read in plain words', () {
      OnTrigger on(String key, {Map<String, Object?>? match, Object? to}) =>
          OnTrigger(
            thing: 'phone',
            key: key,
            mode: match != null || PhoneKeys.events.contains(key)
                ? OnMode.event
                : OnMode.change,
            match: match,
            to: to,
            hasTo: to != null,
          );
      expect(
        words.trigger(
          on('app_opened', match: {'package': 'com.netflix.ninja'}),
        ),
        'Netflix opens',
      );
      expect(words.trigger(on('notification')), 'A notification arrives');
      expect(
        words.trigger(on('bluetooth_connected', match: {'name': 'Car'})),
        'Car connects',
      );
      expect(words.trigger(on('screen_on', to: true)), 'The screen turns on');
      expect(words.trigger(on('dnd_on')), 'Do Not Disturb turns on or off');
      expect(
        words.trigger(on('charging', to: false)),
        'The phone stops charging',
      );
    });

    test('a token from rule.tokens is read without its braces', () {
      final tokens = RuleCalls.tokensOf(_answerToken);
      expect(tokens.first.token, '%answer');
      expect(tokens.first.template, '{{%answer}}');
      expect(
        RuleToken.fromJson({'token': '{{%reply.body}}', 'label': 'x'}).token,
        '%reply.body',
      );
    });
  });

  group('editor', () {
    late FakeEngine engine;

    setUp(() {
      engine = automationsEngine()..devices = [...household(), _tv, _phone];
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
    });

    testWidgets('a step row reads as its sentence, and a tap on its value '
        'opens just that field', (tester) async {
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Lamp',
            'when': [
              {'manual': true},
            ],
            'then': [
              {'wait': 3000},
              {
                'do': 'desk_lamp.power',
                'params': {'value': true},
              },
            ],
          },
        ),
      );
      final row = tester.widget<SentenceRow>(
        find.byKey(const ValueKey('row-then[0]')),
      );
      expect(row.text, 'Wait 3 s');
      expect(row.parts.last.blank, Blank.duration);
      await tester.tapOnText(find.textRange.ofSubstring('3 s'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('duration-amount')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('duration-amount')),
        '10',
      );
      await tester.pump();
      await tapKey(tester, 'form-done');
      expect(find.text('Wait 10 s'), findsOneWidget);

      await tester.tapOnText(find.textRange.ofSubstring('Desk lamp'));
      await tester.pumpAndSettle();
      expect(find.text('Which device?'), findsOneWidget);
      await tapKey(tester, 'pick-device-hall_bulb');
      expect(find.text('Hall bulb · turn on'), findsOneWidget);
      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['then'], [
        {'wait': 10000},
        {
          'do': 'hall_bulb.power',
          'params': {'value': true},
        },
      ]);
    });

    testWidgets('a field takes a value from an earlier step as a token and '
        'shows it by its label', (tester) async {
      engine.answers['rule.tokens'] = _answerToken;
      await pumpPushed(tester, engine, const RuleEditorPage(initial: _blank));
      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-notify');
      expect(engine.callsOf('rule.tokens').last.$2['path'], 'then[0]');
      expect(
        (engine.callsOf('rule.tokens').last.$2['rule'] as Map)['name'],
        'Film night',
      );
      await tester.enterText(
        find.byKey(const ValueKey('notify-title')),
        'You picked ',
      );
      await tester.pump();
      await tapKey(tester, 'notify-title-token-%answer');
      expect(
        find.byKey(const ValueKey('notify-title-has-%answer')),
        findsOneWidget,
      );
      await tapKey(tester, 'form-done');
      expect(find.text('Notify: You picked Answer'), findsOneWidget);
      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['then'], [
        {
          'notify': {'title': 'You picked {{%answer}}'},
        },
      ]);
    });

    testWidgets('the step library searches device actions and TV apps, and '
        'narrows to a category', (tester) async {
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Film',
            'when': [
              {'manual': true},
            ],
            'then': [
              {
                'do': 'desk_lamp.power',
                'params': {'value': false},
              },
            ],
          },
        ),
      );
      await tapAdd(tester, 'Add step');
      expect(
        find.byKey(const ValueKey('suggest-device-desk_lamp')),
        findsOneWidget,
      );
      for (final c in StepCategories.all) {
        expect(find.byKey(ValueKey('category-$c')), findsOneWidget, reason: c);
      }
      await tapKey(tester, 'category-Web and data');
      expect(find.byKey(const ValueKey('pick-math')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-wait')), findsNothing);
      await tapKey(tester, 'category-Web and data');

      await tester.enterText(
        find.byKey(const ValueKey('picker-search')),
        'netflix',
      );
      await tester.pumpAndSettle();
      expect(find.text('Open Netflix on TV'), findsOneWidget);
      await tapText(tester, 'Open Netflix on TV');
      await tapKey(tester, 'rule-save');
      expect((savedSpec(engine)['then'] as List).last, {
        'do': 'tv.launch_app',
        'params': {'package': 'com.netflix.ninja'},
      });
    });

    testWidgets('an ask step chooses from a menu with a default and a time '
        'limit', (tester) async {
      await pumpPushed(tester, engine, const RuleEditorPage(initial: _blank));
      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-ask-choose');
      expect(buttonEnabled(tester, 'form-done'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('ask-title')),
        'Which app?',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ask-choice-0')),
        'Netflix',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ask-choice-1')),
        'YouTube',
      );
      await tester.pump();
      await tapKey(tester, 'ask-add-choice');
      await tester.enterText(
        find.byKey(const ValueKey('ask-choice-2')),
        'Prime',
      );
      await tester.pump();
      await tapKey(tester, 'ask-default-YouTube');
      await tester.enterText(find.byKey(const ValueKey('ask-timeout')), '2');
      await tester.pump();
      await tapKey(tester, 'form-done');
      expect(
        find.text('Ask: Which app?, with Netflix, YouTube or Prime'),
        findsOneWidget,
      );
      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['then'], [
        {
          'ask': {
            'title': 'Which app?',
            'choices': ['Netflix', 'YouTube', 'Prime'],
            'default': 'YouTube',
            'timeoutMs': 120000,
          },
        },
      ]);
    });

    testWidgets('the data steps save what their forms say', (tester) async {
      await pumpPushed(tester, engine, const RuleEditorPage(initial: _blank));
      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-get');
      await tester.enterText(
        find.byKey(const ValueKey('get-from')),
        '{{%reply.body}}',
      );
      await tester.enterText(find.byKey(const ValueKey('get-path')), 'temp');
      await tester.pump();
      await tapKey(tester, 'form-done');

      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-math');
      await tester.enterText(
        find.byKey(const ValueKey('math-expr')),
        '{{%value}} * 2',
      );
      await tester.enterText(find.byKey(const ValueKey('math-as')), 'twice');
      await tester.pump();
      await tapKey(tester, 'form-done');

      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-text');
      await tester.enterText(find.byKey(const ValueKey('text-value')), 'hi');
      await tester.pump();
      await tapText(tester, 'CAPITALS');
      await tapKey(tester, 'form-done');

      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-date');
      await tapText(tester, 'From now');
      await tester.enterText(find.byKey(const ValueKey('date-minutes')), '15');
      await tester.pump();
      await tapKey(tester, 'form-done');

      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['then'], [
        {
          'get': {'from': '{{%reply.body}}', 'path': 'temp'},
        },
        {
          'math': {'expr': '{{%value}} * 2', 'as': '%twice'},
        },
        {
          'text': {'value': 'hi', 'op': 'upper'},
        },
        {
          'date': {'format': 'HH:mm', 'offsetMinutes': 15},
        },
      ]);
    });

    testWidgets('repeat with each goes through a room, with its own steps', (
      tester,
    ) async {
      await pumpPushed(tester, engine, const RuleEditorPage(initial: _blank));
      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-foreach');
      await tapText(tester, 'A room');
      await tapKey(tester, 'foreach-room-Living room');
      await tapKey(tester, 'form-done');
      expect(find.text('Repeat with each'), findsWidgets);
      await tapIn(tester, 'block-then[0].forEach.do', 'Add step');
      await tapKey(tester, 'pick-notify');
      await tester.enterText(
        find.byKey(const ValueKey('notify-title')),
        '{{%item}}',
      );
      await tester.pump();
      await tapKey(tester, 'form-done');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      final row = tester.widget<SentenceRow>(
        find.byKey(const ValueKey('row-then[0]')),
      );
      expect(row.text, 'Repeat with each device in Living room');
      expect(row.trailingText, '1');
      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['then'], [
        {
          'forEach': {
            'in': 'room:Living room',
            'do': [
              {
                'notify': {'title': '{{%item}}'},
              },
            ],
          },
        },
      ]);
    });

    testWidgets('Options sets ask first, notify on run, colour and icon', (
      tester,
    ) async {
      await pumpPushed(
        tester,
        engine,
        RuleEditorPage(
          initial: {
            ..._blank,
            'then': [
              {'wait': 1000},
            ],
          },
        ),
      );
      // They wait in Options, collapsed.
      expect(find.byKey(const ValueKey('rule-ask-first')), findsNothing);
      await tapKey(tester, 'rule-options');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('rule-ask-first')),
          matching: find.byType(Switch),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('rule-notify-on-run')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'rule-look');
      await tapKey(tester, 'look-color-FB923C');
      await tapKey(tester, 'look-icon-movie');
      await tapKey(tester, 'look-done');
      expect(find.text('Orange, Film'), findsOneWidget);
      await tapKey(tester, 'rule-save');
      final spec = savedSpec(engine);
      expect(spec['askFirst'], isTrue);
      expect(spec['notifyOnRun'], isTrue);
      expect(spec['color'], '#FB923C');
      expect(spec['icon'], 'movie');
    });

    testWidgets('the trigger library offers the phone triggers under This '
        'phone', (tester) async {
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Netflix lights',
            'when': [],
            'then': [
              {'wait': 1000},
            ],
          },
        ),
      );
      await tapAdd(tester, 'Add trigger');
      await tapKey(tester, 'category-This phone');
      expect(find.byKey(const ValueKey('pick-time')), findsNothing);
      for (final key in [
        'pick-phone-app',
        'pick-phone-notification',
        'pick-phone-bluetooth',
        'pick-phone-screen',
        'pick-phone-dnd',
        'pick-phone-charging',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      await tapKey(tester, 'pick-phone-app');
      await tester.enterText(
        find.byKey(const ValueKey('phone-app')),
        'com.netflix.ninja',
      );
      await tester.pump();
      await tapKey(tester, 'form-done');
      expect(find.text('Netflix opens'), findsOneWidget);

      await tapAdd(tester, 'Add trigger');
      await tapKey(tester, 'pick-phone-charging');
      await tapText(tester, 'Starts');
      await tapKey(tester, 'form-done');
      expect(find.text('The phone starts charging'), findsOneWidget);
      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['when'], [
        {
          'on': 'phone.app_opened',
          'event': true,
          'match': {'package': 'com.netflix.ninja'},
        },
        {
          'on': 'phone.charging',
          'change': {'to': true},
        },
      ]);
    });

    testWidgets('rows with blanks and tokens, and the step library, meet the '
        'tap target, label and contrast guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      engine.answers['rule.tokens'] = _answerToken;
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Ask',
            'when': [
              {'time': '18:00'},
            ],
            'then': [
              {
                'ask': {
                  'title': 'Which app?',
                  'choices': ['Netflix', 'YouTube'],
                },
              },
              {
                'notify': {'title': 'You picked {{%answer}}'},
              },
            ],
          },
        ),
      );
      expect(find.text('Notify: You picked Answer'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await tapAdd(tester, 'Add step');
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('ask before running is off for a rule with a keep step', (
      tester,
    ) async {
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Bulb off while away',
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
          },
        ),
      );
      // Options opens on its own only for an error, so open it.
      await tapKey(tester, 'rule-options');
      final ask = tester.widget<Switch>(
        find.descendant(
          of: find.byKey(const ValueKey('rule-ask-first')),
          matching: find.byType(Switch),
        ),
      );
      expect(ask.onChanged, isNull);
      expect(find.textContaining('Not with a keep step'), findsOneWidget);
    });

    testWidgets('an ask takes at most ten choices', (tester) async {
      await pumpPushed(tester, engine, const RuleEditorPage(initial: _blank));
      await tapAdd(tester, 'Add step');
      await tapKey(tester, 'pick-ask-choose');
      for (var i = 0; i < 8; i++) {
        await tapKey(tester, 'ask-add-choice');
      }
      expect(find.byKey(const ValueKey('ask-choice-9')), findsOneWidget);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.descendant(
                of: find.byKey(const ValueKey('ask-add-choice')),
                matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
              ),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('a time trigger changes its time from its blank', (
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
            'then': [
              {'wait': 1000},
            ],
          },
        ),
      );
      await tester.tapOnText(find.textRange.ofSubstring('18:00'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
    });
  });
}
