import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

import 'design/tokens.dart';

export 'design/tokens.dart';

/// The app's Material theme, from the design tokens, so plain Material
/// widgets (switches, app bars, dialogs, text fields) already match the
/// mockups.
ThemeData omniTheme() {
  const scheme = ColorScheme.dark(
    primary: OmniColors.accent,
    onPrimary: OmniColors.accentInk,
    primaryContainer: OmniColors.accentSoft,
    onPrimaryContainer: OmniColors.onAccentSoft,
    secondary: OmniColors.accent,
    onSecondary: OmniColors.accentInk,
    secondaryContainer: OmniColors.accentSoft,
    onSecondaryContainer: OmniColors.onAccentSoft,
    tertiary: OmniColors.condition,
    error: OmniColors.bad,
    onError: Color(0xFF3A0A0A),
    errorContainer: OmniColors.badSoft,
    onErrorContainer: OmniColors.bad,
    surface: OmniColors.background,
    onSurface: OmniColors.text,
    onSurfaceVariant: OmniColors.muted,
    surfaceContainerLowest: OmniColors.background,
    surfaceContainerLow: OmniColors.bar,
    surfaceContainer: OmniColors.card,
    surfaceContainerHigh: OmniColors.raised,
    surfaceContainerHighest: OmniColors.raised,
    outline: OmniColors.muted,
    outlineVariant: OmniColors.line,
    inverseSurface: OmniColors.text,
    onInverseSurface: OmniColors.background,
    scrim: Colors.black,
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(OmniRadii.button),
  );
  const minTarget = Size(OmniSpace.target, OmniSpace.target);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: OmniColors.background,
    canvasColor: OmniColors.background,
    dividerColor: OmniColors.line,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: _MotionAwareTransitions()},
    ),
    textTheme: const TextTheme(
      headlineSmall: OmniText.screenTitle,
      titleLarge: OmniText.pageTitle,
      titleMedium: OmniText.bodyStrong,
      titleSmall: OmniText.section,
      bodyLarge: OmniText.body,
      bodyMedium: OmniText.body,
      bodySmall: OmniText.caption,
      labelLarge: OmniText.label,
      labelSmall: TextStyle(fontSize: 11, color: OmniColors.muted),
    ),
    iconTheme: const IconThemeData(color: OmniColors.text, size: 22),
    appBarTheme: const AppBarTheme(
      backgroundColor: OmniColors.background,
      foregroundColor: OmniColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: OmniText.pageTitle,
      iconTheme: IconThemeData(color: OmniColors.muted),
      actionsIconTheme: IconThemeData(color: OmniColors.muted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: OmniColors.bar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: OmniColors.accentSoft,
      height: 64,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
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
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: OmniColors.accent,
      foregroundColor: OmniColors.accentInk,
      elevation: 6,
      highlightElevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      extendedTextStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: OmniColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: OmniSpace.gap),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.card),
        side: const BorderSide(color: OmniColors.line),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: OmniColors.muted,
      textColor: OmniColors.text,
      minVerticalPadding: 10,
    ),
    dividerTheme: const DividerThemeData(
      color: OmniColors.line,
      thickness: 1,
      space: 1,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? OmniColors.muted.withValues(alpha: 0.5)
            : states.contains(WidgetState.selected)
            ? OmniColors.accentInk
            : OmniColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? OmniColors.raised.withValues(alpha: 0.5)
            : states.contains(WidgetState.selected)
            ? OmniColors.accent
            : OmniColors.raised,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? OmniColors.line.withValues(alpha: 0.5)
            : states.contains(WidgetState.selected)
            ? OmniColors.accent
            : OmniColors.line,
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: OmniColors.accent,
      inactiveTrackColor: OmniColors.raised,
      thumbColor: OmniColors.accent,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: OmniColors.accent,
      linearTrackColor: OmniColors.raised,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: OmniColors.accent,
        foregroundColor: OmniColors.accentInk,
        minimumSize: minTarget,
        shape: buttonShape,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: OmniColors.text,
        side: const BorderSide(color: OmniColors.line),
        minimumSize: minTarget,
        shape: buttonShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: OmniColors.accent,
        minimumSize: minTarget,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: minTarget),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OmniColors.card,
      labelStyle: const TextStyle(color: OmniColors.muted),
      hintStyle: const TextStyle(color: OmniColors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OmniRadii.field),
        borderSide: const BorderSide(color: OmniColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OmniRadii.field),
        borderSide: const BorderSide(color: OmniColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OmniRadii.field),
        borderSide: const BorderSide(color: OmniColors.accent),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: OmniColors.card,
      selectedColor: OmniColors.accent,
      side: const BorderSide(color: OmniColors.line),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.chip),
      ),
      labelStyle: const TextStyle(fontSize: 12, color: OmniColors.text),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: OmniColors.sheet,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: OmniColors.scrim,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(OmniRadii.sheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: OmniColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OmniRadii.sheet),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: OmniColors.raised,
      contentTextStyle: TextStyle(color: OmniColors.text, fontSize: 14),
      actionTextColor: OmniColors.accent,
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: OmniColors.raised,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      textStyle: TextStyle(color: OmniColors.text, fontSize: 12),
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
