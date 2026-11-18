import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/ui/settings/settings_screen.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

/// A phone in logical pixels (412 x 915 at 3x).
const _phone = Size(1236, 2745);

Finder _key(String key) => find.byKey(ValueKey(key));

/// Taps the header of the collapsed section [key].
Future<void> _open(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(
    _key(key),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: _key(key), matching: find.byType(InkWell)).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Settings, design v2', () {
    testWidgets('three groups in front, the rare rows in a closed More '
        'settings, and Developer nested in it', (tester) async {
      await pumpScreen(tester, FakeEngine(), const SettingsScreen());
      for (final header in ['Your home', 'This phone', 'Your data']) {
        expect(find.text(header), findsOneWidget, reason: header);
      }
      for (final row in [
        'settings-rooms',
        'settings-places',
        'settings-home-location',
        'settings-appearance',
        'settings-alerts',
        'settings-background',
        'settings-backup',
        'settings-activity',
        'settings-about',
      ]) {
        expect(_key(row), findsOneWidget, reason: row);
      }
      const rare = [
        'settings-tags',
        'settings-variables',
        'settings-sun-lighting',
        'settings-away-lighting',
        'settings-energy',
        'settings-home-runs-on',
        'settings-shake-scene',
        'settings-usb',
      ];
      const developer = ['settings-developer', 'settings-agent-access'];
      for (final row in [...rare, ...developer]) {
        expect(_key(row), findsNothing, reason: '$row is behind a section');
      }
      expect(find.text('More settings'), findsOneWidget);
      expect(find.text('For developers'), findsNothing);

      await _open(tester, 'settings-more');
      for (final row in rare) {
        expect(_key(row), findsOneWidget, reason: row);
      }
      expect(find.text('For developers'), findsOneWidget);
      for (final row in developer) {
        expect(_key(row), findsNothing, reason: '$row is one more tap away');
      }

      await _open(tester, 'settings-for-developers');
      for (final row in developer) {
        expect(_key(row), findsOneWidget, reason: row);
      }
    });

    testWidgets('More settings reads as a closed button with its summary', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, FakeEngine(), const SettingsScreen());
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^More settings, '))),
        matchesSemantics(
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
          label: 'More settings, Tags, saved values, energy, away lighting',
        ),
      );
      handle.dispose();
    });

    testWidgets('holds at 200% text on a phone', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpScreen(
        tester,
        FakeEngine(),
        const SettingsScreen(),
        size: _phone,
      );
      expect(tester.takeException(), isNull);
      await _open(tester, 'settings-more');
      await _open(tester, 'settings-for-developers');
      expect(tester.takeException(), isNull);
    });
  });

  group('Add, design v2', () {
    testWidgets('the kinds are big tiles in front, the rarer ways behind '
        'More ways to add', (tester) async {
      await pumpScreen(tester, FakeEngine(), const AddPage());
      for (final tile in ['manual-tag', 'manual-place']) {
        expect(
          find.byWidgetPredicate(
            (w) => w is AddKindTile && w.key == ValueKey(tile),
          ),
          findsOneWidget,
          reason: tile,
        );
      }
      expect(tester.getSize(_key('manual-tag')).height, greaterThan(100));
      const behind = [
        'manual-weather',
        'manual-usb-board',
        'manual-firmware',
        'add-by-driver',
      ];
      for (final row in behind) {
        expect(_key(row), findsNothing, reason: '$row is behind a section');
      }
      await _open(tester, 'add-more-ways');
      for (final row in behind) {
        expect(_key(row), findsOneWidget, reason: row);
      }
    });

    testWidgets('two tiles across, one across at 200% text', (tester) async {
      tester.view.devicePixelRatio = 3;
      // A phone's width, tall enough that the lazy list builds every tile.
      await pumpScreen(
        tester,
        FakeEngine(),
        const AddPage(),
        size: const Size(1236, 9000),
      );
      Rect tile(int i) => tester.getRect(find.byType(AddKindTile).at(i));
      expect(tile(0).top, tile(1).top, reason: 'side by side at 100%');
      final half = tile(0).width;

      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tile(0).width, greaterThan(half * 1.8), reason: 'one across');
    });
  });
}
