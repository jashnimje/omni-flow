import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

/// Colours from docs/DESIGN.md (UI section).
abstract final class OmniColors {
  static const background = Color(0xFF0D0F12);
  static const bar = Color(0xFF14171C);
  static const card = Color(0xFF1A1E24);
  static const trigger = Color(0xFFFF9F1C);
  static const condition = Color(0xFF7B2CBF);
  static const transformer = Color(0xFF3A86FF);
  static const flowControl = Color(0xFFFF006E);
  static const action = Color(0xFF00F5D4);
}

ThemeData omniTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: OmniColors.action,
    brightness: Brightness.dark,
  ).copyWith(surface: OmniColors.background);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: OmniColors.background,
    appBarTheme: const AppBarTheme(backgroundColor: OmniColors.bar),
    cardTheme: const CardThemeData(color: OmniColors.card),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: OmniColors.bar,
    ),
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
