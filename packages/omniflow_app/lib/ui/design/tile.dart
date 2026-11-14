import 'package:flutter/material.dart';

import 'icons.dart';
import 'skeleton.dart';
import 'tokens.dart';

/// A device tile on Home, showing the device's real state: its icon, its
/// name (up to two lines), a big [reading] (a temperature, the app on a
/// TV) and one line of [state].
///
/// A tile that is [on] takes a muted version of [tint] (a light's own
/// colour, or the accent), and [level] fills it from the left like a
/// gauge. An [offline] tile is dimmed and its text stays AA readable.
///
/// Tapping the tile opens the device ([onTap]; the chevron says so).
/// Tapping the icon switches it ([onIconTap]): the icon wears a ring to
/// show it is a button of its own. [pending] shimmers the icon while a
/// switch waits for the device.
class OmniTile extends StatefulWidget {
  const OmniTile({
    super.key,
    required this.icon,
    required this.name,
    this.reading,
    this.state,
    this.on = false,
    this.offline = false,
    this.pending = false,
    this.level,
    this.tint,
    this.onTap,
    this.onIconTap,
    this.iconLabel,
    this.iconKey,
    this.onLongPress,
    this.tapHint,
  });

  final IconData icon;
  final String name;
  final String? reading;
  final String? state;
  final bool on;
  final bool offline;
  final bool pending;

  /// 0 to 1, filled from the left.
  final double? level;

  /// The device's own colour while on (a light's colour). Null uses the
  /// accent.
  final Color? tint;
  final VoidCallback? onTap;

  /// Switches the device. Null leaves the icon as decoration.
  final VoidCallback? onIconTap;

  /// What the icon does, for screen readers ("Turn Desk lamp off").
  final String? iconLabel;
  final Key? iconKey;
  final VoidCallback? onLongPress;

  /// What a tap does, for screen readers ("Opens it").
  final String? tapHint;

  static const minHeight = 112.0;

  @override
  State<OmniTile> createState() => _OmniTileState();
}

