import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../add/room_field.dart';
import '../design/design.dart';
import 'add_pin_page.dart';
import 'board_extras.dart';
import 'board_pins.dart';

/// Whether [device] is an OmniFlow board, which gets the board page.
bool isBoardDevice(Json device) => device['board'] == true;

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
      'Saved. The board is offline, so it is set up when it is back: $error',
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
    final remove = await showOmniSheet<bool>(
      context,
      builder: (context) => OmniSheet(
        title: pin.label,
        subtitle: pin.description,
        children: [
          const SizedBox(height: OmniSpace.sm),
          OmniButton.danger(
            key: const ValueKey('pin-remove'),
            label: 'Remove this pin',
            icon: OmniIcons.delete,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
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
    final choice = await showOmniSheet<String>(
      context,
      builder: (context) => OmniSheet(
        title: '${device['name'] ?? widget.id}',
        children: [
          OmniListRow(
            key: const ValueKey('board-organize'),
            icon: OmniIcons.edit,
            title: 'Name and room',
            onTap: () => Navigator.of(context).pop('organize'),
          ),
          OmniListRow(
            key: const ValueKey('board-remove'),
            icon: OmniIcons.delete,
            iconForeground: OmniColors.bad,
            title: 'Remove this board',
            onTap: () => Navigator.of(context).pop('remove'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'organize':
        await showOrganizeSheet(context, device);
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
    final device = _device;
    if (device == null) {
      return OmniPage(
        title: 'Board',
        body: ref.watch(devicesProvider).isLoading
            ? const SizedBox.shrink()
            : const OmniEmptyState(
                icon: OmniIcons.board,
                title: 'This board is not here any more',
                message: 'It may have been removed.',
              ),
      );
    }
    final info = _info?.value;
    final failed = _info != null && !_info!.ok;
    final online = device['online'] != false && (info?.live ?? !failed);
    final pins = NamedPin.ofDevice(device);
    final state = DeviceView(device).state;
    return OmniPage(
      title: '${device['name'] ?? widget.id}',
      actions: [
        OmniIconAction(
          key: const ValueKey('board-more'),
          icon: OmniIcons.more,
          label: 'More for this board',
          onPressed: () => _more(device),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _describe,
        child: ListView(
          key: const ValueKey('board-page'),
          padding: const EdgeInsets.only(bottom: OmniSpace.xl),
          children: [
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
                '${info.seenAt == null ? '' : ' at ${_time(info.seenAt!)}'}.',
                actionLabel: 'Try again',
                onAction: _describe,
              ),
            OmniHeroCard(
              key: const ValueKey('board-hero'),
              tone: online ? HeroTone.accent : HeroTone.problem,
              title:
                  '${boardTypeLabel(info?.board)} · ${_info == null
                      ? 'reading'
                      : online
                      ? 'online'
                      : 'offline'}',
              subtitle: [
                ?info?.node ?? device['stableId'] as String?,
                ?device['host'] as String?,
                if (info?.firmware != null) 'firmware ${info!.firmware}',
              ].join(' · '),
            ),
            for (final w in _warnings)
              OmniBanner.warning(w, key: ValueKey('pin-warning-$w')),
            OmniSectionHeader(
              'Pins',
              actionLabel: 'Add pin',
              onAction: _addPin,
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
                  valueColor: p.valueIn(state) == '-' ? OmniColors.muted : null,
                  trailing: p.mode == 'out'
                      ? Semantics(
                          label: p.label,
                          child: Switch(
                            key: ValueKey('pin-switch-${p.name}'),
                            value: state[p.name] == true,
                            onChanged: (v) => ref
                                .read(engineApiProvider)
                                .invoke(widget.id, p.name, {'value': v}),
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
                    final changed = await showOmniSheet<bool>(
                      context,
                      builder: (_) => ExtraSheet(
                        boardId: widget.id,
                        type: type,
                        info: info,
                      ),
                    );
                    if (changed == true && mounted) unawaited(_describe());
                  },
                ),
            ],
          ],
        ),
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

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
