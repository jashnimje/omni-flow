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

/// The source values of the dark teal palette ([OmniPalette.teal]). Every
/// text and icon pair meets WCAG AA on the surface it sits on. Nothing
/// outside this file reads them: screens read [OmniPalette.of], so they
/// follow the Appearance setting and the theme's brightness.
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

/// The colours that follow the Appearance setting and the theme's
/// brightness: the accent family, the surfaces, the text, and the step
/// and status colours. Read with [OmniPalette.of]; the theme carries one.
/// Screens read colours here rather than from [OmniColors], so the light
/// theme ([tealLight]) can ship once every screen does.
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
    this.brightness = Brightness.dark,
    this.highest = OmniSurface.highest,
    this.text = OmniColors.text,
    this.muted = OmniColors.muted,
    this.sliderFill = OmniColors.sliderFill,
    this.onSliderFill = OmniColors.text,
    this.trigger = OmniColors.trigger,
    this.triggerSoft = OmniColors.triggerSoft,
    this.condition = OmniColors.condition,
    this.conditionSoft = OmniColors.conditionSoft,
    this.actionSoft = OmniColors.actionSoft,
    this.flowControl = OmniColors.flowControl,
    this.flowSoft = OmniColors.flowSoft,
    this.flowLine = OmniColors.flowLine,
    this.transformer = OmniColors.transformer,
    this.warn = OmniColors.warn,
    this.warnSoft = OmniColors.warnSoft,
    this.bad = OmniColors.bad,
    this.onBad = OmniColors.onBad,
    this.badSoft = OmniColors.badSoft,
    this.badLine = OmniColors.badLine,
    this.info = OmniColors.info,
    this.infoSoft = OmniColors.infoSoft,
    this.scrim = OmniColors.scrim,
  });

  /// The OmniFlow look, dark.
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

  /// The OmniFlow look, light (docs/ui/design-v2.md, Colour).
  static const tealLight = OmniPalette(
    brightness: Brightness.light,
    accent: Color(0xFF006A60),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFA5F2E3),
    onAccentSoft: Color(0xFF00201C),
    accentLine: Color(0xFF338F83),
    heroTop: Color(0xFFA5F2E3),
    heroBottom: Color(0xFFC9F3EA),
    background: Color(0xFFF5FAF8),
    bar: Color(0xFFEBF1EF),
    card: Color(0xFFE3EAE8),
    raised: Color(0xFFD7DFDD),
    highest: Color(0xFFCDD6D3),
    sheet: Color(0xFFEBF1EF),
    line: Color(0xFFC5CFCC),
    text: Color(0xFF161D1C),
    muted: Color(0xFF3F4947),
    sliderFill: Color(0xFFA5F2E3),
    onSliderFill: Color(0xFF00201C),
    trigger: Color(0xFF6E3F00),
    triggerSoft: Color(0xFFFFDDB8),
    condition: Color(0xFF5A3EB0),
    conditionSoft: Color(0xFFE8DDFF),
    actionSoft: Color(0xFFA5F2E3),
    flowControl: Color(0xFFA1235A),
    flowSoft: Color(0xFFFFD9E2),
    flowLine: Color(0xFFE8A6BE),
    transformer: Color(0xFF1E58C2),
    warn: Color(0xFF7A5900),
    warnSoft: Color(0xFFFFDEA6),
    bad: Color(0xFFBA1A1A),
    onBad: Color(0xFFFFFFFF),
    badSoft: Color(0xFFFFDAD6),
    badLine: Color(0xFFE8A9A3),
    info: Color(0xFF00639B),
    infoSoft: Color(0xFFCDE5FF),
    scrim: Color(0x66000000),
  );

  final Brightness brightness;
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

  /// The top of a stack, one tone above [raised].
  final Color highest;
  final Color sheet;
  final Color line;

  /// Body text and icons on every surface here.
  final Color text;

  /// Secondary text (a subtitle, a summary) and quiet icons.
  final Color muted;

  /// A slider's flat fill, and the text that sits on it.
  final Color sliderFill;
  final Color onSliderFill;

  /// WHEN, ONLY IF and THEN: each step colour and its soft background.
  final Color trigger;
  final Color triggerSoft;
  final Color condition;
  final Color conditionSoft;
  final Color actionSoft;
  final Color flowControl;
  final Color flowSoft;
  final Color flowLine;
  final Color transformer;

  final Color warn;
  final Color warnSoft;
  final Color bad;
  final Color onBad;
  final Color badSoft;
  final Color badLine;
  final Color info;
  final Color infoSoft;
  final Color scrim;

  /// THEN steps wear the accent.
  Color get action => accent;

  bool get isDark => brightness == Brightness.dark;

  static OmniPalette of(BuildContext context) =>
      Theme.of(context).extension<OmniPalette>() ?? teal;

  /// The teal palette [surface] belongs to, light or dark by its
  /// luminance, for colour maths with no [BuildContext].
  static OmniPalette forSurface(Color surface) =>
      surface.computeLuminance() > 0.18 ? tealLight : teal;

  /// The same accent on black surfaces, for OLED screens.
  OmniPalette pureBlack() => copyWith(
    background: Colors.black,
    bar: const Color(0xFF08090B),
    card: const Color(0xFF111317),
    raised: const Color(0xFF1B1F25),
    highest: const Color(0xFF232830),
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
    Brightness? brightness,
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
    Color? highest,
    Color? sheet,
    Color? line,
    Color? text,
    Color? muted,
    Color? sliderFill,
    Color? onSliderFill,
    Color? trigger,
    Color? triggerSoft,
    Color? condition,
    Color? conditionSoft,
    Color? actionSoft,
    Color? flowControl,
    Color? flowSoft,
    Color? flowLine,
    Color? transformer,
    Color? warn,
    Color? warnSoft,
    Color? bad,
    Color? onBad,
    Color? badSoft,
    Color? badLine,
    Color? info,
    Color? infoSoft,
    Color? scrim,
  }) => OmniPalette(
    brightness: brightness ?? this.brightness,
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
    highest: highest ?? this.highest,
    sheet: sheet ?? this.sheet,
    line: line ?? this.line,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    sliderFill: sliderFill ?? this.sliderFill,
    onSliderFill: onSliderFill ?? this.onSliderFill,
    trigger: trigger ?? this.trigger,
    triggerSoft: triggerSoft ?? this.triggerSoft,
    condition: condition ?? this.condition,
    conditionSoft: conditionSoft ?? this.conditionSoft,
    actionSoft: actionSoft ?? this.actionSoft,
    flowControl: flowControl ?? this.flowControl,
    flowSoft: flowSoft ?? this.flowSoft,
    flowLine: flowLine ?? this.flowLine,
    transformer: transformer ?? this.transformer,
    warn: warn ?? this.warn,
    warnSoft: warnSoft ?? this.warnSoft,
    bad: bad ?? this.bad,
    onBad: onBad ?? this.onBad,
    badSoft: badSoft ?? this.badSoft,
    badLine: badLine ?? this.badLine,
    info: info ?? this.info,
    infoSoft: infoSoft ?? this.infoSoft,
    scrim: scrim ?? this.scrim,
  );

  @override
  OmniPalette lerp(OmniPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return OmniPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
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
      highest: mix(highest, other.highest),
      sheet: mix(sheet, other.sheet),
      line: mix(line, other.line),
      text: mix(text, other.text),
      muted: mix(muted, other.muted),
      sliderFill: mix(sliderFill, other.sliderFill),
      onSliderFill: mix(onSliderFill, other.onSliderFill),
      trigger: mix(trigger, other.trigger),
      triggerSoft: mix(triggerSoft, other.triggerSoft),
      condition: mix(condition, other.condition),
      conditionSoft: mix(conditionSoft, other.conditionSoft),
      actionSoft: mix(actionSoft, other.actionSoft),
      flowControl: mix(flowControl, other.flowControl),
      flowSoft: mix(flowSoft, other.flowSoft),
      flowLine: mix(flowLine, other.flowLine),
      transformer: mix(transformer, other.transformer),
      warn: mix(warn, other.warn),
      warnSoft: mix(warnSoft, other.warnSoft),
      bad: mix(bad, other.bad),
      onBad: mix(onBad, other.onBad),
      badSoft: mix(badSoft, other.badSoft),
      badLine: mix(badLine, other.badLine),
      info: mix(info, other.info),
      infoSoft: mix(infoSoft, other.infoSoft),
      scrim: mix(scrim, other.scrim),
    );
  }
}

