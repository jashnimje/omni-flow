import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/rules/rule_spec.dart' show HttpStep;
import 'package:omniflow_app/ui/add/guided_steps_page.dart';
import 'package:omniflow_app/ui/automations/automations_screen.dart'
    show AutomationCard;
import 'package:omniflow_app/ui/automations/new_automation.dart'
    show TemplatePage;
import 'package:omniflow_app/ui/automations/next_run_line.dart';
import 'package:omniflow_app/ui/automations/pickers.dart' show httpForm;
import 'package:omniflow_app/ui/automations/removed_page.dart';
import 'package:omniflow_app/ui/automations/web_headers.dart';
import 'package:omniflow_app/ui/design/design.dart' show OmniButton;
import 'package:omniflow_app/ui/help/screen_help.dart';
import 'package:omniflow_app/ui/help/setting_help.dart';
import 'package:omniflow_app/ui/home/empty_home.dart';
import 'package:omniflow_app/ui/onboarding/home_setup.dart';
import 'package:omniflow_app/ui/settings/backup_page.dart';
import 'package:omniflow_app/ui/settings/phone_access.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show FakeAccess;
import 'screen_harness.dart';

const _tuyaKeyHelp =
    'A 16 character key the device uses to lock its messages. It is not in '
    'the Smart Life or Wipro app.\n1. Make an account at iot.tuya.com.\n'
    '2. Run python -m tinytuya wizard.';

Map<String, Object?> _phone({String? ssid = 'HomeNet'}) => {
  'id': 'this_phone',
  'name': 'This phone',
  'driver': 'phone',
  'state': {'wifi_ssid': ?ssid},
  'capabilities': const <Object?>[],
};

