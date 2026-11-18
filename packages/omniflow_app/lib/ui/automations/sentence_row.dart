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
    final palette = OmniPalette.of(context);
    var taps = 0;
    final onBlank = widget.onBlank;
    return TextSpan(
      style: OmniText.step.copyWith(color: ink),
      children: [
        for (final p in widget.parts)
          if (p.blank case final blank? when onBlank != null)
            TextSpan(
              text: p.text,
              style: TextStyle(
                color: p.token != null ? palette.onAccentSoft : palette.accent,
                backgroundColor: p.token != null ? palette.accentSoft : null,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: palette.accentLine,
              ),
              recognizer: _tap(taps++, () => onBlank(blank)),
            )
          else if (p.token != null)
            TextSpan(
              text: p.text,
              style: TextStyle(
                color: palette.onAccentSoft,
                backgroundColor: palette.accentSoft,
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
        ? OmniPalette.of(context).bad
        : switch (w.style) {
            StepRowStyle.flow => OmniPalette.of(context).flowLine,
            _ => OmniPalette.of(context).line,
          };
    final radius = BorderRadius.circular(OmniRadii.step);
    final inBlock = RuleBlockColor.maybeOf(context);
    final ink = inBlock ?? OmniPalette.of(context).text;
    // Inside a stacked block a plain row sits on the block's own colour.
    // A wait, a group or an error keeps its edge.
    final bare =
        inBlock != null && w.error == null && w.style == StepRowStyle.normal;
    Widget handle = Semantics(
      label: 'Drag to reorder',
      child: SizedBox(
        width: 32,
        height: OmniSpace.target,
        child: Icon(
          OmniIcons.drag,
          size: 20,
          color: OmniPalette.of(context).muted,
        ),
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
            padding: const EdgeInsets.symmetric(vertical: OmniSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(_sentence(ink)),
                if (w.subtitle != null)
                  Text(w.subtitle!, style: OmniText.captionOf(context)),
              ],
            ),
          ),
        ),
        if (w.trailingText != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: OmniSpace.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(w.trailingText!, style: OmniText.captionOf(context)),
                Icon(
                  OmniIcons.chevron,
                  size: 18,
                  color: OmniPalette.of(context).muted,
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
      color: bare
          ? OmniPalette.of(context).background.withValues(alpha: 0.24)
          : OmniPalette.of(context).card,
      shape: w.style == StepRowStyle.wait && w.error == null
          ? _DashedBorder(
              radius: OmniRadii.step,
              color: OmniPalette.of(context).muted,
            )
          : RoundedRectangleBorder(
              borderRadius: radius,
              side: bare ? BorderSide.none : BorderSide(color: borderColor),
            ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: w.onTap, child: body),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _named(card),
          if (w.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OmniSpace.md,
                OmniSpace.xs,
                OmniSpace.md,
                0,
              ),
              child: Text(
                w.error!,
                style: OmniText.caption.copyWith(
                  color: OmniPalette.of(context).bad,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A rounded rectangle drawn with dashes, for a wait step.
class _DashedBorder extends ShapeBorder {
  const _DashedBorder({required this.radius, required this.color});

  final double radius;
  final Color color;

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
      ..color = color
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
  ShapeBorder scale(double t) =>
      _DashedBorder(radius: radius * t, color: color);
}
