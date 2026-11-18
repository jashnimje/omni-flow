import 'package:flutter/material.dart';

import '../design/design.dart';

/// The bold card colour of an automation or scene, from the colour the
/// engine stores for it (`#4D9DFF`). The stored colours are the light ones
/// of the look picker; each maps to the [OmniCardColors] colour of the same
/// hue, which white text reads on in both themes. One with no colour wears
/// teal, the colour the look picker names for it.
Color automationCardColor(String? hex) => switch (hex?.toUpperCase()) {
  '#4D9DFF' => OmniCardColors.blue,
  '#A78BFA' => OmniCardColors.violet,
  '#F472B6' => OmniCardColors.pink,
  '#FB923C' || '#FACC15' => OmniCardColors.orange,
  '#34D399' => OmniCardColors.green,
  '#94A3B8' => OmniCardColors.slate,
  _ => OmniCardColors.teal,
};

/// An automation's icon on its card colour: a white icon in a round,
/// lighter well.
class CardIcon extends StatelessWidget {
  const CardIcon({super.key, required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: OmniCardColors.onCard.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(OmniRadii.iconBox),
      ),
      child: Icon(
        icon,
        size: size * 0.6,
        fill: 1,
        color: OmniCardColors.onCard,
      ),
    ),
  );
}
