import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

import 'design/tokens.dart';

export 'design/tokens.dart';

/// The app's Material theme, from the design tokens, so plain Material
/// widgets (switches, app bars, dialogs, text fields) already match the
/// mockups. [palette] is the Appearance setting: teal by default, the
/// wallpaper's colours, or either on pure black.
ThemeData omniTheme({OmniPalette palette = OmniPalette.teal}) {
  final p = palette;
  final scheme = ColorScheme.dark(
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.onAccentSoft,
    secondary: p.accent,
    onSecondary: p.onAccent,
    secondaryContainer: p.accentSoft,
    onSecondaryContainer: p.onAccentSoft,
    tertiary: OmniColors.condition,
    error: OmniColors.bad,
    onError: OmniColors.onBad,
    errorContainer: OmniColors.badSoft,
    onErrorContainer: OmniColors.bad,
    surface: p.background,
    onSurface: OmniColors.text,
    onSurfaceVariant: OmniColors.muted,
    surfaceContainerLowest: p.background,
    surfaceContainerLow: p.bar,
    surfaceContainer: p.card,
    surfaceContainerHigh: p.raised,
    surfaceContainerHighest: OmniSurface.highest,
    outline: OmniColors.muted,
    outlineVariant: p.line,
    inverseSurface: OmniColors.text,
    onInverseSurface: p.background,
    scrim: Colors.black,
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(OmniRadii.button),
  );
  const minTarget = Size(OmniSpace.target, OmniSpace.target);
  return ThemeData(
    colorScheme: scheme,
    extensions: [p],
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    dividerColor: p.line,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: _MotionAwareTransitions()},
    ),
    textTheme: const TextTheme(
      displaySmall: OmniText.displaySmall,
      headlineLarge: OmniText.headlineLarge,
      headlineMedium: OmniText.headlineMedium,
      headlineSmall: OmniText.headlineSmall,
      titleLarge: OmniText.titleLarge,
      titleMedium: OmniText.titleMedium,
      titleSmall: OmniText.titleSmall,
      bodyLarge: OmniText.bodyLarge,
      bodyMedium: OmniText.body,
      bodySmall: OmniText.caption,
      labelLarge: OmniText.label,
      labelMedium: OmniText.labelMedium,
      labelSmall: OmniText.navLabel,
    ),
    iconTheme: const IconThemeData(color: OmniColors.text, size: 22),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: OmniColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: OmniText.pageTitle,
      iconTheme: const IconThemeData(color: OmniColors.muted),
      actionsIconTheme: const IconThemeData(color: OmniColors.muted),
      systemOverlayStyle: omniSystemBars,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.bar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.accentSoft,
      height: 64,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => OmniText.navLabel.copyWith(
          color: states.contains(WidgetState.selected)
              ? OmniColors.text
              : OmniColors.muted,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? OmniColors.text
              : OmniColors.muted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.bar,
      indicatorColor: p.accentSoft,
      labelType: NavigationRailLabelType.all,
      selectedIconTheme: const IconThemeData(color: OmniColors.text, size: 22),
      unselectedIconTheme: const IconThemeData(
        color: OmniColors.muted,
        size: 22,
      ),
      selectedLabelTextStyle: OmniText.navLabel.copyWith(
        color: OmniColors.text,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: OmniText.navLabel,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.accent,
      foregroundColor: p.onAccent,
      elevation: 6,
      highlightElevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.fab),
      ),
      extendedTextStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: OmniSpace.gap),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.card),
        side: BorderSide(color: p.line),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: OmniColors.muted,
      textColor: OmniColors.text,
      minVerticalPadding: 10,
    ),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? OmniColors.muted.withValues(alpha: 0.5)
            : states.contains(WidgetState.selected)
            ? p.onAccent
            : OmniColors.muted,
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
            : p.line,
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
        minimumSize: minTarget,
        shape: buttonShape,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: OmniColors.text,
        side: BorderSide(color: p.line),
        minimumSize: minTarget,
        shape: buttonShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: minTarget,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: minTarget),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.card,
      labelStyle: const TextStyle(color: OmniColors.muted),
      hintStyle: const TextStyle(color: OmniColors.muted),
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
      labelStyle: const TextStyle(fontSize: 12, color: OmniColors.text),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.sheet,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: OmniColors.scrim,
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
      contentTextStyle: const TextStyle(color: OmniColors.text, fontSize: 14),
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
      textStyle: const TextStyle(color: OmniColors.text, fontSize: 12),
    ),
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

/// The badge colour of a node, from the category the engine registers for it.
Color categoryColor(String type) => switch (builtInNodeTypes[type]?.category) {
  NodeCategory.trigger => OmniColors.trigger,
  NodeCategory.condition => OmniColors.condition,
  NodeCategory.transformer => OmniColors.transformer,
  NodeCategory.gate || NodeCategory.flowControl => OmniColors.flowControl,
  _ => OmniColors.action,
};
