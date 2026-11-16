import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/design.dart';
import 'house_switcher.dart';

/// The top of Home (look B in docs/ui/home-modern-mockups.html): the
/// greeting, the house in view and one line with presence and the house
/// mode, in one gradient card with the accent glowing in its corner. The
/// numbers, the streak and achievements are in Settings, Your activity.
class HomeHero extends ConsumerWidget {
  const HomeHero({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  /// The glow in the top right corner: the accent at its centre.
  static const glow = 0.2;
  static const glowSize = 160.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = OmniPalette.of(context);
    final radius = BorderRadius.circular(OmniRadii.hero);
    return Padding(
      padding: const EdgeInsets.only(top: OmniSpace.xs, bottom: OmniSpace.md),
      child: DecoratedBox(
        key: const ValueKey('home-hero'),
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: const Alignment(-0.35, -1),
            end: const Alignment(0.35, 1),
            colors: [palette.heroTop, palette.heroBottom],
          ),
          border: Border.all(color: palette.accentLine),
          boxShadow: OmniDepth.shadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(
                right: -40,
                top: -40,
                child: IgnorePointer(
                  child: Container(
                    width: glowSize,
                    height: glowSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          palette.accent.withValues(alpha: glow),
                          palette.accent.withValues(alpha: 0),
                        ],
                        stops: const [0, 0.7],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmniSpace.lg,
                  OmniSpace.lg,
                  OmniSpace.lg,
                  14,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const HouseSwitcher(),
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        key: const ValueKey('home-greeting'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OmniText.largeTitle,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        key: const ValueKey('home-status'),
                        style: OmniText.caption.copyWith(
                          color: palette.onAccentSoft,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
