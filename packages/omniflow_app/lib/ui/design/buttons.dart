import 'package:flutter/material.dart';

import 'tokens.dart';

enum OmniButtonKind { primary, ghost, danger, destructive }

/// The full-width pill buttons of the mockups, 56 dp high with a 16
/// label: [OmniButtonKind.primary] (the Appearance accent), ghost
/// (outlined), danger (red outline, for Reject and Remove in a page) and
/// destructive (filled red, the action of a confirm that deletes).
class OmniButton extends StatelessWidget {
  const OmniButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = OmniButtonKind.primary,
    this.expand = true,
  });

  const OmniButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = true,
  }) : kind = OmniButtonKind.ghost;

  const OmniButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = true,
  }) : kind = OmniButtonKind.danger;

  const OmniButton.destructive({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = true,
  }) : kind = OmniButtonKind.destructive;

  final String label;

  /// Null shows the button disabled.
  final VoidCallback? onPressed;
  final IconData? icon;
  final OmniButtonKind kind;

  /// Fills the width it is given.
  final bool expand;

  static final _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(OmniRadii.button),
  );
  static const _size = Size(OmniSpace.targetLarge, OmniSpace.targetLarge);
  static const _padding = EdgeInsets.symmetric(
    horizontal: OmniSpace.xl,
    vertical: OmniSpace.md,
  );

  @override
  Widget build(BuildContext context) {
    final text = Text(label);
    final palette = OmniPalette.of(context);
    final filled = kind == OmniButtonKind.primary;
    final button = switch (kind) {
      OmniButtonKind.primary || OmniButtonKind.destructive => FilledButton.icon(
        onPressed: onPressed,
        icon: icon == null ? null : Icon(icon, size: 20),
        label: text,
        style: FilledButton.styleFrom(
          backgroundColor: filled ? palette.accent : palette.bad,
          foregroundColor: filled ? palette.onAccent : palette.onBad,
          disabledBackgroundColor: palette.raised,
          disabledForegroundColor: palette.muted,
          minimumSize: _size,
          padding: _padding,
          shape: _shape,
          textStyle: OmniText.button,
        ),
      ),
      OmniButtonKind.ghost || OmniButtonKind.danger => OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon == null ? null : Icon(icon, size: 20),
        label: text,
        style: OutlinedButton.styleFrom(
          foregroundColor: kind == OmniButtonKind.danger
              ? palette.bad
              : palette.text,
          side: BorderSide(
            color: kind == OmniButtonKind.danger
                ? palette.badLine
                : palette.line,
          ),
          minimumSize: _size,
          padding: _padding,
          shape: _shape,
          textStyle: OmniText.button,
        ),
      ),
    };
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A muted icon button for headers and rows, with a 48 dp target and its
/// [label] read out and shown as a tooltip.
class OmniIconAction extends StatelessWidget {
  const OmniIconAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.selected = false,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// A count drawn on the icon (the bell's "4"), inside the button's own
  /// 48 dp box so it never covers the button beside it. Its text grows
  /// with the text size only to [badgeMaxScale]; [label] says the count.
  final int? badge;

  /// How far a badge's count grows with the text size.
  static const badgeMaxScale = 1.3;

  /// The icon colour; the palette's muted grey by default.
  final Color? color;

  /// Draws the icon filled and in the accent (a set favourite star).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    Widget glyph = Icon(
      icon,
      color: selected
          ? OmniPalette.of(context).accent
          : color ?? OmniPalette.of(context).muted,
      fill: selected ? 1 : 0,
      semanticLabel: label,
    );
    if (badge case final n? when n > 0) {
      glyph = Badge(
        key: const ValueKey('omni-icon-badge'),
        label: MediaQuery.withClampedTextScaling(
          maxScaleFactor: badgeMaxScale,
          child: ExcludeSemantics(child: Text('$n')),
        ),
        child: glyph,
      );
    }
    return IconButton(
      onPressed: onPressed,
      tooltip: label,
      isSelected: selected,
      constraints: const BoxConstraints(
        minWidth: OmniSpace.target,
        minHeight: OmniSpace.target,
      ),
      icon: glyph,
    );
  }
}

/// Grows the hit area of a small control to 48 dp without changing how it
/// looks. Taps in the padding go to [onTap].
class OmniTapTarget extends StatelessWidget {
  const OmniTapTarget({super.key, required this.child, required this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    excludeFromSemantics: true,
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: OmniSpace.target,
        minHeight: OmniSpace.target,
      ),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    ),
  );
}
