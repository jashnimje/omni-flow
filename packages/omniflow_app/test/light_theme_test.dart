import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/appearance.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/diagram/diagram_nodes.dart'
    show RunColors;
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/open_device.dart';
import 'package:omniflow_app/ui/settings/appearance_page.dart';

import 'automations_fixtures.dart' show automationRows, automationsEngine;
import 'fake_engine.dart';
import 'home_devices_test.dart' show household, tapKey;
import 'screen_harness.dart';

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

/// The light theme: the Appearance choice, every main screen drawn in it,
/// and the colour pairs it rests on.
void main() {
  /// The phone's own light or dark setting for one test. The suite runs on
  /// a dark phone (flutter_test_config.dart), so it goes back to dark.
  void phoneIs(WidgetTester tester, Brightness b) {
    tester.platformDispatcher.platformBrightnessTestValue = b;
    addTearDown(
      () => tester.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark,
    );
  }

  Future<void> pumpWith(WidgetTester tester, MemoryAppearanceStore store) =>
      pumpApp(
        tester,
        household(),
        overrides: [
          appearanceStoreProvider.overrideWithValue(store),
          wallpaperSchemeProvider.overrideWith((ref) async => null),
          wallpaperLightSchemeProvider.overrideWith((ref) async => null),
        ],
      );

  Brightness shown(WidgetTester tester, Finder at) =>
      OmniPalette.of(tester.element(at)).brightness;

  SystemUiOverlayStyle bars(WidgetTester tester) => tester
      .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
      )
      .value;

  group('Appearance theme', () {
    testWidgets('System is the default and follows the phone', (tester) async {
      phoneIs(tester, Brightness.light);
      await pumpWith(tester, MemoryAppearanceStore());
      final tabs = find.byKey(const ValueKey('shell-tabs'));
      expect(shown(tester, tabs), Brightness.light);
      expect(
        Theme.of(tester.element(tabs)).scaffoldBackgroundColor,
        OmniPalette.tealLight.background,
      );
      expect(bars(tester).statusBarIconBrightness, Brightness.dark);
      expect(bars(tester).systemNavigationBarIconBrightness, Brightness.dark);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(shown(tester, tabs), Brightness.dark);
      expect(bars(tester).statusBarIconBrightness, Brightness.light);
    });

    testWidgets('Light and Dark override the phone and are saved', (
      tester,
    ) async {
      phoneIs(tester, Brightness.dark);
      final store = MemoryAppearanceStore();
      await pumpWith(tester, store);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-appearance');
      final page = find.byType(AppearancePage);
      expect(shown(tester, page), Brightness.dark);
      Finder ticked(String choice) => find.descendant(
        of: find.byKey(ValueKey('appearance-theme-$choice')),
        matching: find.byIcon(OmniIcons.check),
      );
      expect(ticked('system'), findsOneWidget);

      await tapKey(tester, 'appearance-theme-light');
      expect(store.saved.theme, ThemeChoice.light);
      expect(ticked('light'), findsOneWidget);
      expect(ticked('system'), findsNothing);
      expect(shown(tester, page), Brightness.light);
      expect(bars(tester).statusBarIconBrightness, Brightness.dark);
      // Pure black is only for the dark theme.
      await tapKey(tester, 'appearance-pure-black');
      expect(store.saved.pureBlack, isTrue);
      expect(
        Theme.of(tester.element(page)).scaffoldBackgroundColor,
        OmniPalette.tealLight.background,
      );

      await tapKey(tester, 'appearance-theme-dark');
      expect(store.saved.theme, ThemeChoice.dark);
      expect(shown(tester, page), Brightness.dark);
      expect(
        Theme.of(tester.element(page)).scaffoldBackgroundColor,
        Colors.black,
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });

    testWidgets('a saved Light choice opens the app light on a dark phone', (
      tester,
    ) async {
      phoneIs(tester, Brightness.dark);
      await pumpWith(
        tester,
        MemoryAppearanceStore(const Appearance(theme: ThemeChoice.light)),
      );
      expect(
        shown(tester, find.byKey(const ValueKey('shell-tabs'))),
        Brightness.light,
      );
    });

    test('the choice reads back from its JSON, System when missing', () {
      for (final t in ThemeChoice.values) {
        final a = Appearance(theme: t, colours: ColourSource.wallpaper);
        expect(Appearance.fromJson(a.toJson()), a);
      }
      expect(Appearance.fromJson(const {}).theme, ThemeChoice.system);
      expect(
        Appearance.fromJson(const {'theme': 'sepia'}).theme,
        ThemeChoice.system,
      );
      expect(ThemeChoice.system.mode, ThemeMode.system);
      expect(ThemeChoice.light.mode, ThemeMode.light);
      expect(ThemeChoice.dark.mode, ThemeMode.dark);
      expect(
        AppearancePage.summary(const Appearance(theme: ThemeChoice.light)),
        'Light · Teal',
      );
      expect(AppearancePage.summary(const Appearance()), 'Teal');
    });

    test('the light palette keeps wallpaper colours and drops pure black', () {
      const scheme = ColorScheme.light(
        primary: Color(0xFF3A5BA9),
        onPrimary: Color(0xFFFFFFFF),
        primaryContainer: Color(0xFFDAE2FF),
        onPrimaryContainer: Color(0xFF001848),
      );
      const a = Appearance(colours: ColourSource.wallpaper, pureBlack: true);
      final light = a.palette(scheme, brightness: Brightness.light);
      expect(light.brightness, Brightness.light);
      expect(light.accent, scheme.primary);
      expect(light.background, OmniPalette.tealLight.background);
      expect(a.palette(null).background, Colors.black);
    });
  });

  group('light theme smoke', () {
    Future<void> lightApp(WidgetTester tester, FakeEngine engine) async {
      phoneIs(tester, Brightness.light);
      await pumpApp(tester, engine);
      expect(
        shown(tester, find.byKey(const ValueKey('shell-tabs'))),
        Brightness.light,
      );
    }

    testWidgets('Home, Devices, Automations and Settings draw in light', (
      tester,
    ) async {
      final engine = household()
        ..answers['automation.list'] = {
          'ok': true,
          'automations': automationRows(),
        };
      await lightApp(tester, engine);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      for (final tab in ['Devices', 'Automations', 'Settings']) {
        await openTab(tester, tab);
        expect(tester.takeException(), isNull, reason: tab);
        await expectLater(
          tester,
          meetsGuideline(textContrastGuideline),
          reason: tab,
        );
      }
    });

    testWidgets('a light page, the TV and the editor draw in light', (
      tester,
    ) async {
      for (final (name, engine, page) in [
        ('light', household(), const DeviceRoute(id: 'desk_lamp')),
        ('tv', household(), const DeviceRoute(id: 'lounge_tv')),
        ('editor', automationsEngine(), const RuleEditorPage(initial: _rule)),
      ]) {
        await pumpScreen(tester, engine, page, brightness: Brightness.light);
        expect(tester.takeException(), isNull, reason: name);
        expect(
          shown(tester, find.byWidget(page)),
          Brightness.light,
          reason: name,
        );
        await expectLater(
          tester,
          meetsGuideline(textContrastGuideline),
          reason: name,
        );
      }
    });
  });

  group('light contrast', () {
    const p = OmniPalette.tealLight;

    test('text and muted read at AA on every light surface, the accent '
        'and red on all but the top of a stack', () {
      for (final surface in [
        p.background,
        p.bar,
        p.card,
        p.raised,
        p.highest,
      ]) {
        for (final fg in [
          p.text,
          p.muted,
          if (surface != p.highest) ...[p.accent, p.bad],
        ]) {
          expect(
            contrastRatio(fg, surface),
            greaterThanOrEqualTo(4.5),
            reason: '$fg on $surface',
          );
        }
      }
    });

    test('step headings, the hero and status colours read at AA', () {
      final pairs = <(Color, Color)>[
        (p.trigger, p.triggerSoft),
        (p.condition, p.conditionSoft),
        (p.action, p.actionSoft),
        (p.flowControl, p.flowSoft),
        (p.warn, p.card),
        (p.info, p.card),
        (p.text, p.heroTop),
        (p.onAccentSoft, p.heroTop),
        (p.text, p.heroBottom),
        (p.onSliderFill, p.sliderFill),
        (LightWhite.onWarm, LightWhite.warm),
        (LightWhite.onWarm, LightWhite.cool),
      ];
      for (final (fg, bg) in pairs) {
        expect(
          contrastRatio(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$fg on $bg',
        );
      }
    });

    test('card colours keep white text, and a lit tile keeps dark text', () {
      for (final c in OmniCardColors.all) {
        expect(
          contrastRatio(OmniCardColors.onCard, c),
          greaterThanOrEqualTo(4.5),
        );
      }
      for (final tint in [LightWhite.warm, LightWhite.cool, p.accent]) {
        final lit = mutedTint(tint, p.card, amount: 0.38);
        expect(contrastRatio(p.text, lit), greaterThanOrEqualTo(4.5));
        expect(
          contrastRatio(OmniDepth.captionOn(lit, palette: p), lit),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('icons and marks reach 3 to 1 on a light card', () {
      expect(contrastRatio(p.accent, p.background), greaterThanOrEqualTo(3));
      expect(contrastRatio(p.muted, p.card), greaterThanOrEqualTo(3));
      expect(contrastRatio(RunColors.ran(p), p.card), greaterThanOrEqualTo(3));
    });
  });
}
