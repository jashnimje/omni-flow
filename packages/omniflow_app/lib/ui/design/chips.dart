import 'package:flutter/material.dart';

import 'buttons.dart';
import 'list_row.dart';
import 'tokens.dart';

/// A fully rounded chip, 40 dp high with a 14 label. Selected is accent
/// filled. [count] follows the label ("All 6"), [dot] leads it (the amber
/// dot of "Needs you"), and the hit area is 48 dp high whatever the
/// chip's size.
class OmniFilterChip extends StatelessWidget {
  const OmniFilterChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.count,
    this.dot,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final int? count;
  final StatusKind? dot;
  final IconData? icon;

  /// The chip's visual height. The hit area stays 48.
  static const _height = 40.0;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final fg = selected ? palette.onAccent : palette.text;
    final text = count == null ? label : '$label $count';
    final radius = BorderRadius.circular(OmniRadii.chip);
    return Semantics(
      button: true,
      selected: selected,
      label: text,
      excludeSemantics: true,
      onTap: onTap,
      child: OmniTapTarget(
        onTap: onTap,
        child: AnimatedContainer(
          duration: OmniMotion.of(context, OmniMotion.fast),
          constraints: const BoxConstraints(minHeight: _height),
          decoration: BoxDecoration(
            color: selected ? palette.accent : palette.card,
            borderRadius: radius,
            border: Border.all(color: selected ? palette.accent : palette.line),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: OmniSpace.lg,
                  vertical: OmniSpace.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (dot != null) ...[
                      ExcludeSemantics(child: StatusDot(dot!)),
                      const SizedBox(width: 6),
                    ],
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: fg),
                      const SizedBox(width: OmniSpace.sm),
                    ],
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: fg,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A status chip on Home ("You are home", "Netflix playing", "Hall bulb
/// offline"): a chip that is never selected and opens what it names.
class OmniStatusChip extends StatelessWidget {
  const OmniStatusChip({
    super.key,
    required this.label,
    this.onTap,
    this.dot,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final StatusKind? dot;
  final IconData? icon;

  @override
  Widget build(BuildContext context) =>
      OmniFilterChip(label: label, onTap: onTap, dot: dot, icon: icon);
}

/// One choice of an [OmniSegmented].
class OmniSegment<T> {
  const OmniSegment(this.value, this.label, {this.count, this.key});

  final T value;
  final String label;

  /// The key of the segment's widget, so a test can tap it.
  final Key? key;

  /// Shown after the label ("Problems 1").
  final int? count;
}

/// The segmented control of Devices, the TV page and Developer: equal
/// pill segments in a pill track, the selected one in the soft accent.
/// Each segment is 48 dp high and wraps its label to two lines at large
/// text sizes.
class OmniSegmented<T> extends StatelessWidget {
  const OmniSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<OmniSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: OmniSpace.md),
    padding: const EdgeInsets.all(OmniSpace.xs),
    decoration: BoxDecoration(
      color: OmniPalette.of(context).card,
      borderRadius: BorderRadius.circular(OmniRadii.segmented),
      border: Border.all(color: OmniPalette.of(context).line),
    ),
    child: Row(
      children: [
        for (final s in segments)
          Expanded(child: _segment(context, s, s.value == selected)),
      ],
    ),
  );

  Widget _segment(BuildContext context, OmniSegment<T> s, bool on) {
    final text = s.count == null ? s.label : '${s.label} ${s.count}';
    final radius = BorderRadius.circular(OmniRadii.segment);
    return Semantics(
      key: s.key,
      button: true,
      selected: on,
      inMutuallyExclusiveGroup: true,
      label: text,
      excludeSemantics: true,
      onTap: () => onChanged(s.value),
      child: AnimatedContainer(
        duration: OmniMotion.of(context, OmniMotion.fast),
        constraints: const BoxConstraints(minHeight: OmniSpace.target),
        decoration: BoxDecoration(
          color: on ? OmniPalette.of(context).accentSoft : Colors.transparent,
          borderRadius: radius,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: () => onChanged(s.value),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: OmniSpace.sm,
                  vertical: OmniSpace.xs,
                ),
                // Two lines at large text sizes rather than a cut count.
                child: Text(
                  text,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: on
                        ? OmniPalette.of(context).onAccentSoft
                        : OmniPalette.of(context).muted,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
