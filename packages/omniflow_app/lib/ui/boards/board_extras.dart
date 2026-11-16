import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'usb_board.dart';
import 'board_pins.dart';

/// The setup of one extra on a board (an IR LED, an RF transmitter, an NFC
/// reader): the GPIO each of its lines takes, Save, and Remove. The board
/// takes extras over USB only, which the engine says when it is on Wi-Fi.
/// Pops true when something changed.
class ExtraSheet extends ConsumerStatefulWidget {
  const ExtraSheet({
    super.key,
    required this.boardId,
    required this.type,
    required this.info,
  });

  final String boardId;
  final String type;
  final BoardInfo info;

  @override
  ConsumerState<ExtraSheet> createState() => _ExtraSheetState();
}

class _ExtraSheetState extends ConsumerState<ExtraSheet> {
  late var _type = widget.type;
  late final _set = widget.info.periph
      .where((p) => p.type == widget.type)
      .firstOrNull;
  final _fields = <String, TextEditingController>{};
  ApiFailure? _failure;
  var _busy = false;

  bool get _nfc => _type == BoardExtras.rc522 || _type == BoardExtras.pn532;

  TextEditingController _field(String line) => _fields.putIfAbsent(
    line,
    () => TextEditingController(text: _set?.pins[line]?.toString() ?? ''),
  );

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, int>? get _pins {
    final pins = <String, int>{};
    for (final line in BoardExtras.lines(_type)) {
      final n = int.tryParse(_field(line).text.trim());
      if (n == null) return null;
      pins[line] = n;
    }
    return pins;
  }

  Future<void> _run({bool clear = false}) async {
    if (clear) {
      final ok = await confirm(
        context,
        title: 'Remove the ${BoardExtras.title(_type)}?',
        body:
            'The board stops using its pins, and automations that '
            '${BoardExtras.job(_type)} with it stop working.',
        action: 'Remove',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    final navigator = Navigator.of(context);
    final devices = ref.read(devicesProvider.notifier);
    setState(() {
      _busy = true;
      _failure = null;
    });
    final engine = ref.read(engineClientProvider);
    final device = ref
        .read(devicesProvider)
        .value
        ?.where((d) => d['id'] == widget.boardId)
        .firstOrNull;
    // A board on Wi-Fi takes extras only on USB: the same board plugged into
    // this phone gets them through its port.
    String? port;
    if (device != null && !'${device['host']}'.startsWith('usb:')) {
      final node = device['stableId'];
      port = (await findUsbBoards(engine))
          .where((b) => b.node != null && b.node == node)
          .firstOrNull
          ?.port;
    }
    final reply = await EngineApi(engine).setBoardPeriph(
      widget.boardId,
      _type,
      pins: _pins ?? const {},
      clear: clear,
      port: port,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failure = reply.failure;
    });
    if (!reply.ok) return;
    await devices.refresh();
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final knownNfc = [
      for (final t in [BoardExtras.rc522, BoardExtras.pn532])
        if (widget.info.periphTypes.contains(t)) t,
    ];
    return SheetTemplate(
      title: BoardExtras.title(_type),
      subtitle: _set == null
          ? 'Not set · ${BoardExtras.job(_type)}'
          : 'Set · ${BoardExtras.job(_type)}',
      primaryLabel: 'Save',
      primaryKey: const ValueKey('extra-save'),
      onPrimary: _busy || _pins == null ? null : _run,
      missing: _busy ? null : 'Give every pin a GPIO number first.',
      banners: [
        if (_failure case final f?)
          OmniBanner.error(key: const ValueKey('extra-failed'), f.message),
      ],
      children: (context) => [
        const OmniBanner.info(
          'A board takes extras over USB only, so it cannot be changed from '
          'across the room. Plug it into this phone with a USB cable, then '
          'save.',
        ),
        if (_nfc && knownNfc.length > 1 && _set == null)
          OmniSegmented<String>(
            segments: [
              for (final t in knownNfc) OmniSegment(t, BoardExtras.chip(t)),
            ],
            selected: _type,
            onChanged: (t) => setState(() => _type = t),
          ),
        for (final line in BoardExtras.lines(_type))
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: TextField(
              key: ValueKey('extra-pin-$line'),
              controller: _field(line),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: BoardExtras.lineLabel(line),
                hintText: 'GPIO number',
              ),
              onChanged: (_) => setState(() => _failure = null),
            ),
          ),
        if (_set != null) ...[
          const SizedBox(height: OmniSpace.sm),
          OmniButton.danger(
            key: const ValueKey('extra-clear'),
            label: 'Remove this extra',
            onPressed: _busy ? null : () => _run(clear: true),
          ),
        ],
      ],
    );
  }
}
