import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/appearance.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/device_page.dart';
import 'package:omniflow_app/ui/home/tile_look.dart';
import 'package:omniflow_app/ui/settings/appearance_page.dart';
import 'package:omniflow_app/api/engine_calls.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show household, pump, tapKey;

/// The look of the app: tiles that show live state, text at 200%, wide
/// screens, Devices' search and type groups, and the Appearance setting.
void main() {
  late FakeEngine engine;

  setUp(() => engine = household());

  group('tile look', () {
    test('a light takes its own colour, its white, or a warm white', () {
      Json light(Map<String, Object?> state, List<String> types) => {
        'id': 'l',
        'state': {'state': true, ...state},
        'capabilities': [
          {'id': 'power', 'type': 'toggle', 'stateKey': 'state'},
          for (final t in types)
            {
              'id': t,
              'type': t,
              'stateKey': t == 'color_temp' ? 'temp' : t,
              if (t == 'color_temp')
                'params': {
                  'value': {'min': 2200, 'max': 6500, 'unit': 'K'},
                },
            },
        ],
      };
      expect(
        tileTint(DeviceView(light({'r': 255, 'g': 0, 'b': 0}, ['color_rgb']))),
        const Color(0xFFFF0000),
      );
      expect(
        tileTint(DeviceView(light({'temp': 2200}, ['color_temp']))),
        OmniColors.warmWhite,
      );
      expect(
        tileTint(DeviceView(light({'level': 50}, ['level']))),
        OmniColors.warmWhite,
      );
      expect(
        tileTint(
          DeviceView({
            ...light({}, ['level']),
            'state': {'state': false},
          }),
        ),
        isNull,
      );
    });

    test('a muted tint keeps light text at AA', () {
      for (final c in const [
        Color(0xFFFFFF00),
        Color(0xFFFFFFFF),
        Color(0xFF00FF00),
        Color(0xFF0000FF),
      ]) {
        final mixed = mutedTint(c, OmniColors.card, amount: 0.6);
        expect(
          contrastRatio(mixed, OmniColors.text),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    testWidgets('a sensor shows its reading big, a TV the app on screen', (
      tester,
    ) async {
      await pump(tester, engine);
      final sensor = tester.widget<OmniTile>(
        find.byKey(const ValueKey('tile-room_temp')),
      );
      expect(sensor.reading, '24.5 °C');
      final tv = tester.widget<OmniTile>(
        find.byKey(const ValueKey('tile-lounge_tv')),
      );
      // The TV keeps its name as the title: the app goes on the line under.
      expect((tv.reading, tv.state), (null, 'Netflix · Playing · vol 35'));
    });
  });

  group('text at 200%', () {
    testWidgets('Home and Devices lay out with no overflow', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester, engine);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tile-desk_lamp')), findsWidgets);
      final name = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const ValueKey('tile-room_temp')),
              matching: find.text('Room temperature'),
            )
            .first,
      );
      expect(name.maxLines, 2);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('shell-tabs')),
          matching: find.text('Devices'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('devices-list')), findsOneWidget);
      final bar = tester.getSize(find.byKey(const ValueKey('shell-tabs')));
      expect(bar.height, greaterThan(64));
    });
  });

  group('wide screens', () {
    Future<void> pumpWide(WidgetTester tester) async {
      await pump(tester, engine);
      // 1000 dp wide: an expanded window, after pump sets the phone size.
      tester.view.physicalSize = const Size(3000, 2400);
      await tester.pumpAndSettle();
    }

    testWidgets('a rail replaces the bar and Home has four tiles a row', (
      tester,
    ) async {
      await pumpWide(tester);
      expect(find.byKey(const ValueKey('shell-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-tabs')), findsNothing);
      final lamp = tester.getSize(
        find.byKey(const ValueKey('tile-desk_lamp')).first,
      );
      expect(lamp.width, lessThan(1000 / 4));
    });

    testWidgets('Devices shows the chosen device beside the list', (
      tester,
    ) async {
      await pumpWide(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('shell-rail')),
          matching: find.text('Devices'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose a device'), findsOneWidget);
      await tapKey(tester, 'device-row-desk_lamp');
      expect(find.byType(DevicePage), findsOneWidget);
      expect(find.byKey(const ValueKey('devices-list')), findsOneWidget);
    });
  });

  group('Devices', () {
    Future<void> openDevices(WidgetTester tester) async {
      await pump(tester, engine);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('shell-tabs')),
          matching: find.text('Devices'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the search field filters the list as you type', (
      tester,
    ) async {
      await openDevices(tester);
      await tester.enterText(
        find.byKey(const ValueKey('devices-filter')),
        'lamp',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('device-row-desk_lamp')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-row-lounge_tv')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('devices-filter')),
        'nothing like it',
      );
      await tester.pumpAndSettle();
      expect(find.text('No device matches "nothing like it"'), findsOneWidget);
      await tapKey(tester, 'devices-filter-clear');
      expect(
        find.byKey(const ValueKey('device-row-lounge_tv')),
        findsOneWidget,
      );
    });

    testWidgets('coming back from a device does not focus the search again', (
      tester,
    ) async {
      await openDevices(tester);
      await tester.tap(find.byKey(const ValueKey('devices-filter')));
      await tester.enterText(
        find.byKey(const ValueKey('devices-filter')),
        'lamp',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-row-desk_lamp')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('devices-filter')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('By type uses plain groups in a fixed order', (tester) async {
      await openDevices(tester);
      await tester.tap(find.text('By type'));
      await tester.pumpAndSettle();
      final lights = tester.getTopLeft(find.text('Lights')).dy;
      final tvs = tester.getTopLeft(find.text('TVs')).dy;
      final sensors = tester.getTopLeft(find.text('Sensors')).dy;
      // The phone has a group of its own, as in the Add list.
      final phones = tester.getTopLeft(find.text('Phones')).dy;
      expect(lights < tvs && tvs < sensors && sensors < phones, isTrue);
      expect(find.text('Plugs and switches'), findsNothing);
    });
  });

  group('Appearance', () {
    testWidgets('pure black and wallpaper colours change the theme live', (
      tester,
    ) async {
      final store = MemoryAppearanceStore();
      await pumpApp(
        tester,
        engine,
        overrides: [
          appearanceStoreProvider.overrideWithValue(store),
          // A phone that shares no wallpaper colours.
          wallpaperSchemeProvider.overrideWith((ref) async => null),
        ],
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('shell-tabs')),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Teal'), findsOneWidget);
      await tapKey(tester, 'settings-appearance');
      expect(find.byType(AppearancePage), findsOneWidget);
      Color background() =>
          Theme.of(tester.element(find.byType(AppearancePage)))
              .scaffoldBackgroundColor;
      expect(background(), OmniColors.background);

      await tapKey(tester, 'appearance-pure-black');
      expect(store.saved.pureBlack, isTrue);
      expect(background(), Colors.black);

      await tapKey(tester, 'appearance-wallpaper');
      expect(store.saved.colours, ColourSource.wallpaper);
      // The test phone shares no wallpaper colours, so the accent stays teal.
      expect(find.textContaining('Android 12 or later'), findsOneWidget);
      expect(
        OmniPalette.of(tester.element(find.byType(AppearancePage))).accent,
        OmniColors.accent,
      );
    });

    test('wallpaper colours replace the accent and keep the surfaces', () {
      const scheme = ColorScheme.dark(
        primary: Color(0xFFA8C7FF),
        onPrimary: Color(0xFF00315F),
        primaryContainer: Color(0xFF004786),
        onPrimaryContainer: Color(0xFFD5E3FF),
      );
      final p = const Appearance(colours: ColourSource.wallpaper)
          .palette(scheme);
      expect(p.accent, scheme.primary);
      expect(p.card, OmniColors.card);
      expect(
        const Appearance(colours: ColourSource.wallpaper).palette(null).accent,
        OmniColors.accent,
      );
    });

    test('the setting reads back from its JSON', () {
      const a = Appearance(colours: ColourSource.wallpaper, pureBlack: true);
      expect(Appearance.fromJson(a.toJson()), a);
      expect(Appearance.fromJson(const {}), const Appearance());
    });
  });
}
