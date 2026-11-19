import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/device_features.dart';
import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/home/first_run.dart';
import 'package:omniflow_app/ui/home/home_data.dart';
import 'package:omniflow_app/ui/settings/settings_screen.dart';

import 'automations_fixtures.dart' as rules;
import 'fake_engine.dart';
import 'screen_harness.dart';

final _inApp = deviceFeaturesProvider.overrideWithValue(DeviceFeatures.inApp);

Finder _key(String key) => find.byKey(ValueKey(key));

final _phone = <String, Object?>{
  'id': 'phone',
  'name': 'This phone',
  'driver': 'phone',
  'state': const {'charging': false},
  'capabilities': const [],
};

class _NotDone implements FirstRunStore {
  @override
  Future<bool> done() async => false;

  @override
  Future<void> markDone() async {}
}

void main() {
  group('Off Android (iOS and the desktop)', () {
    testWidgets('Settings leaves out what only the Android app has', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        FakeEngine(),
        const SettingsScreen(),
        overrides: [_inApp],
      );
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('This phone'), findsNothing);
      expect(_key('settings-appearance'), findsOneWidget);
      expect(_key('settings-alerts'), findsOneWidget);
      expect(_key('settings-background'), findsNothing);
      await tester.scrollUntilVisible(
        _key('settings-more'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find
            .descendant(
              of: _key('settings-more'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(_key('settings-variables'), findsOneWidget);
      for (final row in [
        'settings-tags',
        'settings-home-runs-on',
        'settings-shake-scene',
        'settings-usb',
      ]) {
        expect(_key(row), findsNothing, reason: row);
      }
    });

    test('search finds no page for a missing feature', () {
      final titles = {
        for (final p in settingsPlacesFor(DeviceFeatures.inApp)) p.title,
      };
      for (final gone in [
        'Phone setup',
        'Permissions',
        'NFC tags',
        'Hubs',
        'Home runs on',
      ]) {
        expect(titles, isNot(contains(gone)), reason: gone);
      }
      expect(
        titles,
        containsAll(['Rooms', 'Appearance', 'Backup and restore']),
      );
      expect(
        settingsPlacesFor(DeviceFeatures.android).length,
        settingsPlaces.length,
      );
    });

    testWidgets('Add offers no NFC tag and no USB board', (tester) async {
      await pumpScreen(
        tester,
        FakeEngine(),
        const AddPage(),
        overrides: [_inApp],
      );
      expect(_key('manual-place'), findsOneWidget);
      expect(_key('manual-tag'), findsNothing);
      await tester.scrollUntilVisible(
        _key('add-more-ways'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find
            .descendant(
              of: _key('add-more-ways'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(_key('add-by-driver'), findsOneWidget);
      expect(_key('manual-usb-board'), findsNothing);
      expect(_key('manual-firmware'), findsNothing);
    });

    testWidgets('the trigger library has no This phone and no NFC tag', (
      tester,
    ) async {
      final engine = rules.automationsEngine()
        ..devices = [...rules.household(), _phone];
      await pumpScreen(
        tester,
        engine,
        const RuleEditorPage(
          initial: {
            'name': 'Evening',
            'when': [],
            'then': [
              {'wait': 1000},
            ],
          },
        ),
        overrides: [_inApp],
      );
      await rules.tapAdd(tester, 'Add trigger');
      expect(_key('pick-time'), findsOneWidget);
      expect(_key('category-This phone'), findsNothing);
      for (final key in [
        'pick-phone-app',
        'pick-phone-charging',
        'pick-thing-phone',
        'pick-tag',
      ]) {
        expect(_key(key), findsNothing, reason: key);
      }
    });

    testWidgets('an empty home skips the first run, which asks for Android '
        'permissions', (tester) async {
      final engine = FakeEngine()..devices = [_phone];
      await pumpApp(
        tester,
        engine,
        overrides: [
          _inApp,
          firstRunStoreProvider.overrideWithValue(_NotDone()),
        ],
      );
      expect(find.byType(FirstRunScreen), findsNothing);
      expect(find.text('Nothing added yet'), findsOneWidget);
      expect(_key('empty-restore'), findsOneWidget);
      expect(_key('empty-hub'), findsNothing);
    });
  });
}
