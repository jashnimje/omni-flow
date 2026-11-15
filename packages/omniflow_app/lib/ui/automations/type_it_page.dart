import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/suggestion_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'rule_editor.dart';

/// How long typing pauses before the sentence is read.
const typeItDebounce = Duration(milliseconds: 400);

/// Opens "Type what you want" over [tabContext], and the rule it read in
/// the editor there when the person taps Open in editor. Nothing is saved
/// until they save it in the editor.
Future<void> openTypeIt(BuildContext tabContext) async {
  final spec = await showOmniSheet<Json>(
    tabContext,
    builder: (_) => const TypeItSheet(),
  );
  if (spec == null || !tabContext.mounted) return;
  await openRuleEditor(tabContext, spec: spec);
}

/// A text field that reads the sentence as a rule while the person types:
/// the rule's sentence, the words it could not place marked, why it cannot
/// make a rule, and Open in editor.
class TypeItSheet extends ConsumerStatefulWidget {
  const TypeItSheet({super.key});

  @override
  ConsumerState<TypeItSheet> createState() => _TypeItSheetState();
}

class _TypeItSheetState extends ConsumerState<TypeItSheet> {
  final _text = TextEditingController();
  Timer? _debounce;
  ParsedRule? _parsed;

  /// The text [_parsed] was read from.
  String _readText = '';
  var _reading = false;
  var _silent = false;

  /// Counts each read, so an answer to an older one is dropped.
  var _turn = 0;

  static const _examples = [
    'Turn off the lights when I leave',
    'At 7 every weekday turn on the kettle',
    'Every day at sunset turn on the hall light',
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _parsed = null;
        _reading = false;
      });
      return;
    }
    setState(() => _reading = true);
    _debounce = Timer(typeItDebounce, () => _read(value));
  }

  Future<void> _read(String value) async {
    final turn = ++_turn;
    final parsed = await SuggestionCalls.read(
      ref.read(engineClientProvider),
      value,
    );
    if (!mounted || turn != _turn) return;
    setState(() {
      _reading = false;
      _silent = parsed == null;
      _parsed = parsed;
      _readText = value;
    });
  }

  void _example(String text) {
    _text
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    _changed(text);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final spec = parsed?.spec;
    final current = _text.text == _readText;
    return OmniSheet(
      title: 'Type what you want',
      subtitle:
          'Say it in one sentence. You check it in the editor before '
          'anything is saved.',
      children: [
        TextField(
          key: const ValueKey('type-it-field'),
          controller: _text,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Like "turn off the lights when I leave"',
          ),
          onChanged: _changed,
        ),
        const SizedBox(height: OmniSpace.md),
        if (_text.text.trim().isEmpty) ...[
          const Text('Try one of these', style: OmniText.caption),
          const SizedBox(height: OmniSpace.xs),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in _examples)
                OmniFilterChip(label: e, onTap: () => _example(e)),
            ],
          ),
        ] else if (_silent)
          const Text(
            'OmniFlow did not answer. Try again in a moment.',
            key: ValueKey('type-it-silent'),
            style: OmniText.caption,
          )
        else if (parsed != null) ...[
          if (spec != null) ...[
            const Text('It reads as', style: OmniText.caption),
            const SizedBox(height: OmniSpace.xs),
            KeyedSubtree(
              key: const ValueKey('type-it-sentence'),
              child: AutomationSentence(parsed.sentence),
            ),
          ] else
            Text(
              parsed.problem ?? 'That does not make a rule yet.',
              key: const ValueKey('type-it-problem'),
              style: OmniText.body.copyWith(color: OmniColors.warn),
            ),
          if (parsed.unknown.isNotEmpty) ...[
            const SizedBox(height: OmniSpace.sm),
            UnknownWords(text: _readText, unknown: parsed.unknown),
          ],
          for (final c in parsed.choices)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.sm),
              child: Text(
                '"${c.text}" is ${c.chosen}. It could also be '
                '${c.others.join(' or ')}: change it in the editor.',
                style: OmniText.caption,
              ),
            ),
          for (final n in parsed.notes)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.sm),
              child: Text(n, style: OmniText.caption),
            ),
        ],
        if (_reading)
          const Padding(
            padding: EdgeInsets.only(top: OmniSpace.sm),
            child: Text(
              'Reading…',
              key: ValueKey('type-it-reading'),
              style: OmniText.caption,
            ),
          ),
        const SizedBox(height: OmniSpace.lg),
        OmniButton(
          key: const ValueKey('type-it-open'),
          label: 'Open in editor',
          icon: OmniIcons.edit,
          onPressed: spec != null && current && !_reading
              ? () => Navigator.of(context).pop(spec)
              : null,
        ),
      ],
    );
  }
}

/// [text] as typed, with each of the [unknown] words marked, and a line
/// a screen reader hears saying which words were not understood.
class UnknownWords extends StatelessWidget {
  const UnknownWords({super.key, required this.text, required this.unknown});

  final String text;
  final List<String> unknown;

  static String _bare(String word) =>
      word.toLowerCase().replaceAll(RegExp(r'''^["'(]+|["'),.!?;:]+$'''), '');

  @override
  Widget build(BuildContext context) {
    final marked = unknown.toSet();
    final words = text.trim().split(RegExp(r'\s+'));
    return Semantics(
      label: 'Not understood: ${unknown.join(', ')}',
      excludeSemantics: true,
      child: Text.rich(
        key: const ValueKey('type-it-unknown'),
        TextSpan(
          style: OmniText.body,
          children: [
            const TextSpan(text: 'Not understood: ', style: OmniText.caption),
            for (var i = 0; i < words.length; i++) ...[
              if (i > 0) const TextSpan(text: ' '),
              marked.contains(_bare(words[i]))
                  ? TextSpan(
                      text: words[i],
                      style: const TextStyle(
                        color: OmniColors.warn,
                        decoration: TextDecoration.underline,
                        decorationColor: OmniColors.warn,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : TextSpan(text: words[i]),
            ],
          ],
        ),
      ),
    );
  }
}
