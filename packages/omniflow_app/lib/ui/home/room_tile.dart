import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/house_calls.dart';
import '../../state/house_providers.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'home_screen.dart' show RoomDevicesPage;

/// One tile per room with lights, in a row: a tap opens the room, the icon
/// turns every light in it on or off, and a long press sets one
/// brightness for them all.
class RoomTileRow extends ConsumerWidget {
  const RoomTileRow({super.key});

  static const tileWidth = 156.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(roomLightsProvider).value ?? const <RoomLights>[];
    if (rooms.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OmniSectionHeader('Rooms'),
        SingleChildScrollView(
          key: const ValueKey('room-tiles'),
          scrollDirection: Axis.horizontal,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, room) in rooms.indexed) ...[
                  if (i > 0) const SizedBox(width: OmniSpace.md),
                  SizedBox(
                    width: tileWidth,
                    child: RoomTile(room: room),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: OmniSpace.sm),
      ],
    );
  }
}

class RoomTile extends ConsumerWidget {
  const RoomTile({super.key, required this.room});

  final RoomLights room;

  Future<void> _send(WidgetRef ref, String capability, Json params) async {
    final r = await ref
        .read(houseApiProvider)
        .roomLights(room.id, capability, params);
    if (r['ok'] != true) {
      showMessage(errorMessage(r));
    } else if (r['results'] case final List results
        when results.any((e) => e is Map && e['ok'] != true)) {
      showMessage('Some lights in ${room.name} did not answer');
    }
    await ref.read(roomLightsProvider.notifier).refresh();
  }

  void _open(BuildContext context, WidgetRef ref) {
    final ids = [
      for (final d in ref.read(devicesProvider).value ?? const <Json>[])
        if (d['roomId'] == room.id) '${d['id']}',
    ];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoomDevicesPage(title: room.name, ids: ids),
      ),
    );
  }

  /// No light in the room answers, so the tile is the muted offline tile.
  bool get _offline => room.lights > 0 && room.offline >= room.lights;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OmniTile(
    key: ValueKey('room-tile-${room.id}'),
    icon: OmniIcons.light,
    wash: _offline ? null : OmniPalette.of(context).accent,
    offline: _offline,
    name: room.name,
    state: room.summary,
    on: room.anyOn,
    level: room.anyOn && room.brightness != null
        ? room.brightness! / 100
        : null,
    tapHint: 'Opens the room',
    onTap: () => _open(context, ref),
    iconKey: ValueKey('room-power-${room.id}'),
    iconLabel: _offline
        ? null
        : room.anyOn
        ? 'Turn the lights in ${room.name} off'
        : 'Turn the lights in ${room.name} on',
    onIconTap: _offline
        ? null
        : () => _send(ref, 'power', {'value': !room.anyOn}),
    onLongPress: _offline ? null : () => _brightness(context, ref),
  );

  Future<void> _brightness(BuildContext context, WidgetRef ref) =>
      SheetTemplate.show<void>(
        context,
        builder: (context) => SheetTemplate(
          title: '${room.name} lights',
          subtitle: 'One brightness for every light in the room.',
          children: (context) => [
            OmniLabelledSlider(
              key: ValueKey('room-brightness-${room.id}'),
              label: 'Brightness',
              value: (room.brightness ?? 100).toDouble(),
              min: 1,
              max: 100,
              step: 1,
              format: (v) => '${v.round()}%',
              onChangeEnd: (v) =>
                  _send(ref, 'brightness', {'value': v.round()}),
            ),
          ],
        ),
      );
}