/// The warm and cool ends of a light's white, for warmth sliders and the
/// tint of a white light's tile. They are the colours of the light itself,
/// so they stay the same in the dark and the light theme.
abstract final class LightWhite {
  static const warm = Color(0xFFFFB86B);
  static const cool = Color(0xFFFFE7C2);

  /// Text on either end, at AA.
  static const onWarm = Color(0xFF2A1A00);

  /// The warmth slider's fill, warm to cool. [mired] runs the other way.
  static const kelvin = LinearGradient(colors: [warm, cool]);
  static const mired = LinearGradient(colors: [cool, warm]);
}

/// The seven fixed colours an automation or scene card can wear
/// (docs/ui/design-v2.md, Colour). Each passes 4.5 to 1 with white text
/// in both themes, so a card's name and summary are always [onCard].
abstract final class OmniCardColors {
  static const violet = Color(0xFF5B45C9);
  static const orange = Color(0xFFA8430C);
  static const teal = Color(0xFF00706A);
  static const blue = Color(0xFF1E58C2);
  static const pink = Color(0xFFA1235A);
  static const green = Color(0xFF2B6E30);
  static const slate = Color(0xFF45505E);

  /// The text and icons on every card colour.
  static const onCard = Color(0xFFFFFFFF);

  /// In picker order.
  static const all = [violet, orange, teal, blue, pink, green, slate];
}

