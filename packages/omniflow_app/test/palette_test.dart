import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/theme.dart';

void main() {
  test('the app theme stays dark, and a light one can be built', () {
    final dark = omniTheme();
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(dark.extension<OmniPalette>(), same(OmniPalette.teal));

    final light = omniTheme(brightness: Brightness.light);
    expect(light.colorScheme.brightness, Brightness.light);
    expect(light.extension<OmniPalette>(), same(OmniPalette.tealLight));
    expect(light.colorScheme.surface, const Color(0xFFF5FAF8));
    expect(light.textTheme.bodyMedium!.color, OmniPalette.tealLight.text);
  });

  for (final (name, p) in [
    ('dark', OmniPalette.teal),
    ('light', OmniPalette.tealLight),
  ]) {
    test('$name text and step colours read at AA on their surfaces', () {
      final pairs = <(Color, Color)>[
        (p.text, p.background),
        (p.text, p.card),
        (p.muted, p.card),
        (p.onAccent, p.accent),
        (p.onAccentSoft, p.accentSoft),
        (p.trigger, p.triggerSoft),
        (p.condition, p.conditionSoft),
        (p.bad, p.badSoft),
        (p.warn, p.warnSoft),
        (p.info, p.infoSoft),
        (p.onSliderFill, p.sliderFill),
      ];
      for (final (fg, bg) in pairs) {
        expect(
          contrastRatio(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$fg on $bg',
        );
      }
    });
  }

  test('white reads at AA on every automation card colour', () {
    expect(OmniCardColors.all, hasLength(7));
    for (final c in OmniCardColors.all) {
      expect(
        contrastRatio(OmniCardColors.onCard, c),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('text styles carry no colour of their own', () {
    for (final s in [
      OmniText.body,
      OmniText.bodySmall,
      OmniText.bodyStrong,
      OmniText.largeTitle,
      OmniText.section,
      OmniText.cardTitle,
      OmniText.reading,
      OmniText.step,
      OmniText.button,
    ]) {
      expect(s.color, isNull);
    }
  });
}
