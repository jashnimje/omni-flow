import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

/// The five tonal surface levels, darkest first. A screen sits on
/// [lowest], bars on [low], cards on [container], raised parts (an icon
/// box, a pressed field) on [high], and the top of a stack on [highest].
abstract final class OmniSurface {
  static const lowest = Color(0xFF0D0F12);
  static const low = Color(0xFF14171C);
  static const container = Color(0xFF1A1E24);
  static const high = Color(0xFF222831);
  static const highest = Color(0xFF283039);
}

/// The colours of docs/ui/ui-spec.md (Design system). Every text and icon
/// pair used by the components meets WCAG AA on the surface it sits on.
/// Components that follow the Appearance setting read [OmniPalette]
/// instead; these stay the teal defaults.
abstract final class OmniColors {
  static const background = OmniSurface.lowest;
  static const bar = OmniSurface.low;
  static const card = OmniSurface.container;
  static const raised = OmniSurface.high;
  static const sheet = OmniSurface.low;
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

  /// The warm and cool ends of a light's white, for warmth sliders and
  /// the tint of a white light's tile.
  static const warmWhite = Color(0xFFFFB86B);
  static const coolWhite = Color(0xFFFFE7C2);
  static const onWarmWhite = Color(0xFF2A1A00);

  static const trigger = Color(0xFFFF9F1C);
  static const condition = Color(0xFFB18CFF);
  static const transformer = Color(0xFF3A86FF);
  static const flowControl = Color(0xFFFF5C9A);
  static const action = accent;
  static const warn = Color(0xFFFFB547);
  static const bad = Color(0xFFFF6B6B);
  static const onBad = Color(0xFF3A0A0A);
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

/// The colours that follow the Appearance setting: the accent family and
/// the surfaces. Read with [OmniPalette.of]; the theme carries one.
@immutable
class OmniPalette extends ThemeExtension<OmniPalette> {
  const OmniPalette({
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.accentLine,
    required this.heroTop,
    required this.heroBottom,
    required this.background,
    required this.bar,
    required this.card,
    required this.raised,
    required this.sheet,
    required this.line,
  });

  /// The OmniFlow look.
  static const teal = OmniPalette(
    accent: OmniColors.accent,
    onAccent: OmniColors.accentInk,
    accentSoft: OmniColors.accentSoft,
    onAccentSoft: OmniColors.onAccentSoft,
    accentLine: OmniColors.accentLine,
    heroTop: OmniColors.heroTop,
    heroBottom: OmniColors.heroBottom,
    background: OmniColors.background,
    bar: OmniColors.bar,
    card: OmniColors.card,
    raised: OmniColors.raised,
    sheet: OmniColors.sheet,
    line: OmniColors.line,
  );

  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color onAccentSoft;
  final Color accentLine;
  final Color heroTop;
  final Color heroBottom;
  final Color background;
  final Color bar;
  final Color card;
  final Color raised;
  final Color sheet;
  final Color line;

  static OmniPalette of(BuildContext context) =>
      Theme.of(context).extension<OmniPalette>() ?? teal;

  /// The same accent on black surfaces, for OLED screens.
  OmniPalette pureBlack() => copyWith(
    background: Colors.black,
    bar: const Color(0xFF08090B),
    card: const Color(0xFF111317),
    raised: const Color(0xFF1B1F25),
    sheet: const Color(0xFF0B0C0F),
    line: const Color(0xFF242A32),
  );

  /// The accent family from a wallpaper's dark colour scheme, on the
  /// OmniFlow surfaces.
  OmniPalette withScheme(ColorScheme scheme) => copyWith(
    accent: scheme.primary,
    onAccent: scheme.onPrimary,
    accentSoft: scheme.primaryContainer,
    onAccentSoft: scheme.onPrimaryContainer,
    accentLine: Color.lerp(scheme.primaryContainer, scheme.primary, 0.35),
    heroTop: Color.lerp(card, scheme.primaryContainer, 0.85),
    heroBottom: Color.lerp(card, scheme.primaryContainer, 0.5),
  );

