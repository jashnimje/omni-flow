import 'package:flutter/material.dart';

import '../../api/engine_calls.dart' show SentenceKind, SentencePart;
import 'icons.dart';
import 'tokens.dart';

export '../../api/engine_calls.dart' show SentenceKind, SentencePart;

/// The colours of each part of an automation in [OmniPalette]: WHEN the
/// trigger colour, ONLY IF the condition colour, THEN the accent, flow
/// control pink.
abstract final class SentenceColors {
  static Color of(OmniPalette p, SentenceKind kind) => switch (kind) {
    SentenceKind.when => p.trigger,
    SentenceKind.onlyIf => p.condition,
    SentenceKind.then => p.action,
    SentenceKind.flow => p.flowControl,
    SentenceKind.text => p.muted,
  };

  /// The soft fill behind a part of [kind]: a chip, an editor block.
  static Color softOf(OmniPalette p, SentenceKind kind) => switch (kind) {
    SentenceKind.when => p.triggerSoft,
    SentenceKind.onlyIf => p.conditionSoft,
    SentenceKind.then => p.actionSoft,
    SentenceKind.flow => p.flowSoft,
    SentenceKind.text => p.card,
  };

  /// The icon beside an editor block's heading.
  static IconData iconOf(SentenceKind kind) => switch (kind) {
    SentenceKind.when => OmniIcons.time,
    SentenceKind.onlyIf => OmniIcons.info,
    SentenceKind.then => OmniIcons.play,
    SentenceKind.flow => OmniIcons.branch,
    SentenceKind.text => OmniIcons.automations,
  };
}

/// One coloured phrase of a sentence ("When I get home").
class SentenceChip extends StatelessWidget {
  const SentenceChip(this.kind, this.text, {super.key});

  final SentenceKind kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = OmniPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: SentenceColors.softOf(p, kind),
        borderRadius: BorderRadius.circular(OmniShape.sm),
      ),
      child: Text(
        text,
        style: OmniText.caption.copyWith(color: SentenceColors.of(p, kind)),
      ),
    );
  }
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
            Text(
              p.text,
              style: OmniText.step.copyWith(
                color: OmniPalette.of(context).muted,
              ),
            )
          else
            SentenceChip(p.kind, p.text),
      ],
    ),
  );
}

/// One stacked block of the rule editor: a rounded card in its [kind]'s
/// soft colour, the [heading] ("WHEN") with an optional [caption] ("any of
/// these") beside the kind's icon, then the rows, whose words read in the
/// body text colour. [addLabel] adds a "+ Add trigger" link under the
/// rows. Without one, an empty block ([isEmpty]) offers [emptyLabel]
/// ("Choose what starts it") as one big target that calls [onAdd].
class OmniRuleBlock extends StatelessWidget {
  const OmniRuleBlock({
    super.key,
    required this.kind,
    required this.heading,
    required this.caption,
    required this.children,
    this.addLabel,
    this.onAdd,
    this.isEmpty = false,
    this.emptyLabel,
  });

  final SentenceKind kind;
  final String heading;
  final String caption;
  final List<Widget> children;
  final String? addLabel;
  final VoidCallback? onAdd;
  final bool isEmpty;
  final String? emptyLabel;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final color = SentenceColors.of(palette, kind);
    final title = caption.isEmpty
        ? heading.toUpperCase()
        : '${heading.toUpperCase()} · $caption';
    return Container(
      margin: const EdgeInsets.only(bottom: OmniSpace.sm),
      padding: const EdgeInsets.fromLTRB(
        OmniSpace.lg,
        OmniSpace.md,
        OmniSpace.sm,
        OmniSpace.sm,
      ),
      decoration: BoxDecoration(
        color: SentenceColors.softOf(palette, kind),
        borderRadius: BorderRadius.circular(OmniRadii.step),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: OmniSpace.sm),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      SentenceColors.iconOf(kind),
                      size: 18,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: OmniSpace.sm),
                  Expanded(
                    child: Text(
                      title,
                      style: OmniText.blockHeading.copyWith(color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
          RuleBlockColor(
            color: palette.text,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
          if (isEmpty &&
              addLabel == null &&
              emptyLabel != null &&
              onAdd != null)
            Padding(
              padding: const EdgeInsets.only(bottom: OmniSpace.sm),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(OmniRadii.step),
                  onTap: onAdd,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: OmniSpace.targetLarge,
                    ),
                    child: Row(
                      children: [
                        Icon(OmniIcons.add, color: color),
                        const SizedBox(width: OmniSpace.sm),
                        Expanded(
                          child: Text(
                            emptyLabel!,
                            style: OmniText.body.copyWith(color: palette.text),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                  foregroundColor: palette.accent,
                  minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  textStyle: OmniText.label,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The ink of the rule block around a step row, so its words and icon
/// read in the colour the block sets.
class RuleBlockColor extends InheritedWidget {
  const RuleBlockColor({super.key, required this.color, required super.child});

  final Color color;

  static Color? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RuleBlockColor>()?.color;

  @override
  bool updateShouldNotify(RuleBlockColor old) => old.color != color;
}
