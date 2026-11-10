import 'package:flutter/material.dart';

import 'progress.dart';
import 'tokens.dart';

/// A device tile on Home: icon, name, one line of state, and a level bar
/// when [level] is set. An [on] tile uses the accent gradient, an [offline]
/// one is dimmed (its text stays AA readable).
class OmniTile extends StatelessWidget {
  const OmniTile({
    super.key,
    required this.icon,
    required this.name,
    this.state,
    this.on = false,
    this.offline = false,
    this.level,
    this.onTap,
    this.onLongPress,
    this.tapHint,
  });

  final IconData icon;
  final String name;
  final String? state;
  final bool on;
  final bool offline;

  /// 0 to 1, drawn as a thin bar under the state.
  final double? level;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// What a tap does, for screen readers ("Turns it off", "Opens it").
  final String? tapHint;

  @override
  Widget build(BuildContext context) {
    final lit = on && !offline;
    final radius = BorderRadius.circular(OmniRadii.tile);
    return Semantics(
      container: true,
      button: onTap != null,
      label: [name, ?state].join(', '),
      hint: tapHint,
      onLongPressHint: onLongPress == null ? null : 'Open controls',
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: OmniMotion.of(context),
        curve: OmniMotion.curve,
        constraints: const BoxConstraints(minHeight: 92),
        decoration: BoxDecoration(
          borderRadius: radius,
          color: lit ? null : OmniColors.card,
          gradient: lit
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [OmniColors.heroTop, OmniColors.heroBottom],
                )
              : null,
          border: Border.all(
            color: lit ? OmniColors.accentLine : OmniColors.line,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.all(OmniSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: offline ? 0.55 : 1,
                    child: OmniIconBox(icon: icon, on: lit),
                  ),
                  const SizedBox(height: OmniSpace.gap),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OmniText.label.copyWith(
                      color: offline ? OmniColors.muted : OmniColors.text,
                    ),
                  ),
                  if (state != null)
                    Text(
                      state!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OmniText.caption.copyWith(
                        color: lit ? OmniColors.onAccentSoft : OmniColors.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  if (level != null) ...[
                    const SizedBox(height: OmniSpace.sm),
                    OmniProgressBar(value: level, height: 4),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rounded square an icon sits in on tiles and list rows. [on] fills
/// it with the accent; [background] and [foreground] override (a TV app's
/// brand badge).
class OmniIconBox extends StatelessWidget {
  const OmniIconBox({
    super.key,
    required this.icon,
    this.on = false,
    this.size = 32,
    this.background,
    this.foreground,
  });

  final IconData icon;
  final bool on;
  final double size;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: background ?? (on ? OmniColors.accent : OmniColors.raised),
      borderRadius: BorderRadius.circular(OmniRadii.iconBox),
    ),
    child: Icon(
      icon,
      size: size * 0.56,
      color: foreground ?? (on ? OmniColors.accentInk : OmniColors.text),
    ),
  );
}

/// A tile's shape while its device loads.
class OmniTileSkeleton extends StatelessWidget {
  const OmniTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: Container(
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.all(OmniSpace.md),
      decoration: BoxDecoration(
        color: OmniColors.card,
        borderRadius: BorderRadius.circular(OmniRadii.tile),
        border: Border.all(color: OmniColors.line),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Bone(width: 32, height: 32, radius: OmniRadii.iconBox),
          SizedBox(height: OmniSpace.gap),
          _Bone(width: 90, height: 12),
          SizedBox(height: 6),
          _Bone(width: 56, height: 10),
        ],
      ),
    ),
  );
}

class _Bone extends StatelessWidget {
  const _Bone({required this.width, required this.height, this.radius = 4});

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: OmniColors.raised,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}