  @override
  OmniPalette copyWith({
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? onAccentSoft,
    Color? accentLine,
    Color? heroTop,
    Color? heroBottom,
    Color? background,
    Color? bar,
    Color? card,
    Color? raised,
    Color? sheet,
    Color? line,
  }) => OmniPalette(
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    accentSoft: accentSoft ?? this.accentSoft,
    onAccentSoft: onAccentSoft ?? this.onAccentSoft,
    accentLine: accentLine ?? this.accentLine,
    heroTop: heroTop ?? this.heroTop,
    heroBottom: heroBottom ?? this.heroBottom,
    background: background ?? this.background,
    bar: bar ?? this.bar,
    card: card ?? this.card,
    raised: raised ?? this.raised,
    sheet: sheet ?? this.sheet,
    line: line ?? this.line,
  );

  @override
  OmniPalette lerp(OmniPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return OmniPalette(
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccentSoft: mix(onAccentSoft, other.onAccentSoft),
      accentLine: mix(accentLine, other.accentLine),
      heroTop: mix(heroTop, other.heroTop),
      heroBottom: mix(heroBottom, other.heroBottom),
      background: mix(background, other.background),
      bar: mix(bar, other.bar),
      card: mix(card, other.card),
      raised: mix(raised, other.raised),
      sheet: mix(sheet, other.sheet),
      line: mix(line, other.line),
    );
  }
}

/// The WCAG contrast ratio of two colours, 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [tint] blended [amount] of the way into [surface], backing off until
/// [text] on it still reads at AA (4.5 to 1). A bright yellow light gives
/// a muted amber tile, not a yellow one.
Color mutedTint(
  Color tint,
  Color surface, {
  double amount = 0.35,
  Color text = OmniColors.text,
}) {
  var a = amount;
  var mixed = Color.lerp(surface, tint, a)!;
  while (a > 0 && contrastRatio(mixed, text) < 4.5) {
    a = math.max(0, a - 0.03);
    mixed = Color.lerp(surface, tint, a)!;
  }
  return mixed;
}

/// The depth every card and tile wears (Home look C in
/// docs/ui/home-modern-mockups.html): a faint light along the top, a soft
/// shadow under it and a near-clear edge. A tile with a colour of its own
/// (a scene, a room) also takes a wash of that colour from its top
/// corner. Text on every surface here stays at AA (4.5 to 1).
abstract final class OmniDepth {
  /// White at 4.5 %, fading out 40 % of the way down.
  static const highlight = Color(0x0BFFFFFF);
  static const highlightEnd = 0.4;

  /// White at 6 %, the edge of a card or tile without a colour.
  static const edge = Color(0x0FFFFFFF);

  /// How much of a tile's own colour shows at its top corner and where
  /// the wash ends.
  static const washTop = 0.30;
  static const washBottom = 0.06;
  static const washEnd = 0.7;

  static const shadow = [
    BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8)),
  ];

  /// The light along the top, laid over a surface's own fill.
  static const sheen = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [highlight, Color(0x00FFFFFF)],
    stops: [0, highlightEnd],
  );

  /// [edge] over [surface], as one solid colour for a border.
  static Color edgeOn(Color surface) => Color.alphaBlend(edge, surface);

  /// The top corner of [tint]'s wash on [surface]: [washTop] of it, less
  /// when [OmniColors.text] would drop below AA.
  static Color washTopOf(Color tint, Color surface) =>
      mutedTint(tint, surface, amount: washTop);

  /// A wash of [tint] on [surface], from the top left (strong) to 70 %
  /// down (faint), as solid colours so it lerps when a tile changes.
  static LinearGradient wash(Color tint, Color surface) => LinearGradient(
    begin: const Alignment(-0.7, -1),
    end: const Alignment(0.7, 1),
    colors: [washTopOf(tint, surface), Color.lerp(surface, tint, washBottom)!],
    stops: const [0, washEnd],
  );

  /// The brightest point of a surface of [fill] under the [sheen].
  static Color litTop(Color fill) => Color.alphaBlend(highlight, fill);

  /// The colour for small grey text (a caption) on [surface]: the usual
  /// [OmniColors.muted] where it reads at AA, else lighter until it does.
  static Color captionOn(Color surface) {
    final top = litTop(surface);
    var t = 0.0;
    var c = OmniColors.muted;
    while (t < 1 && contrastRatio(c, top) < 4.5) {
      t = math.min(1, t + 0.05);
      c = Color.lerp(OmniColors.muted, OmniColors.text, t)!;
    }
    return c;
  }

  /// A card or tile surface: [color] (or [gradient]), its [border] (the
  /// clear [edge] by default), the [radius] and the [shadow].
  static BoxDecoration surface({
    required Color color,
    required BorderRadius radius,
    Gradient? gradient,
    Color? border,
    bool lifted = true,
  }) => BoxDecoration(
    color: gradient == null ? color : null,
    gradient: gradient,
    borderRadius: radius,
    border: Border.all(color: border ?? edgeOn(color)),
    boxShadow: lifted ? shadow : null,
  );
}