void main() {
  group('setting help', () {
    test('the summary is the first sentence', () {
      expect(helpSummary(_tuyaKeyHelp), startsWith('A 16 character key'));
      expect(helpSummary(_tuyaKeyHelp), endsWith('messages.'));
      expect(helpSummary('One line'), 'One line');
    });

    testWidgets('shows under the field, and the "?" opens all of it', (
      tester,
    ) async {
      final engine = FakeEngine();
      await pumpScreen(
        tester,
        engine,
        GuidedStepsPage(
          id: 'plug',
          name: 'Kettle plug',
          first: NextStep.fromJson({
            'step': 'secret',
            'instruction': 'Enter the Local key',
            'keys': [
              {
                'step': 'secret',
                'key': 'localKey',
                'label': 'Local key',
                'help': _tuyaKeyHelp,
              },
            ],
            'remaining': ['secret'],
          }),
        ),
      );
      expect(
        find.text('A 16 character key the device uses to lock its messages.'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('setting-help-open-localKey')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setting-help-sheet')), findsOneWidget);
      expect(find.textContaining('iot.tuya.com'), findsOneWidget);
      expect(find.textContaining('tinytuya wizard'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget, reason: 'steps are numbered');
    });

    testWidgets('a field with no help shows none', (tester) async {
      await pumpScreen(
        tester,
        FakeEngine(),
        GuidedStepsPage(
          id: 'mac',
          name: 'Mac',
          first: NextStep.fromJson({
            'step': 'configure',
            'keys': [
              {'step': 'configure', 'key': 'username', 'label': 'Username'},
            ],
            'remaining': ['configure'],
          }),
        ),
      );
      expect(
        find.byKey(const ValueKey('setup-field-username')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('setting-help-open-username')),
        findsNothing,
      );
    });
  });

  group('screen help', () {
    for (final screen in HelpScreen.values) {
      testWidgets('the ${screen.name} "?" opens its help', (tester) async {
        await pumpScreen(
          tester,
          FakeEngine(),
          Scaffold(appBar: AppBar(actions: [ScreenHelpButton(screen)])),
        );
        await tester.tap(find.byKey(ValueKey('help-${screen.name}')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('help-sheet-${screen.name}')), findsOne);
        expect(find.text(screenHelp[screen]!.title), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('help-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('help-sheet-${screen.name}')), findsNothing);
      });
    }

    testWidgets('Devices help lists where to find each key', (tester) async {
      final engine = FakeEngine()
        ..answers['driver.list'] = {
          'ok': true,
          'drivers': [
            {
              'id': 'tuya_plug',
              'name': 'Tuya smart plug',
              'settings': [
                {'key': 'devId', 'label': 'Device id', 'help': 'Its id.'},
                {
                  'key': 'localKey',
                  'label': 'Local key',
                  'secret': true,
                  'help': _tuyaKeyHelp,
                },
              ],
            },
          ],
        };
      await pumpScreen(
        tester,
        engine,
        Scaffold(
          appBar: AppBar(actions: const [ScreenHelpButton(HelpScreen.devices)]),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('help-devices')));
      await tester.pumpAndSettle();
      final guide = find.byKey(const ValueKey('key-guide-tuya_plug-localKey'));
      expect(guide, findsOneWidget);
      expect(
        find.byKey(const ValueKey('key-guide-tuya_plug-devId')),
        findsNothing,
        reason: 'only keys, not every setting',
      );
      await tester.ensureVisible(guide);
      await tester.tap(guide);
      await tester.pumpAndSettle();
      expect(find.textContaining('iot.tuya.com'), findsOneWidget);
    });
  });

  group('next run', () {
    final now = DateTime(2026, 11, 13, 9);

    test('reads as today, tomorrow, a weekday or a date', () {
      expect(
        nextRunWords(DateTime(2026, 11, 13, 18, 30), now: now),
        'today 18:30',
      );
      expect(
        nextRunWords(DateTime(2026, 11, 14, 6, 5), now: now),
        'tomorrow 06:05',
      );
      expect(nextRunWords(DateTime(2026, 11, 17, 7), now: now), 'Tue 07:00');
      expect(nextRunWords(DateTime(2026, 12, 3, 7), now: now), '3 Dec 07:00');
    });

    test('automation.list rows carry nextRun', () {
      final a = AutomationSummary.fromJson({
        'id': 'evening',
        'name': 'Evening',
        'nextRun': '2026-11-13T18:30:00.000',
      });
      expect(a.nextRun, DateTime(2026, 11, 13, 18, 30));
      expect(
        AutomationSummary.fromJson({'id': 'x', 'name': 'X'}).nextRun,
        isNull,
      );
    });

    testWidgets('the card shows Next while it is on', (tester) async {
      final at = DateTime.now().add(const Duration(minutes: 5));
      await pumpScreen(
        tester,
        FakeEngine(),
        Scaffold(
          body: ListView(
            children: [
              AutomationCard(
                automation: AutomationSummary(
                  id: 'evening',
                  name: 'Evening',
                  nextRun: at,
                ),
              ),
              AutomationCard(
                automation: AutomationSummary(
                  id: 'off',
                  name: 'Off one',
                  enabled: false,
                  nextRun: at,
                ),
              ),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('next-run-evening')), findsOneWidget);
      expect(find.text('Next: ${nextRunWords(at)}'), findsOneWidget);
      expect(find.byKey(const ValueKey('next-run-off')), findsNothing);
    });
  });

  group('recently removed', () {
    test('days left counts a part day as a day', () {
      final now = DateTime(2026, 11, 13, 9);
      expect(daysLeft(now.add(const Duration(days: 2, hours: 1)), now: now), 3);
      expect(daysLeft(now.add(const Duration(hours: 1)), now: now), 1);
      expect(daysLeft(now.subtract(const Duration(hours: 1)), now: now), 0);
      expect(daysLeftWords(1), '1 day left');
      expect(daysLeftWords(4), '4 days left');
    });

    testWidgets('lists removed automations and puts one back', (tester) async {
      final now = DateTime.now().toUtc();
      final engine = FakeEngine()
        ..answers['automation.removed'] = {
          'ok': true,
          'removed': [
            {
              'id': 'bedtime',
              'name': 'Bedtime',
              'form': 'rule',
              'removedAt': now
                  .subtract(const Duration(hours: 2))
                  .toIso8601String(),
              'keptUntil': now
                  .add(const Duration(days: 6, hours: 22))
                  .toIso8601String(),
              'versions': 2,
            },
          ],
          'keptDays': 7,
        };
      await pumpScreen(tester, engine, const RemovedPage());
      expect(find.text('Bedtime'), findsOneWidget);
      expect(find.textContaining('7 days left'), findsOneWidget);
      expect(find.textContaining('Removed today'), findsOneWidget);

      engine.answers['automation.removed'] = {
        'ok': true,
        'removed': <Object?>[],
        'keptDays': 7,
      };
      await tester.tap(find.byKey(const ValueKey('restore-bedtime')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('automation.unremove').single.$2, {
        'id': 'bedtime',
      });
      expect(find.textContaining('Bedtime is back'), findsOneWidget);
      expect(find.byKey(const ValueKey('removed-empty')), findsOneWidget);
    });
  });

  group('web request headers', () {
    test('a secret name comes from the header name', () {
      expect(secretNameFor('X-Api-Key'), 'x-api-key');
      expect(secretNameFor('Authorization'), 'authorization');
      expect(secretNameFor(' 9 Bearer token'), 'bearer_token');
      expect(secretNameFor('---'), 'web_key');
    });

    testWidgets('a header from a secret is stored by web.secret.set', (
      tester,
    ) async {
      final engine = FakeEngine();
      HttpStep? got;
      await pumpScreen(
        tester,
        engine,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open-form'),
              onPressed: () async => got = await httpForm(
                context,
                HttpStep('https://api.example.com/x'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-form')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('http-header-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('http-header-name-0')),
        'X-Api-Key',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('From a secret'));
      await tester.pumpAndSettle();
      final secretName = tester.widget<TextField>(
        find.byKey(const ValueKey('http-header-secret-name-0')),
      );
      expect(secretName.controller!.text, 'x-api-key');
      expect(find.text('Save the secret for X-Api-Key first'), findsOneWidget);
      expect(
        tester
            .widget<OmniButton>(find.byKey(const ValueKey('form-done')))
            .onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const ValueKey('http-header-secret-value-0')),
        'abc123',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('http-header-secret-save-0')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('web.secret.set').single.$2, {
        'name': 'x-api-key',
        'value': 'abc123',
      });
      expect(find.text('Saved on this phone as x-api-key'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('http-header-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('http-header-name-1')),
        'Accept',
      );
      await tester.enterText(
        find.byKey(const ValueKey('http-header-value-1')),
        'application/json',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect((got!.toJson()['http'] as Map)['headers'], {
        'X-Api-Key': {'secret': 'x-api-key'},
        'Accept': 'application/json',
      });
      expect('${got!.toJson()}', isNot(contains('abc123')));
    });

    testWidgets('saved headers reopen as they were, and can be removed', (
      tester,
    ) async {
      final engine = FakeEngine();
      HttpStep? got;
      await pumpScreen(
        tester,
        engine,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open-form'),
              onPressed: () async => got = await httpForm(
                context,
                HttpStep(
                  'https://api.example.com/x',
                  extra: {
                    'headers': {
                      'Authorization': {'secret': 'ha_token'},
                    },
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-form')));
      await tester.pumpAndSettle();
      expect(find.text('Saved on this phone as ha_token'), findsOneWidget);
      expect(find.text('Its headers stay as they were set.'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('http-header-remove-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await tester.pumpAndSettle();
      expect((got!.toJson()['http'] as Map).containsKey('headers'), isFalse);
      expect(engine.callsOf('web.secret.set'), isEmpty);
    });
  });

  group('home setup', () {
    testWidgets('walks you, home, Wi-Fi, then device and automation', (
      tester,
    ) async {
      final engine = FakeEngine()..devices = [_phone()];
      engine.onCall = (command, args) {
        if (command == 'device.add') {
          engine.devices = [
            _phone(),
            {'id': 'asha', 'name': 'Asha', 'driver': 'person', 'state': {}},
          ];
        }
      };
      final access = FakeAccess(const PhoneAccessState(location: false));
      await pumpScreen(
        tester,
        engine,
        const HomeSetupPage(),
        overrides: [phoneAccessProvider.overrideWithValue(access)],
      );
      expect(find.bySemanticsLabel('Step 1 of 5'), findsOneWidget);
      expect(find.text('Who are you?'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('setup-name')), 'Asha');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-name-save')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.add').single.$2, {
        'id': 'asha',
        'name': 'Asha',
        'driver': 'person',
      });
      expect(engine.callsOf('thing.configure').single.$2, {
        'id': 'this_phone',
        'settings': {'person': 'asha'},
      });

      expect(find.bySemanticsLabel('Step 2 of 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-home-location')), findsOne);
      await tester.tap(find.byKey(const ValueKey('step-skip')));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Step 3 of 5'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('setup-allow-location')));
      await tester.pumpAndSettle();
      expect(access.asked, ['location']);
      await tester.tap(find.byKey(const ValueKey('setup-use-wifi')));
      await tester.pumpAndSettle();
      final zone = engine.callsOf('zone.save').single.$2['zone'] as Map;
      expect(zone['id'], 'home');
      expect((zone['wifi'] as Map)['ssids'], ['HomeNet']);

      expect(find.bySemanticsLabel('Step 4 of 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-add-device')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('step-skip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setup-new-automation')), findsOne);
      await tester.tap(find.byKey(const ValueKey('step-skip')));
      await tester.pumpAndSettle();
      expect(find.text('That is all for now'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('setup-finish')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('root')), findsOneWidget);
    });

    testWidgets('resumes on the first step not done', (tester) async {
      final engine = FakeEngine()
        ..devices = [
          _phone(ssid: null),
          {'id': 'asha', 'name': 'Asha', 'driver': 'person', 'state': {}},
        ]
        ..answers['home.location'] = {
          'ok': true,
          'location': {'latitude': 12.97, 'longitude': 77.59},
        };
      await pumpScreen(
        tester,
        engine,
        const HomeSetupPage(),
        overrides: [
          phoneAccessProvider.overrideWithValue(
            FakeAccess(
              const PhoneAccessState(location: true, locationAlways: true),
            ),
          ),
        ],
      );
      expect(find.bySemanticsLabel('Step 3 of 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-no-wifi')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('setup-allow-location')),
        findsNothing,
        reason: 'location is already allowed',
      );
    });

    testWidgets('Not now leaves at once', (tester) async {
      await pumpScreen(
        tester,
        FakeEngine()..devices = [_phone()],
        const HomeSetupPage(),
        overrides: [
          phoneAccessProvider.overrideWithValue(
            FakeAccess(const PhoneAccessState()),
          ),
        ],
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('root')), findsOneWidget);
    });

    testWidgets('the Settings row says how far it got and opens it', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        FakeEngine()
          ..devices = [
            _phone(),
            {'id': 'asha', 'name': 'Asha', 'driver': 'person', 'state': {}},
          ],
        const Scaffold(body: HomeSetupRow()),
        overrides: [
          phoneAccessProvider.overrideWithValue(
            FakeAccess(const PhoneAccessState()),
          ),
        ],
      );
      expect(find.textContaining('1 of 5 done'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-home-setup')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step 2 of 5'), findsOneWidget);
    });
  });

  group('templates', () {
    testWidgets('one that needs a person offers Set up home', (tester) async {
      await pumpScreen(
        tester,
        FakeEngine()..devices = [_phone()],
        TemplatePage(
          template: AutomationTemplate.fromJson({
            'id': 'arrive_home',
            'name': 'Arrive home',
            'placeholders': [
              {'key': 'person', 'label': 'Who', 'kind': 'person'},
            ],
          }),
        ),
        overrides: [
          phoneAccessProvider.overrideWithValue(
            FakeAccess(const PhoneAccessState()),
          ),
        ],
      );
      expect(find.byKey(const ValueKey('tpl-missing-person')), findsOneWidget);
      await tester.tap(find.text('Set up home'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeSetupPage), findsOneWidget);
      expect(find.text('Who are you?'), findsOneWidget);
    });
  });

  group('empty home', () {
    testWidgets('offers Restore a backup and Connect to a hub', (tester) async {
      final engine = FakeEngine()
        ..devices = [_phone()]
        ..answers['device.discover'] = {'ok': true, 'found': <Object?>[]};
      await pumpScreen(tester, engine, const EmptyHome());
      expect(find.byKey(const ValueKey('empty-hub')), findsOneWidget);
      expect(find.byKey(const ValueKey('empty-setup')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('empty-restore')));
      await tester.pumpAndSettle();
      expect(find.byType(BackupPage), findsOneWidget);
    });
  });
}
