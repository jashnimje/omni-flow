import 'package:flutter/material.dart';

import 'tokens.dart';

enum OmniButtonKind { primary, ghost, danger }

/// The full-width buttons of the mockups: [OmniButtonKind.primary] (accent),
/// ghost (outlined) and danger (red outline, for Reject and Remove).
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
  static const _size = Size(OmniSpace.target, OmniSpace.target);
  static const _padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

  @override
  Widget build(BuildContext context) {
    final text = Text(label);
    final button = switch (kind) {
      OmniButtonKind.primary => FilledButton.icon(
        onPressed: onPressed,
        icon: icon == null ? null : Icon(icon, size: 20),
        label: text,
        style: FilledButton.styleFrom(
          backgroundColor: OmniColors.accent,
          foregroundColor: OmniColors.accentInk,
          disabledBackgroundColor: OmniColors.raised,
          disabledForegroundColor: OmniColors.muted,
          minimumSize: _size,
          padding: _padding,
          shape: _shape,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      OmniButtonKind.ghost || OmniButtonKind.danger => OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon == null ? null : Icon(icon, size: 20),
        label: text,
        style: OutlinedButton.styleFrom(
          foregroundColor: kind == OmniButtonKind.danger
              ? OmniColors.bad
              : OmniColors.text,
          side: BorderSide(
            color: kind == OmniButtonKind.danger
                ? OmniColors.badLine
                : OmniColors.line,
          ),
          minimumSize: _size,
          padding: _padding,
          shape: _shape,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
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
    this.color = OmniColors.muted,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color color;

  /// Draws the icon filled and in the accent (a set favourite star).
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: label,
    isSelected: selected,
    constraints: const BoxConstraints(
      minWidth: OmniSpace.target,
      minHeight: OmniSpace.target,
    ),
    icon: Icon(
      icon,
      color: selected ? OmniColors.accent : color,
      fill: selected ? 1 : 0,
      semanticLabel: label,
    ),
  );
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
