import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/rule_calls.dart';
import '../design/design.dart';
import 'rule_words.dart';

/// Where a field's tokens come from: the values the engine says are
/// available at the field's step (`rule.tokens`), loaded once per form.
/// The labels it gets are kept in [words], so rows show them too.
class TokenSource {
  TokenSource(this._load, {required this.words});

  /// A source with no tokens, for a form opened outside a rule.
  TokenSource.none({required this.words}) : _load = _nothing;

  static Future<List<RuleToken>> _nothing() async => const [];

  final Future<List<RuleToken>> Function() _load;
  final RuleWords words;

  late final Future<List<RuleToken>> tokens = _load().then((tokens) {
    for (final t in tokens) {
      words.tokenLabels[t.token] = t.label;
    }
    return tokens;
  });

  /// [inside] in words: its label, or its name.
  String labelOf(String inside) => words.tokenText(inside);
}

/// Shows each `{{...}}` in the field in the token colour, so a value from
/// an earlier step stands out from typed text.
class TokenController extends TextEditingController {
  TokenController({super.text});

  static final _template = RegExp(r'\{\{[^{}]+\}\}');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!_template.hasMatch(text) || value.composing.isValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in _template.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(
        TextSpan(
          text: m.group(0),
          style: const TextStyle(
            color: OmniColors.onAccentSoft,
            backgroundColor: OmniColors.accentSoft,
          ),
        ),
      );
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }

  /// Puts [template] where the cursor is, or at the end.
  void insert(String template) {
    final sel = selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, template);
    value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + template.length),
    );
  }
}

/// A text field that also takes values from earlier steps and the
/// trigger: the [source]'s tokens show as chips under it and insert
/// `{{token}}` where the cursor is, and the tokens already in the field
/// show by their labels. [id] names its keys: `<id>-token-<token>` for an
/// insert chip, `<id>-has-<token>` for one in the field.
class TokenField extends StatelessWidget {
  const TokenField({
    super.key,
    required this.id,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.source,
    this.hint,
    this.error,
    this.autofocus = false,
    this.kinds,
  });

  final String id;
  final String label;
  final TokenController controller;
  final ValueChanged<String> onChanged;
  final TokenSource? source;
  final String? hint;
  final String? error;
  final bool autofocus;

  /// The token kinds that fit the field (`number` for a sum), or all.
  final Set<String>? kinds;

  static final _template = RegExp(r'\{\{([^{}]+)\}\}');

  @override
  Widget build(BuildContext context) {
    final used = [
      for (final m in _template.allMatches(controller.text))
        RuleCalls.inside(m.group(1)!),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            autofocus: autofocus,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              errorText: error,
            ),
            onChanged: onChanged,
          ),
          if (used.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.xs),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Uses', style: OmniText.caption),
                  for (final t in used.toSet())
                    TokenChip(
                      key: ValueKey('$id-has-$t'),
                      label: source?.labelOf(t) ?? t,
                    ),
                ],
              ),
            ),
          if (source != null)
            FutureBuilder<List<RuleToken>>(
              future: source!.tokens,
              builder: (context, snap) {
                final tokens = [
                  for (final t in snap.data ?? const <RuleToken>[])
                    if (kinds == null ||
                        t.kind == 'any' ||
                        kinds!.contains(t.kind))
                      t,
                ];
                if (tokens.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: OmniSpace.xs),
                  child: Wrap(
                    key: ValueKey('$id-tokens'),
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Add a value', style: OmniText.caption),
                      for (final t in tokens)
                        TokenChip(
                          key: ValueKey('$id-token-${t.token}'),
                          label: t.label,
                          semanticLabel: 'Add ${t.label} to $label',
                          onTap: () {
                            controller.insert(t.template);
                            onChanged(controller.text);
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// A value from an earlier step or the trigger, as a small chip: one in a
/// field, or one to add when [onTap] is set.
class TokenChip extends StatelessWidget {
  const TokenChip({
    super.key,
    required this.label,
    this.onTap,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: OmniColors.accentSoft,
        borderRadius: BorderRadius.circular(OmniRadii.chip),
        border: Border.all(color: OmniColors.accentLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            onTap == null ? AutomationIcons.variable : Symbols.add_rounded,
            size: 14,
            color: OmniColors.onAccentSoft,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: OmniColors.onAccentSoft,
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      label: semanticLabel ?? 'Value: $label',
      excludeSemantics: true,
      onTap: onTap,
      child: onTap == null ? chip : OmniTapTarget(onTap: onTap, child: chip),
    );
  }
}