/// The WCAG contrast ratio of two colours, 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [tint] blended [amount] of the way into [surface], backing off until
/// [text] on it still reads at AA (4.5 to 1). A bright yellow light gives
/// a muted amber tile, not a yellow one. [text] defaults to the body text
/// of the theme [surface] belongs to.
Color mutedTint(
  Color tint,
  Color surface, {
  double amount = 0.35,
  Color? text,
}) {
  text ??= OmniPalette.forSurface(surface).text;
  var a = amount;
  var mixed = Color.lerp(surface, tint, a)!;
  while (a > 0 && contrastRatio(mixed, text) < 4.5) {
    a = math.max(0, a - 0.03);
    mixed = Color.lerp(surface, tint, a)!;
  }
  return mixed;
}

/// Depth by tone (docs/ui/design-v2.md, Tonal elevation): a card or tile
/// is a lighter surface than the screen with a near-clear edge, and has no
/// shadow and no sheen. [shadow] stays only on the floating button and
/// sheets. A tile with a colour of its own (a scene, a room) takes a wash
/// of that colour from its top corner. Text on every surface here stays
/// at AA (4.5 to 1).
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
  /// when the theme's body text would drop below AA.
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

  /// The colour for small grey text (a caption) on [surface]: [palette]'s
  /// muted where it reads at AA, else nearer its body text until it does.
  /// [palette] defaults to the teal one [surface] belongs to.
  static Color captionOn(Color surface, {OmniPalette? palette}) {
    final p = palette ?? OmniPalette.forSurface(surface);
    final top = litTop(surface);
    // The worse of the plain surface and its lit top: the top for light
    // text, the plain surface for dark text.
    double worst(Color c) =>
        math.min(contrastRatio(c, top), contrastRatio(c, surface));
    var t = 0.0;
    var c = p.muted;
    while (t < 1 && worst(c) < 4.5) {
      t = math.min(1, t + 0.05);
      c = Color.lerp(p.muted, p.text, t)!;
    }
    return c;
  }

  /// A card or tile surface: [color] (or [gradient]), its [border] (the
  /// clear [edge] by default) and the [radius]. [lifted] adds the
  /// [shadow], for something that floats over the page.
  static BoxDecoration surface({
    required Color color,
    required BorderRadius radius,
    Gradient? gradient,
    Color? border,
    bool lifted = false,
  }) => BoxDecoration(
    color: gradient == null ? color : null,
    gradient: gradient,
    borderRadius: radius,
    border: Border.all(color: border ?? edgeOn(color)),
    boxShadow: lifted ? shadow : null,
  );
}

/// Dark ink or light text, whichever reads better on [background].
Color inkOn(Color background) {
  const dark = OmniSurface.lowest;
  final light = OmniPalette.teal.text;
  return contrastRatio(background, dark) >= contrastRatio(background, light)
      ? dark
      : light;
}

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

/// The same bars over the light screens: dark icons.
const omniSystemBarsLight = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarContrastEnforced: false,
);

/// The system bars for the current theme's brightness.
SystemUiOverlayStyle omniSystemBarsOf(BuildContext context) =>
    OmniPalette.of(context).isDark ? omniSystemBars : omniSystemBarsLight;