/// Dark ink or light text, whichever reads better on [background].
Color inkOn(Color background) =>
    contrastRatio(background, OmniColors.background) >=
        contrastRatio(background, OmniColors.text)
    ? OmniColors.background
    : OmniColors.text;

/// The status and navigation bars over OmniFlow's dark screens: see
/// through, with light icons, so pages draw edge to edge under them.
const omniSystemBars = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);

/// The 4 pt grid.
abstract final class OmniSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const gap = 10.0;
  static const md = 12.0;
  static const screen = 14.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 40.0;

  /// The smallest touch target.
  static const target = 48.0;

  static const screenPadding = EdgeInsets.symmetric(horizontal: screen);
}

/// Space a screen leaves for the system bars and floating buttons, from
/// the real insets rather than fixed numbers.
abstract final class OmniInsets {
  /// The extended floating button and its margins.
  static const _fab = 56.0 + OmniSpace.lg + OmniSpace.xl;

  /// The bottom padding a scrolling list needs so its last row clears the
  /// floating button and the gesture bar.
  static double fabClearance(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + _fab;

  /// The bottom padding of a list with no floating button.
  static double bottom(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + OmniSpace.xl;
}

/// The corner scale of Material 3: extra small to extra large, then full.
abstract final class OmniShape {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 28.0;
  static const full = 999.0;
}

/// Where each component sits on [OmniShape].
abstract final class OmniRadii {
  static const tile = OmniShape.lg;
  static const card = OmniShape.lg;
  static const hero = OmniShape.xl;
  static const sheet = OmniShape.xl;
  static const button = OmniShape.md;
  static const fab = OmniShape.lg;
  static const banner = OmniShape.md;
  static const segmented = OmniShape.md;
  static const segment = OmniShape.sm;
  static const step = OmniShape.md;
  static const field = OmniShape.md;
  static const iconBox = OmniShape.md;
  static const tooltip = OmniShape.sm;
  static const handle = OmniShape.xs;
  static const chip = OmniShape.full;
}

/// The type scale. Nothing is below 12. Page titles are 22 (title large),
/// tab titles open at 28 (headline medium) and shrink to 22 as the page
/// scrolls. Numbers use tabular figures.
abstract final class OmniText {
  static const _tabular = [FontFeature.tabularFigures()];

  static const displaySmall = TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.w500,
    color: OmniColors.text,
    height: 1.2,
    fontFeatures: _tabular,
  );
  static const headlineLarge = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    height: 1.25,
  );
  static const headlineMedium = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    height: 1.25,
  );
  static const headlineSmall = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    height: 1.3,
  );
  static const titleLarge = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    height: 1.25,
  );
  static const titleMedium = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const titleSmall = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const labelMedium = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );

  /// The open size of a tab's title.
  static const largeTitle = headlineMedium;
  static const screenTitle = titleLarge;
  static const pageTitle = titleLarge;

  /// A tile's or hero's main reading: a temperature, the app on a TV.
  static const reading = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    height: 1.2,
    fontFeatures: _tabular,
  );
  static const heroTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
    height: 1.25,
    fontFeatures: _tabular,
  );
  static const section = titleSmall;
  static const body = TextStyle(fontSize: 14, color: OmniColors.text);
  static const bodyLarge = TextStyle(fontSize: 16, color: OmniColors.text);
  static const bodyStrong = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const label = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: OmniColors.text,
  );
  static const caption = TextStyle(fontSize: 12, color: OmniColors.muted);
  static const navLabel = TextStyle(fontSize: 12, color: OmniColors.muted);
  static const number = TextStyle(
    fontSize: 12,
    color: OmniColors.text,
    fontFeatures: _tabular,
  );
  static const blockHeading = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
  );
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.6,
    color: OmniColors.text,
  );
}

