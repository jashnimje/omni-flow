import 'package:flutter/material.dart';

import 'icons.dart';
import 'tile.dart';
import 'tokens.dart';

enum StatusKind { online, offline, warning, problem }

/// The 8 dp status dot: online (accent), offline (muted), warning (amber),
/// problem (red). It carries its meaning for screen readers.
class StatusDot extends StatelessWidget {
  const StatusDot(this.kind, {super.key, this.label});

  final StatusKind kind;

  /// Read out instead of the default word for [kind].
  final String? label;

  /// The colour of [kind] in the current palette.
  static Color colorIn(BuildContext context, StatusKind kind) {
    final p = OmniPalette.of(context);
    return switch (kind) {
      StatusKind.online => p.accent,
      StatusKind.offline => p.muted,
      StatusKind.warning => p.warn,
      StatusKind.problem => p.bad,
    };
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        label ??
        switch (kind) {
          StatusKind.online => 'Online',
          StatusKind.offline => 'Offline',
          StatusKind.warning => 'Needs attention',
          StatusKind.problem => 'Problem',
        },
    child: Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: colorIn(context, kind),
        shape: BoxShape.circle,
      ),
    ),
  );
}

/// A list row: a 40 dp icon box (or any [leading]), a 16 title with an
/// optional 14 subtitle, and on the right a [value] in the accent, a
/// status [dot], a [trailing] widget or a chevron. A one-line row is at
/// least 56 dp and a two-line row 72, and both grow with the text size.
/// Rows are divided by a line.
class OmniListRow extends StatelessWidget {
  const OmniListRow({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.value,
    this.valueColor,
    this.dot,
    this.trailing,
    this.chevron = false,
    this.divider = true,
    this.onTap,
    this.onLongPress,
    this.iconBackground,
    this.iconForeground,
    this.semanticLabel,
    this.subtitleLines = 1,
    this.selected = false,
    this.enabled = true,
  });

  final String title;
  final IconData? icon;

  /// Shown instead of the icon box (a checkbox, a brand badge).
  final Widget? leading;
  final String? subtitle;
  final String? value;
  final Color? valueColor;
  final StatusKind? dot;
  final Widget? trailing;

  /// Shows a chevron when nothing else is on the right: the row opens a page.
  final bool chevron;
  final bool divider;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? iconBackground;
  final Color? iconForeground;

  /// Read out instead of the title, subtitle and value.
  final String? semanticLabel;
  final int subtitleLines;

  /// The row shown beside the list (two panes on a wide screen).
  final bool selected;

  /// False draws the row muted and tells a screen reader it is unavailable.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final right = <Widget>[
      if (value != null)
        Text(
          value!,
          style: OmniText.number.copyWith(color: valueColor ?? palette.accent),
        ),
      if (dot != null) StatusDot(dot!),
      ?trailing,
      if (chevron && value == null && trailing == null)
        Icon(OmniIcons.chevron, color: palette.muted, size: 24),
    ];
    final row = Container(
      constraints: BoxConstraints(
        minHeight: subtitle == null ? OmniSpace.row : OmniSpace.rowTwoLine,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: 2,
        vertical: OmniSpace.sm,
      ),
      decoration: BoxDecoration(
        color: selected ? palette.accentSoft : null,
        borderRadius: selected ? BorderRadius.circular(OmniRadii.field) : null,
        border: divider && !selected
            ? Border(bottom: BorderSide(color: palette.line))
            : null,
      ),
      child: Row(
        children: [
          if (leading != null)
            leading!
          else if (icon != null)
            OmniIconBox(
              icon: icon!,
              size: 40,
              background: iconBackground,
              foreground: iconForeground,
            ),
          if (leading != null || icon != null)
            const SizedBox(width: OmniSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: OmniText.body.copyWith(
                    color: enabled ? palette.text : palette.muted,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    // Large text wraps rather than cutting off the end.
                    maxLines: MediaQuery.textScalerOf(context).scale(10) >= 13
                        ? subtitleLines * 3
                        : subtitleLines,
                    overflow: TextOverflow.ellipsis,
                    style: OmniText.caption.copyWith(color: palette.muted),
                  ),
              ],
            ),
          ),
          for (final w in right) ...[const SizedBox(width: OmniSpace.sm), w],
        ],
      ),
    );
    final tappable = onTap != null || onLongPress != null;
    return Semantics(
      container: true,
      button: tappable,
      selected: selected ? true : null,
      enabled: enabled ? null : false,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      onTap: semanticLabel != null ? onTap : null,
      onLongPress: semanticLabel != null ? onLongPress : null,
      child: tappable
          ? InkWell(onTap: onTap, onLongPress: onLongPress, child: row)
          : row,
    );
  }
}
