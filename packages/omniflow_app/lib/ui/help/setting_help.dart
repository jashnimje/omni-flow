import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../design/design.dart';
import 'help_sheet.dart';

/// The first sentence of [help], which shows under a field. The whole text
/// is in the "?" sheet.
String helpSummary(String help) {
  final firstLine = help.split('\n').first.trim();
  final end = firstLine.indexOf('. ');
  return end < 0 ? firstLine : firstLine.substring(0, end + 1);
}

/// Opens the help for the setting [label]: what it is and where to find
/// it, from the driver's manifest.
Future<void> showSettingHelp(
  BuildContext context, {
  required String label,
  required String help,
}) => showHelpSheet(
  context,
  key: const ValueKey('setting-help-sheet'),
  title: label,
  sections: [(heading: 'What it is and where to find it', body: help)],
);

/// The help under a setting's field: its first sentence and a "?" that
/// opens the whole text. Null when the setting has no help, so a field can
/// pass it straight to `InputDecoration.helper`.
Widget? settingHelpLine({
  required String settingKey,
  required String label,
  String? help,
}) => help == null || help.trim().isEmpty
    ? null
    : SettingHelpLine(settingKey: settingKey, label: label, help: help);

class SettingHelpLine extends StatelessWidget {
  const SettingHelpLine({
    super.key,
    required this.settingKey,
    required this.label,
    required this.help,
  });

  final String settingKey;
  final String label;
  final String help;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: Text(
          helpSummary(help),
          key: ValueKey('setting-help-$settingKey'),
          style: OmniText.caption,
        ),
      ),
      OmniIconAction(
        key: ValueKey('setting-help-open-$settingKey'),
        icon: Symbols.help_rounded,
        label: 'Help with $label',
        onPressed: () => showSettingHelp(context, label: label, help: help),
      ),
    ],
  );
}
