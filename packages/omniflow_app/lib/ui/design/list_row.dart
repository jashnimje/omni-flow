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

  static Color colorOf(StatusKind kind) => switch (kind) {
    StatusKind.online => OmniColors.accent,
    StatusKind.offline => OmniColors.muted,
    StatusKind.warning => OmniColors.warn,
    StatusKind.problem => OmniColors.bad,
  };

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
      decoration: BoxDecoration(color: colorOf(kind), shape: BoxShape.circle),
    ),
  );
}

/// A list row: an icon box (or any [leading]), a title with an optional
/// one-line subtitle, and on the right a [value] in the accent, a status
/// [dot], a [trailing] widget or a chevron. Rows are divided by a line.
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

  @override
  Widget build(BuildContext context) {
    final right = <Widget>[
      if (value != null)
        Text(
          value!,
          style: OmniText.number.copyWith(
            color: valueColor ?? OmniColors.accent,
          ),
        ),
      if (dot != null) StatusDot(dot!),
      ?trailing,
      if (chevron && value == null && trailing == null)
        const Icon(OmniIcons.chevron, color: OmniColors.muted, size: 22),
    ];
    final row = Container(
      constraints: const BoxConstraints(minHeight: OmniSpace.target + 4),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? OmniPalette.of(context).accentSoft : null,
        borderRadius: selected ? BorderRadius.circular(OmniRadii.field) : null,
        border: divider && !selected
            ? Border(bottom: BorderSide(color: OmniPalette.of(context).line))
            : null,
      ),
      child: Row(
        children: [
          if (leading != null)
            leading!
          else if (icon != null)
            OmniIconBox(
              icon: icon!,
              background: iconBackground,
              foreground: iconForeground,
            ),
          if (leading != null || icon != null)
            const SizedBox(width: OmniSpace.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: OmniText.body),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: subtitleLines,
                    overflow: TextOverflow.ellipsis,
                    style: OmniText.caption,
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
