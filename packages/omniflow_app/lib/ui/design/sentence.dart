import 'package:flutter/material.dart';

import '../../api/engine_calls.dart' show SentenceKind, SentencePart;
import 'icons.dart';
import 'tokens.dart';

export '../../api/engine_calls.dart' show SentenceKind, SentencePart;

/// The colours of each part of an automation: WHEN orange, ONLY IF purple,
/// THEN accent, flow control pink.
abstract final class SentenceColors {
  static Color of(SentenceKind kind) => switch (kind) {
    SentenceKind.when => OmniColors.trigger,
    SentenceKind.onlyIf => OmniColors.condition,
    SentenceKind.then => OmniColors.action,
    SentenceKind.flow => OmniColors.flowControl,
    SentenceKind.text => OmniColors.muted,
  };

  static Color softOf(SentenceKind kind) => switch (kind) {
    SentenceKind.when => OmniColors.triggerSoft,
    SentenceKind.onlyIf => OmniColors.conditionSoft,
    SentenceKind.then => OmniColors.actionSoft,
    SentenceKind.flow => OmniColors.flowSoft,
    SentenceKind.text => Colors.transparent,
  };
}

/// One coloured phrase of a sentence ("When I get home").
class SentenceChip extends StatelessWidget {
  const SentenceChip(this.kind, this.text, {super.key});

  final SentenceKind kind;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: SentenceColors.softOf(kind),
      borderRadius: BorderRadius.circular(OmniShape.sm),
    ),
    child: Text(
      text,
      style: OmniText.caption.copyWith(color: SentenceColors.of(kind)),
    ),
  );
}

/// An automation's sentence as one plain line: the arrows the card draws
/// between its parts read as commas.
String sentenceText(List<SentencePart> parts) => parts
    .map((p) => p.text)
    .join(' ')
    .replaceAll(' → ', ', ')
    .replaceAll('→', ',');

/// An automation written as its sentence: chips for the WHEN, ONLY IF and
/// THEN parts and plain muted words ("then", "→") between them, wrapping.
/// Screen readers hear the whole sentence as one line, the arrows as
/// commas ([sentenceText]).
class AutomationSentence extends StatelessWidget {
  const AutomationSentence(this.parts, {super.key});

  final List<SentencePart> parts;

  @override
  Widget build(BuildContext context) => Semantics(
    label: sentenceText(parts),
    excludeSemantics: true,
    child: Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final p in parts)
          if (p.kind == SentenceKind.text)
            Text(p.text, style: OmniText.step.copyWith(color: OmniColors.muted))
          else
            SentenceChip(p.kind, p.text),
      ],
    ),
  );
}

/// One block of the rule editor: a coloured left rule, the [heading]
/// ("WHEN") with its [caption] ("any of these"), the rows, and the add
/// link ("＋ Add trigger").
class OmniRuleBlock extends StatelessWidget {
  const OmniRuleBlock({
    super.key,
    required this.kind,
    required this.heading,
    required this.caption,
    required this.children,
    this.addLabel,
    this.onAdd,
  });

  final SentenceKind kind;
  final String heading;
  final String caption;
  final List<Widget> children;
  final String? addLabel;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final color = SentenceColors.of(kind);
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${heading.toUpperCase()} · $caption',
                style: OmniText.blockHeading.copyWith(color: color),
              ),
            ),
          ),
          RuleBlockColor(
            color: color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
          if (addLabel != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(OmniIcons.add, size: 18),
                label: Text(addLabel!),
                style: TextButton.styleFrom(
                  foregroundColor: OmniPalette.of(context).accent,
                  minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  textStyle: OmniText.caption,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The colour of the rule block around a step row, so its words read in
/// the block's colour (WHEN orange, ONLY IF purple, THEN cyan).
class RuleBlockColor extends InheritedWidget {
  const RuleBlockColor({super.key, required this.color, required super.child});

  final Color color;

  static Color? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RuleBlockColor>()?.color;

  @override
  bool updateShouldNotify(RuleBlockColor old) => old.color != color;
}
