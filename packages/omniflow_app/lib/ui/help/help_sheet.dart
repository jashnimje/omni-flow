import 'package:flutter/material.dart';

import '../design/design.dart';

/// One part of a help sheet: a short heading and its plain words.
typedef HelpSection = ({String heading, String body});

/// Help text as paragraphs: each line is one, and a line that starts with
/// a number and a dot ("1. Open...") is a numbered step.
class HelpText extends StatelessWidget {
  const HelpText(this.text, {super.key});

  final String text;

  static final _step = RegExp(r'^(\d+)\.\s+(.*)$');

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: switch (_step.firstMatch(line.trim())) {
              final m? => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: OmniSpace.xl,
                    child: Text('${m[1]}.', style: OmniText.bodyStrong),
                  ),
                  Expanded(child: Text(m[2]!, style: OmniText.body)),
                ],
              ),
              null => Text(line.trim(), style: OmniText.body),
            },
          ),
    ],
  );
}

/// Opens a help sheet with [title], an optional [intro] and [sections],
/// then [extra] widgets (rows that open more help).
Future<void> showHelpSheet(
  BuildContext context, {
  required String title,
  String? intro,
  List<HelpSection> sections = const [],
  List<Widget> extra = const [],
  Key? key,
}) => SheetTemplate.show<void>(
  context,
  builder: (context) => SheetTemplate(
    key: key,
    title: title,
    subtitle: intro,
    primaryLabel: 'Got it',
    primaryKey: const ValueKey('help-close'),
    onPrimary: () => Navigator.of(context).pop(),
    children: (context) => [
      for (final s in sections) ...[
        Padding(
          padding: const EdgeInsets.only(
            top: OmniSpace.sm,
            bottom: OmniSpace.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(s.heading, style: OmniText.bodyStrong),
          ),
        ),
        HelpText(s.body),
      ],
      ...extra,
    ],
  ),
);
