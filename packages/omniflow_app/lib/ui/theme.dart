import 'package:flutter/material.dart';

import 'design/tokens.dart';

export 'design/tokens.dart';

/// The app's Material theme, from the design tokens, so plain Material
/// widgets (switches, app bars, dialogs, text fields) already match the
/// mockups. [palette] is the Appearance setting, light or dark: teal by
/// default, the wallpaper's colours, or dark teal on pure black. Asking for
/// the light [brightness] with the default teal uses
/// [OmniPalette.tealLight].
ThemeData omniTheme({
  OmniPalette palette = OmniPalette.teal,
  Brightness brightness = Brightness.dark,
}) {
  final p =
      brightness == Brightness.light && identical(palette, OmniPalette.teal)
      ? OmniPalette.tealLight
      : palette;
  final scheme = omniColorScheme(p);
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(OmniRadii.button),
  );
  const minTarget = Size(OmniSpace.target, OmniSpace.target);
  const largeTarget = Size(OmniSpace.targetLarge, OmniSpace.targetLarge);
  final bars = p.isDark ? omniSystemBars : omniSystemBarsLight;
  return ThemeData(
    brightness: p.brightness,
    colorScheme: scheme,
    extensions: [p],
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    dividerColor: p.line,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: _MotionAwareTransitions()},
    ),
    textTheme: omniTextTheme(p),
    iconTheme: IconThemeData(color: p.text, size: 22),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: OmniText.pageTitle.copyWith(color: p.text),
      iconTheme: IconThemeData(color: p.muted),
      actionsIconTheme: IconThemeData(color: p.muted),
      systemOverlayStyle: bars,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.bar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accentSoft,
      height: 80,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => OmniText.navLabel.copyWith(
          color: states.contains(WidgetState.selected) ? p.text : p.muted,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected) ? p.text : p.muted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.bar,
      indicatorColor: p.accentSoft,
      labelType: NavigationRailLabelType.all,
      selectedIconTheme: IconThemeData(color: p.text, size: 24),
      unselectedIconTheme: IconThemeData(color: p.muted, size: 24),
      selectedLabelTextStyle: OmniText.navLabel.copyWith(
        color: p.text,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: OmniText.navLabel.copyWith(color: p.muted),
    ),
    // The floating button keeps its shadow: it floats over the page.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.accent,
      foregroundColor: p.onAccent,
      elevation: 6,
      highlightElevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.fab),
      ),
      extendedTextStyle: OmniText.button,
    ),
    cardTheme: CardThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: OmniSpace.md),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.card),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.muted,
      textColor: p.text,
      minVerticalPadding: OmniSpace.md,
      minTileHeight: OmniSpace.row,
    ),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? p.muted.withValues(alpha: 0.5)
            : states.contains(WidgetState.selected)
            ? p.onAccent
            : p.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? p.raised.withValues(alpha: 0.5)
            : states.contains(WidgetState.selected)
            ? p.accent
            : p.raised,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? p.line.withValues(alpha: 0.5)
            : states.contains(WidgetState.selected)
            ? p.accent
            : p.muted,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.accent,
      inactiveTrackColor: p.raised,
      thumbColor: p.accent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.raised,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: largeTarget,
        shape: buttonShape,
        textStyle: OmniText.button,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.line),
        minimumSize: minTarget,
        shape: buttonShape,
        textStyle: OmniText.button,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: minTarget,
        shape: buttonShape,
        textStyle: OmniText.label,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: minTarget),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.card,
      labelStyle: TextStyle(color: p.muted),
      hintStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OmniRadii.field),
        borderSide: BorderSide(color: p.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OmniRadii.field),
        borderSide: BorderSide(color: p.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OmniRadii.field),
        borderSide: BorderSide(color: p.accent),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.card,
      selectedColor: p.accent,
      side: BorderSide(color: p.line),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.chip),
      ),
      labelStyle: TextStyle(fontSize: 14, color: p.text),
    ),
    // Sheets keep the Material shadow: they float over the page.
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.sheet,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: p.scrim,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(OmniRadii.sheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.sheet),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.raised,
      contentTextStyle: TextStyle(color: p.text, fontSize: 14),
      actionTextColor: p.accent,
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: const BorderRadius.all(
          Radius.circular(OmniRadii.tooltip),
        ),
      ),
      textStyle: TextStyle(color: p.text, fontSize: 14),
    ),
  );
}

/// The Material colour scheme of [p], dark or light by its brightness.
ColorScheme omniColorScheme(OmniPalette p) => ColorScheme(
  brightness: p.brightness,
  primary: p.accent,
  onPrimary: p.onAccent,
  primaryContainer: p.accentSoft,
  onPrimaryContainer: p.onAccentSoft,
  secondary: p.accent,
  onSecondary: p.onAccent,
  secondaryContainer: p.accentSoft,
  onSecondaryContainer: p.onAccentSoft,
  tertiary: p.condition,
  onTertiary: p.isDark ? p.background : Colors.white,
  tertiaryContainer: p.conditionSoft,
  onTertiaryContainer: p.condition,
  error: p.bad,
  onError: p.onBad,
  errorContainer: p.badSoft,
  onErrorContainer: p.bad,
  surface: p.background,
  onSurface: p.text,
  onSurfaceVariant: p.muted,
  surfaceDim: p.background,
  surfaceBright: p.raised,
  surfaceContainerLowest: p.background,
  surfaceContainerLow: p.bar,
  surfaceContainer: p.card,
  surfaceContainerHigh: p.raised,
  surfaceContainerHighest: p.highest,
  outline: p.muted,
  outlineVariant: p.line,
  inverseSurface: p.text,
  onInverseSurface: p.background,
  inversePrimary: p.accentSoft,
  shadow: Colors.black,
  scrim: Colors.black,
  surfaceTint: Colors.transparent,
);

/// The [OmniText] scale in [p]'s text colours: body text in
/// [OmniPalette.text], the small grey styles in [OmniPalette.muted]. Text
/// with no colour of its own takes these through [DefaultTextStyle].
TextTheme omniTextTheme(OmniPalette p) {
  TextStyle on(TextStyle s) => s.copyWith(color: p.text);
  TextStyle quiet(TextStyle s) => s.copyWith(color: p.muted);
  return TextTheme(
    displaySmall: on(OmniText.displaySmall),
    headlineLarge: on(OmniText.headlineLarge),
    headlineMedium: on(OmniText.headlineMedium),
    headlineSmall: on(OmniText.headlineSmall),
    titleLarge: on(OmniText.titleLarge),
    titleMedium: on(OmniText.titleMedium),
    titleSmall: on(OmniText.titleSmall),
    bodyLarge: on(OmniText.body),
    bodyMedium: on(OmniText.body),
    bodySmall: quiet(OmniText.caption),
    labelLarge: on(OmniText.label),
    labelMedium: on(OmniText.labelMedium),
    labelSmall: quiet(OmniText.navLabel),
  );
}

/// Android's page transitions, or none when the system asks for reduced
/// motion.
class _MotionAwareTransitions extends PageTransitionsBuilder {
  const _MotionAwareTransitions();

  static const _android = PredictiveBackPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _android.transitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition {
    final outgoing = _android.delegatedTransition;
    if (outgoing == null) return null;
    return (context, animation, secondary, allowSnapshotting, child) =>
        OmniMotion.reduced(context)
        ? child
        : outgoing(context, animation, secondary, allowSnapshotting, child);
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => OmniMotion.reduced(context)
      ? child
      : _android.buildTransitions(
          route,
          context,
          animation,
          secondaryAnimation,
          child,
        );
}