/// The 4 dp grid, with 8 as the main step (docs/ui/design-v2.md,
/// Spacing). Screen margins are 16 on a compact phone.
abstract final class OmniSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const screen = 16.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 40.0;

  /// The smallest touch target.
  static const target = 48.0;

  /// The target of a primary control: power, a D-pad key, a scene's Run,
  /// Save.
  static const targetLarge = 56.0;

  /// A one-line list row and a two-line one (title and subtitle).
  static const row = 56.0;
  static const rowTwoLine = 72.0;

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
/// [lgPlus] (24) sits between large and extra large, for tiles and
/// cards.
abstract final class OmniShape {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const lgIncreased = 20.0;
  static const lgPlus = 24.0;
  static const xl = 28.0;
  static const full = 999.0;
}

/// Where each component sits on [OmniShape].
abstract final class OmniRadii {
  static const tile = OmniShape.lgPlus;
  static const card = OmniShape.lgPlus;

  /// An [OmniDisclosure] card.
  static const section = OmniShape.lgPlus;
  static const hero = OmniShape.xl;
  static const sheet = OmniShape.xl;
  static const button = OmniShape.full;
  static const fab = OmniShape.lg;
  static const banner = OmniShape.lg;
  static const segmented = OmniShape.full;
  static const segment = OmniShape.full;

  /// An editor block (When, Only if, Then).
  static const step = OmniShape.lgIncreased;
  static const field = OmniShape.md;
  static const iconBox = OmniShape.md;
  static const tooltip = OmniShape.sm;
  static const handle = OmniShape.xs;
  static const chip = OmniShape.full;
}

/// The Material 3 type scale (docs/ui/design-v2.md, Type). Body text is
/// 16, subtitles and summaries in front are 14, and 12 is only for
/// navigation labels and tags on cards. Page titles open at 32 and shrink
/// to 22 as the page scrolls. Numbers use tabular figures.
///
/// The styles carry no colour: text takes it from the theme
/// ([OmniPalette.text] through the theme's text styles), which is what
/// lets a light theme work. A style that needs another colour sets it
/// with `copyWith(color: OmniPalette.of(context).muted)`, or reads
/// [captionOf].
abstract final class OmniText {
  static const _tabular = [FontFeature.tabularFigures()];

  static const displaySmall = TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.w500,
    height: 1.2,
    fontFeatures: _tabular,
  );
  static const headlineLarge = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
  static const headlineMedium = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
  static const headlineSmall = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const titleLarge = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
  static const titleMedium = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
  static const titleSmall = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
  static const labelMedium = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );

  /// The open size of a page's title, on tab roots and pushed pages alike.
  static const largeTitle = headlineLarge;
  static const screenTitle = titleLarge;
  static const pageTitle = titleLarge;

  /// The state card's reading ("On · 60%") and a tile's main reading (a
  /// temperature, the app on a TV).
  static const reading = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.2,
    fontFeatures: _tabular,
  );
  static const heroTitle = reading;

  /// The header above a group of rows or tiles.
  static const section = TextStyle(fontSize: 18, fontWeight: FontWeight.w600);

  /// An automation card's name: 18 so a two-word name fits one line on a
  /// 184 dp card at 100 % and wraps cleanly at 200 %.
  static const cardTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );

  /// Body Large, the size of every row title and paragraph.
  static const body = TextStyle(fontSize: 16);

  /// Dense lists inside a section (Activity, Developer details).
  static const bodySmall = TextStyle(fontSize: 14);
  static const bodyStrong = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
  static const label = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

  /// A button's label.
  static const button = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);

  /// A subtitle or summary in front: Body Medium, 14. Set its colour, or
  /// read [captionOf] for the theme's muted grey.
  static const caption = TextStyle(fontSize: 14);

  /// [caption] in the current theme's muted colour.
  static TextStyle captionOf(BuildContext context) =>
      caption.copyWith(color: OmniPalette.of(context).muted);

  /// A navigation label.
  static const navLabel = TextStyle(fontSize: 12);
  static const number = TextStyle(fontSize: 14, fontFeatures: _tabular);

  /// A tag on a card and a block's WHEN / ONLY IF / THEN heading.
  static const blockHeading = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
  );
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.6,
  );

  /// The words of a rule step in an editor block: 18 on a 28 line.
  static const step = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w500,
    height: 28 / 18,
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
