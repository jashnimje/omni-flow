import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/device_sections.dart' show askRoomName;
import '../home/home_data.dart';

/// The rooms in their order: add, rename, drag to reorder, remove. Home
/// and Devices show rooms in this order.
class RoomsPage extends ConsumerWidget {
  const RoomsPage({super.key});

  Future<void> _reload(WidgetRef ref) async {
    ref.invalidate(roomsProvider);
    await ref.read(devicesProvider.notifier).refresh();
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final name = await askRoomName(context);
    if (name == null) return;
    final saved = await ref.read(engineApiProvider).saveRoom(name: name);
    if (saved.ok) await _reload(ref);
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Room r) async {
    final name = await askRoomName(context, initial: r.name);
    if (name == null || name == r.name) return;
    final saved = await ref
        .read(engineApiProvider)
        .saveRoom(id: r.id, name: name, order: r.order);
    if (saved.ok) await _reload(ref);
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, Room r) async {
    final ok = await confirm(
      context,
      title: 'Remove ${r.name}?',
      body: r.deviceCount == 0
          ? 'It has no devices.'
          : 'Its ${r.deviceCount} device${r.deviceCount == 1 ? '' : 's'} '
                'stay, in no room.',
      action: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    final removed = await ref.read(engineApiProvider).removeRoom(r.id);
    if (removed.ok) await _reload(ref);
  }

  Future<void> _reorder(
    WidgetRef ref,
    List<Room> rooms,
    int from,
    int to,
  ) async {
    final ids = [for (final r in rooms) r.id];
    final moved = ids.removeAt(from);
    ids.insert(to, moved);
    final done = await ref.read(engineApiProvider).orderRooms(ids);
    if (done.ok) await _reload(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(roomsProvider);
    final list = rooms.value ?? const <Room>[];
    return ListPage.custom(
      title: 'Rooms',
      actions: [
        OmniIconAction(
          key: const ValueKey('rooms-add'),
          icon: OmniIcons.add,
          label: 'Add a room',
          onPressed: () => _add(context, ref),
        ),
      ],
      state: OmniLoad.of(
        rooms,
        isEmpty: (r) => r.isEmpty,
        error: 'The rooms did not load.',
        onRetry: () => ref.invalidate(roomsProvider),
      ),
      empty: const OmniEmptyState(
        key: ValueKey('rooms-empty'),
        icon: OmniIcons.room,
        title: 'No rooms yet',
        message:
            'Rooms group your devices on Home and in Devices. Tap the plus '
            'at the top to add one.',
      ),
      body: (context, padding) => ReorderableListView(
        key: const ValueKey('rooms-list'),
        padding: padding,
        buildDefaultDragHandles: false,
        onReorderItem: (from, to) => _reorder(ref, list, from, to),
        children: [
          for (var i = 0; i < list.length; i++)
            OmniListRow(
              key: ValueKey('room-${list[i].id}'),
              leading: ReorderableDragStartListener(
                index: i,
                child: Padding(
                  padding: EdgeInsets.all(OmniSpace.md),
                  child: Icon(
                    OmniIcons.drag,
                    color: OmniPalette.of(context).muted,
                    semanticLabel: 'Drag to reorder',
                  ),
                ),
              ),
              title: list[i].name,
              subtitle:
                  '${list[i].deviceCount} device${list[i].deviceCount == 1 ? '' : 's'}',
              onTap: () => _rename(context, ref, list[i]),
              trailing: OmniIconAction(
                key: ValueKey('room-remove-${list[i].id}'),
                icon: OmniIcons.delete,
                label: 'Remove ${list[i].name}',
                onPressed: () => _remove(context, ref, list[i]),
              ),
            ),
        ],
      ),
    );
  }
}