class _OmniTileState extends State<OmniTile> {
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final palette = OmniPalette.of(context);
    final lit = w.on && !w.offline;
    final tint = w.tint ?? palette.accent;
    final base = lit
        ? mutedTint(tint, palette.card, amount: 0.2)
        : palette.card;
    final fill = lit ? mutedTint(tint, palette.card, amount: 0.38) : base;
    final border = lit ? Color.lerp(palette.card, tint, 0.55)! : palette.line;
    final radius = BorderRadius.circular(OmniRadii.tile);
    final spring = OmniMotion.springFast;
    final reduced = OmniMotion.reduced(context);
    final level = lit ? w.level?.clamp(0.0, 1.0) : null;
    final textColor = w.offline ? OmniColors.muted : OmniColors.text;
    final stateColor = lit ? OmniColors.text : OmniColors.muted;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: w.onTap != null,
      label: [w.name, ?w.reading, ?w.state].join(', '),
      hint: w.tapHint,
      onLongPressHint: w.onLongPress == null ? null : 'Open controls',
      onTap: w.onTap,
      onLongPress: w.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1,
        duration: reduced ? Duration.zero : spring.duration,
        curve: spring.curve,
        child: AnimatedContainer(
          duration: OmniMotion.of(context),
          curve: OmniMotion.curve,
          constraints: const BoxConstraints(minHeight: OmniTile.minHeight),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: base,
            border: Border.all(color: border),
          ),
          child: Stack(
            children: [
              if (level != null)
                Positioned.fill(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AnimatedFractionallySizedBox(
                      duration: OmniMotion.of(context, OmniMotion.slow),
                      curve: OmniMotion.emphasizedIn,
                      widthFactor: level,
                      heightFactor: 1,
                      child: ColoredBox(color: fill),
                    ),
                  ),
                ),
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  // The tile's Semantics above carries the tap and label.
                  excludeFromSemantics: true,
                  borderRadius: radius,
                  onTap: w.onTap,
                  onLongPress: w.onLongPress,
                  onHighlightChanged: (v) => setState(() => _pressed = v),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      OmniSpace.xs,
                      OmniSpace.xs,
                      OmniSpace.sm,
                      OmniSpace.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _TileIcon(
                              key: w.iconKey,
                              icon: w.icon,
                              lit: lit,
                              tint: tint,
                              offline: w.offline,
                              pending: w.pending,
                              label: w.iconLabel,
                              onTap: w.onIconTap,
                            ),
                            const Spacer(),
                            if (w.onTap != null)
                              const Padding(
                                padding: EdgeInsets.only(top: OmniSpace.md),
                                child: ExcludeSemantics(
                                  child: Icon(
                                    OmniIcons.chevron,
                                    size: 20,
                                    color: OmniColors.muted,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: OmniSpace.sm,
                          ),
                          child: ExcludeSemantics(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (w.reading != null)
                                  Text(
                                    w.reading!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: OmniText.reading.copyWith(
                                      color: textColor,
                                    ),
                                  ),
                                Text(
                                  w.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: OmniText.label.copyWith(
                                    color: textColor,
                                  ),
                                ),
                                if (w.state != null && w.state!.isNotEmpty)
                                  Text(
                                    w.state!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: OmniText.caption.copyWith(
                                      color: stateColor,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tile's icon: a 48 dp button holding a 40 dp box. Lit, it takes
/// the device's real colour; as a switch it wears a ring.
class _TileIcon extends StatelessWidget {
  const _TileIcon({
    super.key,
    required this.icon,
    required this.lit,
    required this.tint,
    required this.offline,
    required this.pending,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final bool lit;
  final Color tint;
  final bool offline;
  final bool pending;
  final String? label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final background = lit ? tint : palette.raised;
    final box = AnimatedContainer(
      duration: OmniMotion.of(context),
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        border: onTap == null
            ? null
            : Border.all(
                color: lit ? inkOn(tint).withValues(alpha: 0.35) : palette.line,
                width: 1.5,
              ),
      ),
      child: Icon(
        icon,
        size: 22,
        fill: lit ? 1 : 0,
        color: lit ? inkOn(tint) : OmniColors.text,
      ),
    );
    final shown = Opacity(
      opacity: offline ? 0.55 : (pending ? 0.75 : 1),
      child: OmniShimmer(enabled: pending, child: box),
    );
    final target = SizedBox(
      width: OmniSpace.target,
      height: OmniSpace.target,
      child: Center(child: shown),
    );
    if (onTap == null) return ExcludeSemantics(child: target);
    return Semantics(
      container: true,
      button: true,
      toggled: lit,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: target,
        ),
      ),
    );
  }
}

/// The rounded square an icon sits in on list rows. [on] fills it with
/// the accent; [background] and [foreground] override (a TV app's brand
/// badge).
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
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? (on ? palette.accent : palette.raised),
        borderRadius: BorderRadius.circular(
          size <= 32 ? OmniShape.sm : OmniRadii.iconBox,
        ),
      ),
      child: Icon(
        icon,
        size: size * 0.56,
        color: foreground ?? (on ? palette.onAccent : OmniColors.text),
      ),
    );
  }
}

/// A tile's shape while its device loads.
class OmniTileSkeleton extends StatelessWidget {
  const OmniTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    return Semantics(
      label: 'Loading',
      child: OmniShimmer(
        child: Container(
          constraints: const BoxConstraints(minHeight: OmniTile.minHeight),
          padding: const EdgeInsets.all(OmniSpace.md),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(OmniRadii.tile),
            border: Border.all(color: palette.line),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OmniBone(width: 40, height: 40, radius: OmniShape.full),
              SizedBox(height: OmniSpace.gap),
              OmniBone(width: 90, height: 12),
              SizedBox(height: 6),
              OmniBone(width: 56, height: 10),
            ],
          ),
        ),
      ),
    );
  }
}
