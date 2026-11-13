import 'package:flutter/semantics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design/design.dart';
import 'rule_words.dart';

/// A row of the rule editor that reads as its sentence, with the parts a
/// tap edits on their own (the device, the value, the time, the text) as
/// accent words in it: "Wait `3 s`", "`Desk lamp` · `power on`". A tap on
/// one calls [onBlank] with what it edits; a tap anywhere else calls
/// [onTap], which opens the step's whole form or its page.
///
/// It looks like [OmniStepRow]: a drag handle (pass [reorderIndex] inside
/// a [ReorderableListView] without default handles), the icon, the words,
/// and a remove button or a [trailingText] for a group. An [error] draws
/// it red with the reason under it.
class SentenceRow extends StatefulWidget {
  const SentenceRow({
    super.key,
    required this.parts,
    this.icon,
    this.subtitle,
    this.style = StepRowStyle.normal,
    this.onTap,
    this.onBlank,
    this.onRemove,
    this.trailingText,
    this.reorderIndex,
    this.error,
  });

  final List<WordPart> parts;
  final IconData? icon;
  final String? subtitle;
  final StepRowStyle style;
  final VoidCallback? onTap;
  final void Function(Blank blank)? onBlank;
  final VoidCallback? onRemove;
  final String? trailingText;
  final int? reorderIndex;
  final String? error;

  /// The sentence as plain words.
  String get text => joinParts(parts);

  @override
  State<SentenceRow> createState() => _SentenceRowState();
}

class _SentenceRowState extends State<SentenceRow> {
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(int i, VoidCallback onTap) {
    while (_taps.length <= i) {
      _taps.add(TapGestureRecognizer());
    }
    return _taps[i]..onTap = onTap;
  }

  InlineSpan _sentence(Color ink) {
    var taps = 0;
    final onBlank = widget.onBlank;
    return TextSpan(
      style: TextStyle(fontSize: 13, color: ink),
      children: [
        for (final p in widget.parts)
          if (p.blank case final blank? when onBlank != null)
            TextSpan(
              text: p.text,
              style: TextStyle(
                color: p.token != null
                    ? OmniColors.onAccentSoft
                    : OmniColors.accent,
                backgroundColor: p.token != null ? OmniColors.accentSoft : null,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: OmniColors.accentLine,
              ),
              recognizer: _tap(taps++, () => onBlank(blank)),
            )
          else if (p.token != null)
            TextSpan(
              text: p.text,
              style: const TextStyle(
                color: OmniColors.onAccentSoft,
                backgroundColor: OmniColors.accentSoft,
              ),
            )
          else
            TextSpan(text: p.text),
      ],
    );
  }

  /// [card] with a named screen reader action for each blank ("Change
  /// device"), beside the blanks' own links, which read as their words.
  Widget _named(Widget card) {
    final onBlank = widget.onBlank;
    final blanks = {for (final p in widget.parts) ?p.blank};
    if (onBlank == null || blanks.isEmpty) return card;
    return Semantics(
      customSemanticsActions: {
        for (final b in blanks)
          CustomSemanticsAction(label: 'Change ${b.words}'): () => onBlank(b),
      },
      child: card,
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final borderColor = w.error != null
        ? OmniColors.bad
        : switch (w.style) {
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
    if (w.reorderIndex != null) {
      handle = ReorderableDragStartListener(
        index: w.reorderIndex!,
        child: handle,
      );
    }
    final body = Row(
      children: [
        handle,
        if (w.icon != null) ...[
          Icon(w.icon, size: 18, color: ink),
          const SizedBox(width: OmniSpace.sm),
        ],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(_sentence(ink)),
                if (w.subtitle != null)
                  Text(w.subtitle!, style: OmniText.caption),
              ],
            ),
          ),
        ),
        if (w.trailingText != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(w.trailingText!, style: OmniText.caption),
                const Icon(
                  OmniIcons.chevron,
                  size: 18,
                  color: OmniColors.muted,
                ),
              ],
            ),
          ),
        if (w.onRemove != null)
          OmniIconAction(
            icon: OmniIcons.close,
            label: 'Remove ${w.text}',
            onPressed: w.onRemove,
          ),
      ],
    );
    final card = Material(
      color: OmniColors.card,
      shape: w.style == StepRowStyle.wait && w.error == null
          ? const _DashedBorder(radius: OmniRadii.step)
          : RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: borderColor),
            ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: w.onTap, child: body),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _named(card),
          if (w.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                w.error!,
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
