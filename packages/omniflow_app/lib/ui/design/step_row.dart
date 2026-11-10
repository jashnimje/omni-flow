import 'package:flutter/material.dart';

import 'buttons.dart';
import 'icons.dart';
import 'sentence.dart' show RuleBlockColor;
import 'tokens.dart';

enum StepRowStyle {
  normal,

  /// A wait: drawn with a dashed border.
  wait,

  /// A branch or parallel group that opens its own list: pink border.
  flow,
}

/// A row of the rule editor: a drag handle, an icon, the step in plain
/// words, and a remove button or a [trailingText] ("2 ›") for a group.
///
/// Inside a [ReorderableListView] with `buildDefaultDragHandles: false`,
/// pass [reorderIndex] and the handle starts the drag. An [error] (from the
/// rule path the engine names) draws the row red with the reason under it.
class OmniStepRow extends StatelessWidget {
  const OmniStepRow({
    super.key,
    required this.text,
    this.icon,
    this.subtitle,
    this.style = StepRowStyle.normal,
    this.onTap,
    this.onRemove,
    this.trailingText,
    this.reorderIndex,
    this.error,
  });

  final String text;
  final IconData? icon;
  final String? subtitle;
  final StepRowStyle style;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final String? trailingText;
  final int? reorderIndex;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final borderColor = error != null
        ? OmniColors.bad
        : switch (style) {
            StepRowStyle.flow => OmniColors.flowLine,
            _ => OmniColors.line,
          };
    final radius = BorderRadius.circular(OmniRadii.step);
    final ink = RuleBlockColor.maybeOf(context) ?? OmniColors.text;
    Widget handle = Semantics(
      label: 'Drag to reorder',
      child: const SizedBox(
        width: 32,
        height: OmniSpace.target,
        child: Icon(OmniIcons.drag, size: 20, color: OmniColors.muted),
      ),
    );
    if (reorderIndex != null) {
      handle = ReorderableDragStartListener(
        index: reorderIndex!,
        child: handle,
      );
    }
    final body = Row(
      children: [
        handle,
        if (icon != null) ...[
          Icon(icon, size: 18, color: ink),
          const SizedBox(width: OmniSpace.sm),
        ],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(text, style: TextStyle(fontSize: 13, color: ink)),
                if (subtitle != null) Text(subtitle!, style: OmniText.caption),
              ],
            ),
          ),
        ),
        if (trailingText != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(trailingText!, style: OmniText.caption),
                const Icon(
                  OmniIcons.chevron,
                  size: 18,
                  color: OmniColors.muted,
                ),
              ],
            ),
          ),
        if (onRemove != null)
          OmniIconAction(
            icon: OmniIcons.close,
            label: 'Remove $text',
            onPressed: onRemove,
          ),
      ],
    );
    final card = Material(
      color: OmniColors.card,
      shape: style == StepRowStyle.wait && error == null
          ? const _DashedBorder(radius: OmniRadii.step)
          : RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: borderColor),
            ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: body),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          card,
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                error!,
                style: OmniText.caption.copyWith(color: OmniColors.bad),
              ),
            ),
        ],
      ),
    );
  }
}

/// A rounded rectangle drawn with dashes, for a wait step.
class _DashedBorder extends ShapeBorder {
  const _DashedBorder({required this.radius});

  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.all(1);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect.deflate(1), textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final paint = Paint()
      ..color = OmniColors.muted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = getOuterPath(rect.deflate(0.5));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  ShapeBorder scale(double t) => _DashedBorder(radius: radius * t);
}
