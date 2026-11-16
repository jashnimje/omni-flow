import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show PinsSaved;
import '../../state/providers.dart';
import '../design/design.dart';
import 'add_pin_page.dart';
import 'board_page.dart';
import 'board_pins.dart';

/// The pins of an OmniFlow board in a sheet, for screens that set them in
/// place (the guided add, a device's Pins): each named pin with Remove, and
/// Add a pin, which opens the GPIO picker (5.2). The board page (5.1) shows
/// the same pins with their live values.
class PinSheet extends ConsumerStatefulWidget {
  const PinSheet({super.key, required this.device});

  final Json device;

  @override
  ConsumerState<PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends ConsumerState<PinSheet> {
  var _warnings = const <String>[];

  String get _id => '${widget.device['id']}';

  Json get _device =>
      ref
          .watch(devicesProvider)
          .value
          ?.where((d) => d['id'] == _id)
          .firstOrNull ??
      widget.device;

  Future<void> _add() async {
    final saved = await Navigator.of(
      context,
    ).push<PinsSaved>(MaterialPageRoute(builder: (_) => AddPinPage(id: _id)));
    if (saved != null && mounted) setState(() => _warnings = saved.warnings);
  }

  Future<void> _remove(NamedPin pin) async {
    final ok = await confirm(
      context,
      title: 'Remove ${pin.label}?',
      body:
          'Automations that use it stop working, and the board stops using '
          'GPIO ${pin.pin}. You can add it again later.',
      action: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final saved = await saveBoardPins(
      ref,
      _id,
      NamedPin.rawOf(_device)..remove(pin.name),
    );
    if (saved.value case final s? when mounted) {
      setState(() => _warnings = s.warnings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final pins = NamedPin.ofDevice(device);
    return SheetTemplate(
      title: 'Pins of ${device['name'] ?? _id}',
      subtitle: 'Each named pin shows up as a control and in automations',
      primaryLabel: 'Add a pin',
      primaryKey: const ValueKey('pin-add'),
      onPrimary: _add,
      banners: [
        for (final w in _warnings)
          OmniBanner.warning(w, key: ValueKey('pin-warning-$w')),
      ],
      children: (context) => [
        if (pins.isEmpty)
          const OmniEmptyState(
            icon: OmniIcons.board,
            title: 'No pins named yet',
            message: 'Add the button, relay or sensor you wired to it.',
            compact: true,
          ),
        for (final p in pins)
          OmniListRow(
            key: ValueKey('pin-${p.name}'),
            icon: p.role.icon,
            title: p.label,
            subtitle: p.description,
            trailing: OmniIconAction(
              key: ValueKey('pin-remove-${p.name}'),
              icon: OmniIcons.delete,
              label: 'Remove ${p.label}',
              onPressed: () => _remove(p),
            ),
          ),
      ],
    );
  }
}
