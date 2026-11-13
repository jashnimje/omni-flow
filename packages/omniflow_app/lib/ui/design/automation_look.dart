import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'icons.dart';
import 'tokens.dart';

/// The colour and icon an automation, scene or template wears, from the
/// names the engine stores (`color: "#4D9DFF"`, `icon: "moon"`). Anything
/// the app does not know falls back to the plain card look.
abstract final class AutomationLook {
  /// The colours a rule or scene can take, by the hex the engine stores,
  /// in picker order, each with its spoken name.
  static const colors = <String, ({Color color, String name})>{
    '#00F5D4': (color: Color(0xFF00F5D4), name: 'Teal'),
    '#4D9DFF': (color: Color(0xFF4D9DFF), name: 'Blue'),
    '#A78BFA': (color: Color(0xFFA78BFA), name: 'Purple'),
    '#F472B6': (color: Color(0xFFF472B6), name: 'Pink'),
    '#FB923C': (color: Color(0xFFFB923C), name: 'Orange'),
    '#FACC15': (color: Color(0xFFFACC15), name: 'Yellow'),
    '#34D399': (color: Color(0xFF34D399), name: 'Green'),
    '#94A3B8': (color: Color(0xFF94A3B8), name: 'Grey'),
  };

  /// The icons a rule can take, by the name the engine stores, in picker
  /// order.
  static const icons = <String, IconData>{
    'bolt': Symbols.bolt_rounded,
    'home': Symbols.home_rounded,
    'sunrise': Symbols.wb_twilight_rounded,
    'moon': Symbols.bedtime_rounded,
    'tv': Symbols.tv_rounded,
    'lightbulb': Symbols.lightbulb_rounded,
    'movie': Symbols.movie_rounded,
    'music': Symbols.music_note_rounded,
    'fan': Symbols.mode_fan_rounded,
    'lock': Symbols.lock_rounded,
    'car': Symbols.directions_car_rounded,
    'bell': Symbols.notifications_rounded,
    'heart': Symbols.favorite_rounded,
    'star': Symbols.star_rounded,
    'leaf': Symbols.eco_rounded,
    'fire': Symbols.local_fire_department_rounded,
  };

  /// The icon of the "Asks first" badge.
  static const askIcon = Symbols.contact_support_rounded;

  /// The ink on every colour of [colors]: each is light enough for dark
  /// text at AA.
  static const ink = Color(0xFF0D0F12);

  /// The colour [hex] names, or null when it names none of [colors].
  static Color? colorOf(String? hex) =>
      hex == null ? null : colors[hex.toUpperCase()]?.color;

  /// The spoken name of the colour [hex] names, or null.
  static String? colorName(String? hex) =>
      hex == null ? null : colors[hex.toUpperCase()]?.name;

  /// The icon [name] names, else [fallback].
  static IconData iconOf(String? name, {IconData? fallback}) =>
      icons[name] ?? fallback ?? OmniIcons.automations;

  /// The background of a badge in [hex]: the colour, or the plain raised
  /// grey when it has none.
  static Color badgeOf(String? hex) => colorOf(hex) ?? OmniColors.raised;

  /// The icon colour on [badgeOf].
  static Color badgeInkOf(String? hex) =>
      colorOf(hex) == null ? OmniColors.text : ink;

  /// A tile's soft fill in [hex], or the plain card.
  static Color tintOf(String? hex) => switch (colorOf(hex)) {
    final c? => Color.alphaBlend(c.withAlpha(0x2E), OmniColors.card),
    null => OmniColors.card,
  };

  /// A tile's border in [hex], or the plain line.
  static Color lineOf(String? hex) => switch (colorOf(hex)) {
    final c? => Color.alphaBlend(c.withAlpha(0x73), OmniColors.card),
    null => OmniColors.line,
  };
}

/// The rounded square badge of an automation, scene or template: [icon]
/// on its [color] (`#RRGGBB`), or on plain grey without one.
class AutomationBadge extends StatelessWidget {
  const AutomationBadge({
    super.key,
    required this.icon,
    this.color,
    this.size = 36,
  });

  final IconData icon;
  final String? color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AutomationLook.badgeOf(color),
        borderRadius: BorderRadius.circular(OmniRadii.iconBox),
      ),
      child: Icon(
        icon,
        size: size * 0.56,
        fill: 1,
        color: AutomationLook.badgeInkOf(color),
      ),
    ),
  );
}

/// A small muted pill saying how an automation behaves ("Asks first",
/// "Tells you when it runs").
class BehaviourBadge extends StatelessWidget {
  const BehaviourBadge({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: OmniColors.raised,
        borderRadius: BorderRadius.circular(OmniRadii.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: OmniColors.muted),
          const SizedBox(width: 4),
          Text(label, style: OmniText.caption),
        ],
      ),
    ),
  );
}

/// One colour to pick: a 48 dp target with a round swatch, ringed and
/// checked when [selected]. Read out as a toggle named [label].
class ColorSwatchButton extends StatelessWidget {
  const ColorSwatchButton({
    super.key,
    required this.color,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: selected,
    label: label,
    excludeSemantics: true,
    child: InkResponse(
      onTap: onPressed,
      radius: 24,
      child: SizedBox.square(
        dimension: OmniSpace.target,
        child: Center(
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? OmniColors.text : Colors.transparent,
                width: 2,
              ),
            ),
            child: selected
                ? const Icon(
                    OmniIcons.check,
                    size: 18,
                    color: AutomationLook.ink,
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}
