import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/clock.dart';
import '../../state/providers.dart';
import '../add/room_field.dart';
import '../design/design.dart';
import 'usb_board.dart';
import 'add_pin_page.dart';
import 'board_extras.dart';
import 'board_pins.dart';

/// Saves [pins] as the whole pin set of board [id] and reloads the devices.
/// [quiet] leaves a refusal for the caller to show inline.
Future<Reply<PinsSaved>> saveBoardPins(
  WidgetRef ref,
  String id,
  Json pins, {
  bool quiet = false,
}) async {
  final devices = ref.read(devicesProvider.notifier);
  final api = quiet
      ? EngineApi(ref.read(engineClientProvider))
      : ref.read(engineApiProvider);
  final reply = await api.saveBoardPins(id, pins);
  await devices.refresh();
  if (reply.value?.provisionError case final error?) {
    showMessage(
      'Saved. The board is not answering, so it is set up when it answers: '
      '$error',
    );
  }
  return reply;
}

/// 5.1 Board page: what the board is and whether it answers, its pins with
/// their live values or a switch, and its extras.
class BoardPage extends ConsumerStatefulWidget {
  const BoardPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  Reply<BoardInfo>? _info;
  var _warnings = const <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_describe());
  }

  /// Quiet: an offline board is a state of this page, not a snackbar.
  Future<void> _describe() async {
    final reply = await EngineApi(ref.read(engineClientProvider))
        .boardDescribe(widget.id);
    if (!mounted) return;
    setState(() {
      _info = reply;
      _warnings = reply.value?.warnings ?? const [];
    });
  }

  Json? get _device => ref
      .watch(devicesProvider)
      .value
      ?.where((d) => d['id'] == widget.id)
      .firstOrNull;

  Future<void> _addPin() async {
    final added = await Navigator.of(context).push<PinsSaved>(
      MaterialPageRoute(builder: (_) => AddPinPage(id: widget.id)),
    );
    if (added != null && mounted) {
      setState(() => _warnings = added.warnings);
      unawaited(_describe());
    }
  }

  Future<void> _pinSheet(Json device, NamedPin pin) async {
    final remove = await SheetTemplate.show<bool>(
      context,
      builder: (context) => SheetTemplate(
        title: pin.label,
        subtitle: pin.description,
        primaryLabel: 'Remove this pin',
        primaryKey: const ValueKey('pin-remove'),
        destructive: true,
        onPrimary: () => Navigator.of(context).pop(true),
        children: (_) => const [],
      ),
    );
    if (remove != true || !mounted) return;
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
      widget.id,
      NamedPin.rawOf(device)..remove(pin.name),
    );
    if (saved.value case final s? when mounted) {
      setState(() => _warnings = s.warnings);
    }
  }

  Future<void> _more(Json device) async {
    final choice = await showPickerSheet<String>(
      context,
      title: '${device['name'] ?? widget.id}',
      sections: const [
        PickerSection([
          PickerItem(
            key: ValueKey('board-organize'),
            value: 'organize',
            icon: OmniIcons.edit,
            title: 'Name and room',
          ),
          PickerItem(
            key: ValueKey('board-usb'),
            value: 'usb',
            icon: OmniIcons.wifi,
            title: 'Wi-Fi and name, over USB',
            subtitle: 'Plug it into this phone',
          ),
          PickerItem(
            key: ValueKey('board-remove'),
            value: 'remove',
            icon: OmniIcons.delete,
            title: 'Remove this board',
          ),
        ]),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'organize':
        await showOrganizeSheet(context, device);
      case 'usb':
        await showUsbBoardSheet(context, node: device['stableId'] as String?);
      case 'remove':
        await _remove(device);
    }
  }

  Future<void> _remove(Json device) async {
    final ok = await confirm(
      context,
      title: 'Remove ${device['name'] ?? widget.id}?',
      body:
          'Automations that use its pins stop working until it is added '
          'again. The board itself keeps its Wi-Fi and pins.',
      action: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final devices = ref.read(devicesProvider.notifier);
    final navigator = Navigator.of(context);
    final reply = await ref.read(engineApiProvider).removeDevice(widget.id);
    if (!reply.ok) return;
    await devices.refresh();
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);
    final device = _device;
    if (device == null) {
      return DetailPage(
        title: 'Board',
        state: OmniLoad.of(
          devices,
          isEmpty: (_) => true,
          onRetry: () => ref.invalidate(devicesProvider),
          error: 'The devices did not load.',
        ),
        notFound: const OmniEmptyState(
          icon: OmniIcons.board,
          title: 'This board is not here any more',
          message: 'It may have been removed.',
        ),
        children: (_) => const [],
      );
    }
    final info = _info?.value;
    final failed = _info != null && !_info!.ok;
    final online = device['online'] != false && (info?.live ?? !failed);
    final pins = NamedPin.ofDevice(device);
    final state = DeviceView(device).state;
    return RefreshIndicator(
      onRefresh: _describe,
      child: DetailPage(
        key: const ValueKey('board-page'),
        title: '${device['name'] ?? widget.id}',
        actions: [
          OmniIconAction(
            key: const ValueKey('board-more'),
            icon: OmniIcons.more,
            label: 'More for this board',
            onPressed: () => _more(device),
          ),
        ],
        banners: [
          if (failed)
            OmniBanner.error(
              key: const ValueKey('board-offline'),
              'The board is not answering, so OmniFlow cannot read what it '
              'offers. Check it has power and is on the same Wi-Fi.',
              actionLabel: 'Try again',
              onAction: _describe,
            )
          else if (info != null && !info.live)
            OmniBanner.warning(
              key: const ValueKey('board-stale'),
              'The board is not answering. This is what it reported'
              '${info.seenAt == null ? '' : ' at ${timeOfDayText(ref.watch(hour12Provider), info.seenAt!)}'}.',
              actionLabel: 'Try again',
              onAction: _describe,
            ),
        ],
        hero: OmniHeroCard(
          key: const ValueKey('board-hero'),
          tone: online ? HeroTone.accent : HeroTone.problem,
          title:
              '${boardTypeLabel(info?.board)} · ${_info == null
                  ? 'reading'
                  : online
                  ? 'online'
                  : 'not answering'}',
          subtitle: [
            ?info?.node ?? device['stableId'] as String?,
            ?device['host'] as String?,
            if (info?.firmware != null) 'firmware ${info!.firmware}',
          ].join(' · '),
        ),
        children: (context) => [
          for (final w in _warnings)
            OmniBanner.warning(w, key: ValueKey('pin-warning-$w')),
          // With no pins the empty state carries the one Add button.
          OmniSectionHeader(
            'Pins',
            actionLabel: pins.isEmpty ? null : 'Add pin',
            onAction: pins.isEmpty ? null : _addPin,
          ),
          if (pins.isEmpty)
            OmniEmptyState(
              key: const ValueKey('pins-empty'),
              icon: OmniIcons.board,
              title: 'No pins yet',
              message:
                  'Add the button, relay or sensor you wired to it, and it '
                  'shows up here and in automations.',
              padding: const EdgeInsets.symmetric(vertical: OmniSpace.lg),
              action: OmniButton.ghost(
                label: 'Add a pin',
                icon: OmniIcons.add,
                onPressed: _addPin,
              ),
            )
          else
            for (final p in pins)
              OmniListRow(
                key: ValueKey('pin-${p.name}'),
                icon: p.role.icon,
                title: p.label,
                subtitle: p.description,
                value: p.valueIn(state),
                valueColor: p.valueIn(state) == '-'
                    ? OmniPalette.of(context).muted
                    : null,
                trailing: p.mode == 'out'
                    ? Semantics(
                        label: p.label,
                        child: Switch(
                          key: ValueKey('pin-switch-${p.name}'),
                          value: state[p.name] == true,
                          onChanged: (v) => ref.read(engineApiProvider).invoke(
                            widget.id,
                            p.name,
                            {'value': v},
                          ),
                        ),
                      )
                    : null,
                onTap: () => _pinSheet(device, p),
              ),
          if (info != null && info.periphTypes.isNotEmpty) ...[
            const OmniSectionHeader('Extras'),
            for (final type in _extraTypes(info))
              OmniListRow(
                key: ValueKey('extra-$type'),
                icon: BoardExtras.icon(type),
                title: BoardExtras.title(type),
                subtitle: _extraLine(info, type),
                chevron: true,
                onTap: () async {
                  final changed = await SheetTemplate.show<bool>(
                    context,
                    builder: (_) =>
                        ExtraSheet(boardId: widget.id, type: type, info: info),
                  );
                  if (changed == true && mounted) unawaited(_describe());
                },
              ),
          ],
        ],
      ),
    );
  }

  /// IR, RF, then one NFC reader row: the type set now, or the first the
  /// firmware knows.
  static List<String> _extraTypes(BoardInfo info) {
    final known = info.periphTypes;
    final nfcSet = info.periph
        .map((p) => p.type)
        .where((t) => t == BoardExtras.rc522 || t == BoardExtras.pn532)
        .firstOrNull;
    return [
      if (known.contains(BoardExtras.ir)) BoardExtras.ir,
      if (known.contains(BoardExtras.rf)) BoardExtras.rf,
      if (nfcSet != null)
        nfcSet
      else if (known.contains(BoardExtras.rc522))
        BoardExtras.rc522
      else if (known.contains(BoardExtras.pn532))
        BoardExtras.pn532,
    ];
  }

  static String _extraLine(BoardInfo info, String type) {
    final set = info.periph.where((p) => p.type == type).firstOrNull;
    final chip = BoardExtras.chip(type);
    if (set == null) {
      return [if (chip.isNotEmpty) chip, 'not set'].join(' · ');
    }
    final pins = set.pins.length == 1
        ? 'GPIO ${set.pins.values.single}'
        : set.pins.entries.map((e) => '${e.key} ${e.value}').join(', ');
    return [if (chip.isNotEmpty) chip, pins, BoardExtras.job(type)].join(' · ');
  }
}
