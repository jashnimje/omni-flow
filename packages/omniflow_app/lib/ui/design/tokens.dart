import 'package:flutter/material.dart';

/// The colours of docs/ui/ui-spec.md (Design system). Every text and icon
/// pair used by the components meets WCAG AA on the surface it sits on.
abstract final class OmniColors {
  static const background = Color(0xFF0D0F12);
  static const bar = Color(0xFF14171C);
  static const card = Color(0xFF1A1E24);
  static const raised = Color(0xFF222831);
  static const sheet = Color(0xFF181C22);
  static const line = Color(0xFF2A313B);
  static const text = Color(0xFFE8ECF1);
  static const muted = Color(0xFF8B95A3);

  static const accent = Color(0xFF00F5D4);
  static const accentInk = Color(0xFF00382F);
  static const accentSoft = Color(0xFF12403A);
  static const accentLine = Color(0xFF1D6B61);
  static const onAccentSoft = Color(0xFF9FF3E6);
  static const heroTop = Color(0xFF134A43);
  static const heroBottom = Color(0xFF0F2E2A);

  /// A slider's fill, dark enough for [text] on it to pass AA.
  static const sliderFill = Color(0xFF186A60);

  static const trigger = Color(0xFFFF9F1C);
  static const condition = Color(0xFFB18CFF);
  static const transformer = Color(0xFF3A86FF);
  static const flowControl = Color(0xFFFF5C9A);
  static const action = accent;
  static const warn = Color(0xFFFFB547);
  static const bad = Color(0xFFFF6B6B);
  static const info = Color(0xFF9FE0FF);

  static const triggerSoft = Color(0xFF3A2A10);
  static const conditionSoft = Color(0xFF2A2140);
  static const actionSoft = Color(0xFF0E3833);
  static const flowSoft = Color(0xFF3A1526);
  static const flowLine = Color(0xFF5A2A4A);
  static const infoSoft = Color(0xFF12303A);
  static const warnSoft = Color(0xFF3A2E12);
  static const badSoft = Color(0xFF3A1616);
  static const badLine = Color(0xFF5A2A2A);
  static const scrim = Color(0x99000000);
}

/// The 4 pt grid.
abstract final class OmniSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const gap = 10.0;
  static const md = 12.0;
  static const screen = 14.0;
  static const lg = 16.0;
  static const xl = 24.0;

  /// The smallest touch target.
  static const target = 48.0;

  static const screenPadding = EdgeInsets.symmetric(horizontal: screen);
}

abstract final class OmniRadii {
  static const tile = 18.0;
  static const card = 18.0;
  static const hero = 22.0;
  static const sheet = 22.0;
  static const button = 14.0;
  static const banner = 14.0;
  static const segmented = 12.0;
  static const step = 12.0;
  static const field = 12.0;
  static const iconBox = 10.0;
  static const chip = 999.0;
}

/// The type scale: screen titles 22, page titles 17, section titles 13,
/// body 14, captions 12. Numbers use tabular figures.
abstract final class OmniText {
  static const _tabular = [FontFeature.tabularFigures()];

  static const screenTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    height: 1.25,
  );
  static const pageTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const heroTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    fontFeatures: _tabular,
  );
  static const section = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const body = TextStyle(fontSize: 14, color: OmniColors.text);
  static const bodyStrong = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const caption = TextStyle(fontSize: 12, color: OmniColors.muted);
  static const number = TextStyle(
    fontSize: 12,
    color: OmniColors.text,
    fontFeatures: _tabular,
  );
  static const blockHeading = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.9,
  );
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.6,
    color: OmniColors.text,
  );
}

/// State changes and sheets take 150 to 250 ms, and nothing animates when
/// the system asks for reduced motion.
abstract final class OmniMotion {
  static const fast = Duration(milliseconds: 150);
  static const standard = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 250);
  static const curve = Curves.easeInOutCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or zero under reduced motion.
  static Duration of(BuildContext context, [Duration d = standard]) =>
      reduced(context) ? Duration.zero : d;
}
