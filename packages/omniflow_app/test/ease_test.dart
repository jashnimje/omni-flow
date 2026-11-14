import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/things.dart';
import 'package:omniflow_app/service/installed_apps.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/rule_words.dart';
import 'package:omniflow_app/ui/automations/sentence_row.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

final _board = Thing({
  'id': 'desk_board',
  'name': 'Desk board',
  'driver': 'omniflow_board',
  'capabilities': [
    {
      'id': 'ir_nec',
      'type': 'action',
      'label': 'Send NEC IR (address and command)',
    },
    {
      'id': 'ir_code',
      'type': 'text_command',
      'label': 'Send NEC IR (32-bit code, MSB first)',
    },
    {'id': 'rf_send', 'type': 'action', 'label': 'Send a 433 MHz RF code'},
  ],
});

Map<String, Object?> _inRoom(Map<String, Object?> device, String room) => {
  ...device,
  'room': room,
};

const _blank = <String, Object?>{
  'name': 'Lights out',
  'when': [
    {'manual': true},
  ],
  'then': [],
};

void main() {
  group('step library', () {
    test('a board reads as infrared and radio codes, not its protocol', () {
      expect(_board.actionsText, 'infrared and radio codes');
      expect(
        Thing({
          'id': 'bulb',
          'capabilities': [
            {'id': 'power', 'type': 'toggle', 'label': 'Power'},
            {'id': 'brightness', 'type': 'level', 'label': 'Brightness'},
            {
              'id': 'color_temp',
              'type': 'level',
              'label': 'White temperature in mireds (153 cool to 500 warm)',
            },
          ],
        }).actionsText,
        'on and off, brightness and white temperature in mireds',
      );
    });

    testWidgets('opens with the search focused and the categories in one '
        'row that scrolls sideways', (tester) async {
      final engine = automationsEngine();
      await pumpPushed(tester, engine, const RuleEditorPage(initial: _blank));
      await tapText(tester, 'Add step');
      final search = tester.widget<TextField>(
        find.byKey(const ValueKey('picker-search')),
      );
      expect(search.autofocus, isTrue);
      final row = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('library-categories')),
      );
      expect(row.scrollDirection, Axis.horizontal);
    });
  });

  group('automation rows', () {
    testWidgets('the switch says On or Off, and the filter says Quick links', (
      tester,
    ) async {
      final engine = automationsEngine();
      await pumpPage(tester, engine, const AutomationsScreen());
      expect(find.text('Quick links'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('enable-label-arrive_home')),
            )
            .data,
        'On',
      );
      expect(find.bySemanticsLabel('Turn Arrive home off'), findsOneWidget);
    });

    testWidgets('a swipe right turns it off, and Undo turns it on again', (
      tester,
    ) async {
      final engine = automationsEngine();
      await pumpPage(tester, engine, const AutomationsScreen());
      await tester.drag(
        find.byKey(const ValueKey('automation-arrive_home')),
        const Offset(500, 0),
      );
      await tester.pumpAndSettle();
      expect(engine.callsOf('automation.enable').single.$2, {
        'id': 'arrive_home',
        'enabled': false,
      });
      expect(find.text('Turned Arrive home off'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('automation.enable').last.$2, {
        'id': 'arrive_home',
        'enabled': true,
      });
    });

    testWidgets('a swipe left removes it, and Undo saves it back as it was', (
      tester,
    ) async {
      final engine = automationsEngine();
      final spec = {
        'name': 'Arrive home',
        'when': [
          {'arrive': 'home'},
        ],
        'then': [],
      };
      engine.answers['automation.get'] = {
        'ok': true,
        'id': 'arrive_home',
        'source': 'rule',
        'spec': spec,
        'enabled': false,
        'approved': true,
      };
      await pumpPage(tester, engine, const AutomationsScreen());
      await tester.drag(
        find.byKey(const ValueKey('automation-arrive_home')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(engine.callsOf('automation.remove').single.$2, {
        'id': 'arrive_home',
      });
      expect(find.text('Removed Arrive home'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('automation.save').single.$2, {
        'form': 'rule',
        'spec': spec,
        'trusted': true,
        'id': 'arrive_home',
      });
      // It was off, so it comes back off.
      expect(engine.callsOf('automation.enable').single.$2, {
        'id': 'arrive_home',
        'enabled': false,
      });
    });
  });

  group('an app opens', () {
    testWidgets('picks from the phone\'s apps, with the typed field kept', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(InstalledApps.name),
        (call) async => [
          {'package': 'com.netflix.mediaclient', 'label': 'Netflix'},
          {'package': 'com.whatsapp', 'label': 'WhatsApp'},
        ],
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(InstalledApps.name),
          null,
        ),
      );
      final engine = automationsEngine()
        ..devices = [
          ...household(),
          {
            'id': 'phone',
            'name': 'This phone',
            'driver': 'phone',
            'state': const <String, Object?>{},
            'capabilities': const [],
          },
        ];
      await pumpPushed(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Chat lights',
            'when': [],
            'then': [
              {'wait': 1000},
            ],
          },
        ),
      );
      await tapText(tester, 'Add trigger');
      await tapKey(tester, 'category-This phone');
      await tapKey(tester, 'pick-phone-app');
      expect(find.byKey(const ValueKey('phone-app')), findsOneWidget);
      await tapKey(tester, 'phone-app-choose');
      await tester.enterText(
        find.byKey(const ValueKey('picker-search')),
        'whats',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('pick-phone-app-com.netflix.mediaclient')),
        findsNothing,
      );
      await tapKey(tester, 'pick-phone-app-com.whatsapp');
      expect(find.text('WhatsApp'), findsOneWidget);
      await tapKey(tester, 'form-done');
      await tapKey(tester, 'rule-save');
      expect((savedSpec(engine)['when'] as List).single, {
        'on': 'phone.app_opened',
        'event': true,
        'match': {'package': 'com.whatsapp'},
      });
    });
  });

  group('repeat with each over a room', () {
    testWidgets('does one thing to each device, written as a sentence', (
      tester,
    ) async {
      final engine = automationsEngine()
        ..devices = [
          _inRoom(FakeEngine.lamp(), 'Study'),
          _inRoom(hallBulb, 'Study'),
          livingTv,
        ];
      await pumpPushed(tester, engine, const RuleEditorPage(initial: _blank));
      await tapText(tester, 'Add step');
      await tapKey(tester, 'pick-foreach');
      await tapText(tester, 'A room');
      await tapKey(tester, 'foreach-room-Study');
      expect(find.text('Do this to each device'), findsOneWidget);
      await tapKey(tester, 'foreach-each-on-power');
      await tapKey(tester, 'form-done');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('block-then[0].forEach.do')),
          matching: find.textContaining('Turn each device on'),
        ),
        findsWidgets,
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      final row = tester.widget<SentenceRow>(
        find.byKey(const ValueKey('row-then[0]')),
      );
      expect(row.text, 'Repeat with each device in Study');
      await tapKey(tester, 'rule-save');
      expect(savedSpec(engine)['then'], [
        {
          'forEach': {
            'in': 'room:Study',
            'do': [
              {
                'do': '{{%item}}.power',
                'params': {'value': true},
              },
            ],
          },
        },
      ]);
    });
  });
}
