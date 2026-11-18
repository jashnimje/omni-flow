import 'package:flutter/material.dart';

import 'icons.dart';
import 'tokens.dart';

/// The round 72 dp power button of a device's state card: accent when
/// [on], raised when off. Screen readers hear it as a switch named
/// [label].
class OmniPowerButton extends StatelessWidget {
  const OmniPowerButton({
    super.key,
    required this.on,
    required this.onPressed,
    this.label = 'Power',
    this.size = 72,
  });

  final bool on;

  /// Null shows it disabled (an offline device).
  final VoidCallback? onPressed;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: AnimatedContainer(
        duration: OmniMotion.of(context),
        curve: OmniMotion.curve,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? palette.accent : palette.raised,
          border: on ? null : Border.all(color: palette.line),
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(
              OmniIcons.power,
              size: size * 0.42,
              weight: 600,
              color: onPressed == null
                  ? palette.muted
                  : on
                  ? palette.onAccent
                  : palette.text,
            ),
          ),
        ),
      ),
    );
  }
}