/// A spring from Material 3 Expressive, as a [curve] and the [duration]
/// it takes to settle, for the implicit animations that take a curve.
@immutable
class OmniSpring {
  const OmniSpring({required this.stiffness, required this.dampingRatio});

  final double stiffness;
  final double dampingRatio;

  SpringDescription get description => SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: stiffness,
    ratio: dampingRatio,
  );

  /// How long the spring takes to come within a thousandth of rest.
  Duration get duration {
    final sim = SpringSimulation(
      description,
      0,
      1,
      0,
      tolerance: const Tolerance(distance: 0.001, velocity: 0.01),
    );
    var t = 0.0;
    while (!sim.isDone(t) && t < 2) {
      t += 0.01;
    }
    return Duration(milliseconds: (t * 1000).round());
  }

  Curve get curve => _SpringCurve(this);
}

class _SpringCurve extends Curve {
  _SpringCurve(this.spring)
    : _sim = SpringSimulation(spring.description, 0, 1, 0),
      _seconds = spring.duration.inMicroseconds / 1e6;

  final OmniSpring spring;
  final SpringSimulation _sim;
  final double _seconds;

  @override
  double transformInternal(double t) => _sim.x(t * _seconds);
}

/// State changes and sheets take 150 to 250 ms, moves between screens use
/// the emphasized easing, and spatial motion (a tile pressed, a tab
/// arriving) uses springs. Nothing animates when the system asks for
/// reduced motion.
abstract final class OmniMotion {
  static const fast = Duration(milliseconds: 150);
  static const standard = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 250);
  static const medium = Duration(milliseconds: 300);
  static const long = Duration(milliseconds: 400);
  static const curve = Curves.easeInOutCubic;

  /// Something arriving on screen, and something leaving it.
  static const emphasizedIn = Easing.emphasizedDecelerate;
  static const emphasizedOut = Easing.emphasizedAccelerate;

  /// Expressive spatial springs: a little bounce, for things that move.
  static const springFast = OmniSpring(stiffness: 800, dampingRatio: 0.6);
  static const springDefault = OmniSpring(stiffness: 380, dampingRatio: 0.8);
  static const springSlow = OmniSpring(stiffness: 200, dampingRatio: 0.8);

  /// Effects springs: no bounce, for colour and opacity.
  static const effectsFast = OmniSpring(stiffness: 3800, dampingRatio: 1);
  static const effectsDefault = OmniSpring(stiffness: 1600, dampingRatio: 1);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or zero under reduced motion.
  static Duration of(BuildContext context, [Duration d = standard]) =>
      reduced(context) ? Duration.zero : d;
}

/// Window size classes: compact phones under 600, medium (a foldable, a
/// small tablet) under 840, expanded above.
enum OmniWidth {
  compact,
  medium,
  expanded;

  static const mediumFrom = 600.0;
  static const expandedFrom = 840.0;

  static OmniWidth forWidth(double width) => width < mediumFrom
      ? compact
      : width < expandedFrom
      ? medium
      : expanded;

  static OmniWidth of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);

  /// How many tiles a Home row holds.
  int get tileColumns => switch (this) {
    compact => 2,
    medium => 3,
    expanded => 4,
  };
}
