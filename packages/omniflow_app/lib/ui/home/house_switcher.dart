import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/house.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../onboarding/home_setup.dart' show SetupStep, openHomeSetup;

/// The steps a new house goes through: the same as the first run's, less
/// the ones that belong to the person (who you are) or come later.
const newHouseSteps = [SetupStep.home, SetupStep.presence];

/// The house in view at the top of Home, as its name with a down arrow.
/// It opens the list of houses. Nothing shows with an engine that has no
/// houses.
class HouseSwitcher extends ConsumerWidget {
  const HouseSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final house = ref.watch(houseShownProvider);
    if (house == null) return const SizedBox.shrink();
    final palette = OmniPalette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: 'House: ${house.name}',
      hint: 'Opens the list of houses',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('house-switcher'),
        borderRadius: BorderRadius.circular(OmniRadii.tile),
        onTap: () => showHouses(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OmniSpace.target),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(OmniIcons.home, size: 20, color: palette.onAccentSoft),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  house.name,
                  key: const ValueKey('house-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmniText.label.copyWith(color: palette.onAccentSoft),
                ),
              ),
              Icon(
                Symbols.keyboard_arrow_down_rounded,
                size: 22,
                color: palette.onAccentSoft,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every house, the one shown ticked, with Add a house. Each house can be
/// renamed or removed from its menu.
Future<void> showHouses(BuildContext context) => showOmniSheet<void>(
  context,
  builder: (sheet) => Consumer(
    builder: (context, ref, _) {
      final houses = ref.watch(housesProvider).value ?? const <House>[];
      final shown = ref.watch(houseInViewProvider).value;
      return OmniSheet(
        title: 'Houses',
        subtitle: 'The app shows one house at a time',
        children: [
          for (final h in houses)
            OmniListRow(
              key: ValueKey('house-${h.id}'),
              icon: OmniIcons.home,
              title: h.name,
              selected: h.id == shown,
              value: h.id == shown ? 'Showing' : null,
              onTap: () {
                Navigator.of(sheet).pop();
                if (h.id != shown) {
                  ref.read(houseInViewProvider.notifier).show(h.id);
                }
              },
              trailing: PopupMenuButton<String>(
                key: ValueKey('house-menu-${h.id}'),
                tooltip: 'More for ${h.name}',
                onSelected: (action) => action == 'rename'
                    ? _rename(sheet, ref, h)
                    : _remove(sheet, ref, h),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'remove', child: Text('Remove')),
                ],
              ),
            ),
          OmniListRow(
            key: const ValueKey('house-add'),
            icon: OmniIcons.add,
            title: 'Add a house',
            subtitle: 'A second home, with its own devices and automations',
            divider: false,
            onTap: () => _add(sheet, ref),
          ),
        ],
      );
    },
  ),
);

/// Asks for a house's name. Null when cancelled or left empty.
Future<String?> askHouseName(
  BuildContext context, {
  required String title,
  String initial = '',
  required String action,
}) async {
  final field = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (dialog) => Owning(
      [field],
      child: AlertDialog(
        title: Text(title),
        content: TextField(
          key: const ValueKey('house-name-field'),
          controller: field,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Name',
            helperText: 'Like Mumbai, or Work flat',
          ),
          onSubmitted: (v) => Navigator.of(dialog).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('house-name-save'),
            onPressed: () => Navigator.of(dialog).pop(field.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
  return name == null || name.isEmpty ? null : name;
}

/// [reply] as it came, with the engine's words shown when it refused.
Json _said(Json reply) {
  if (reply['ok'] != true) showMessage(errorMessage(reply));
  return reply;
}

/// Adds a house, shows it, then goes through where it is and its Wi-Fi.
Future<void> _add(BuildContext sheet, WidgetRef ref) async {
  final name = await askHouseName(sheet, title: 'Add a house', action: 'Add');
  if (name == null) return;
  final r = _said(await ref.read(housesApiProvider).add(name));
  if (r['ok'] != true) return;
  final added = r['house'] is Map ? (r['house'] as Map)['id'] : r['id'];
  await ref.read(housesProvider.notifier).refresh();
  if (added is String) await ref.read(houseInViewProvider.notifier).show(added);
  if (!sheet.mounted) return;
  Navigator.of(sheet).pop();
  await openHomeSetup(sheet, steps: newHouseSteps);
}

Future<void> _rename(BuildContext sheet, WidgetRef ref, House h) async {
  final name = await askHouseName(
    sheet,
    title: 'Rename ${h.name}',
    initial: h.name,
    action: 'Rename',
  );
  if (name == null || name == h.name) return;
  final r = _said(await ref.read(housesApiProvider).rename(h.id, name));
  if (r['ok'] == true) await ref.read(housesProvider.notifier).refresh();
}

/// Removes a house. The engine refuses while it still has things in it,
/// and its words say what to do.
Future<void> _remove(BuildContext sheet, WidgetRef ref, House h) async {
  final sure = await confirm(
    sheet,
    title: 'Remove ${h.name}?',
    body:
        'Only an empty house can be removed. Move or remove its devices, '
        'automations and scenes first.',
    action: 'Remove',
    destructive: true,
  );
  if (!sure) return;
  final r = _said(await ref.read(housesApiProvider).remove(h.id));
  if (r['ok'] == true) await ref.read(housesProvider.notifier).refresh();
}
