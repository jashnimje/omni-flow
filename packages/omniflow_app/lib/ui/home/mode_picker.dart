import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/house_providers.dart';
import '../../state/providers.dart';
import '../automations/form_parts.dart' show ChoiceRow;
import '../design/design.dart';

/// The icon each built-in mode shows, and one for the user's own.
IconData modeIcon(String id) => switch (id) {
  'home' => OmniIcons.home,
  'away' => Icons.directions_walk_rounded,
  'night' => Icons.bedtime_rounded,
  'vacation' => Icons.luggage_rounded,
  _ => Icons.label_rounded,
};

/// The house mode at the top of Home: a chip that opens the picker.
/// Nothing shows while the engine has no mode.
class ModeChip extends ConsumerWidget {
  const ModeChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = ref.watch(houseModeProvider).value;
    if (modes == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: OmniSpace.sm),
        child: Semantics(
          hint: 'Opens the house modes',
          child: OmniFilterChip(
            key: const ValueKey('mode-chip'),
            label: 'Mode: ${modes.name}',
            icon: modeIcon(modes.mode),
            onTap: () => showModePicker(context, ref),
          ),
        ),
      ),
    );
  }
}

/// Picks the house mode: every mode, the one now ticked.
Future<void> showModePicker(BuildContext context, WidgetRef ref) async {
  final modes = ref.read(houseModeProvider).value;
  if (modes == null) return;
  final picked = await showOmniSheet<String>(
    context,
    builder: (context) => OmniSheet(
      title: 'House mode',
      subtitle: 'Automations can start when it changes, or check it.',
      children: [
        for (final m in modes.modes)
          ChoiceRow(
            key: ValueKey('mode-${m.id}'),
            title: m.name,
            icon: modeIcon(m.id),
            selected: m.id == modes.mode,
            onTap: () => Navigator.of(context).pop(m.id),
          ),
        const SizedBox(height: OmniSpace.sm),
        const Text(
          'Add your own modes, or let the mode follow who is home, in '
          'Settings, Alerts and modes.',
          style: OmniText.caption,
        ),
      ],
    ),
  );
  if (picked == null || picked == modes.mode) return;
  final r = await ref.read(houseApiProvider).setMode(picked);
  if (r['ok'] != true) {
    showMessage(errorMessage(r));
    return;
  }
  await ref.read(houseModeProvider.notifier).refresh();
}
