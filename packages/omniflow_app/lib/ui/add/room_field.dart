import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../home/home_data.dart' show roomsProvider;
import '../tv/tv_widgets.dart' show askText;

const _newRoom = '\u0000new';
const _noRoom = '';

/// The room picker of the add flow and the board and tag pages: the rooms
/// from `room.list`, "No room", and "New room", which makes one with
/// `room.save`. [value] and [onChanged] carry the room id, '' for none.
class RoomField extends ConsumerStatefulWidget {
  const RoomField({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  ConsumerState<RoomField> createState() => _RoomFieldState();
}

class _RoomFieldState extends ConsumerState<RoomField> {
  List<Room>? _rooms;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final rooms = await EngineApi(ref.read(engineClientProvider)).rooms();
    if (mounted) setState(() => _rooms = rooms.or(const []));
  }

  Future<void> _create() async {
    final name = await askText(
      context,
      title: 'New room',
      label: 'Room name',
      action: 'Add',
      validate: (t) => t.trim().isEmpty ? 'Enter a name' : null,
    );
    if (name == null || !mounted) return;
    final saved = await ref.read(engineApiProvider).saveRoom(name: name.trim());
    if (saved.value case final id?) {
      ref.invalidate(roomsProvider);
      await _load();
      widget.onChanged(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = _rooms ?? const <Room>[];
    final known = rooms.any((r) => r.id == widget.value);
    return KeyedSubtree(
      key: const ValueKey('room-field'),
      child: _dropdown(rooms, known),
    );
  }

  Widget _dropdown(List<Room> rooms, bool known) {
    final value = known ? widget.value : _noRoom;
    // A form field reads its value once, so a new room or a late room list
    // builds a fresh one.
    return DropdownButtonFormField<String>(
      key: ValueKey('room-$value-${rooms.length}'),
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Room'),
      items: [
        const DropdownMenuItem(value: _noRoom, child: Text('No room')),
        for (final r in rooms)
          DropdownMenuItem(value: r.id, child: Text(r.name)),
        const DropdownMenuItem(
          value: _newRoom,
          child: Row(
            children: [
              Icon(OmniIcons.add, size: 18, color: OmniColors.accent),
              SizedBox(width: OmniSpace.sm),
              Text('New room'),
            ],
          ),
        ),
      ],
      onChanged: (v) {
        if (v == _newRoom) {
          unawaited(_create());
        } else if (v != null) {
          widget.onChanged(v);
        }
      },
    );
  }
}

/// Renames a device and moves it to a room, through `device.organize`.
Future<void> showOrganizeSheet(BuildContext context, Json device) =>
    showOmniSheet<void>(
      context,
      builder: (_) => _OrganizeSheet(device: device),
    );

class _OrganizeSheet extends ConsumerStatefulWidget {
  const _OrganizeSheet({required this.device});

  final Json device;

  @override
  ConsumerState<_OrganizeSheet> createState() => _OrganizeSheetState();
}

class _OrganizeSheetState extends ConsumerState<_OrganizeSheet> {
  late final _name = TextEditingController(
    text: '${widget.device['name'] ?? ''}',
  );
  late var _room = DeviceView(widget.device).roomId ?? '';
  var _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final devices = ref.read(devicesProvider.notifier);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final reply = await ref
        .read(engineApiProvider)
        .organizeDevice(
          '${widget.device['id']}',
          name: _name.text.trim(),
          room: _room,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!reply.ok) return;
    await devices.refresh();
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) => OmniSheet(
    title: 'Name and room',
    children: [
      TextField(
        key: const ValueKey('organize-name'),
        controller: _name,
        decoration: const InputDecoration(labelText: 'Name'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: OmniSpace.sm),
      RoomField(value: _room, onChanged: (r) => setState(() => _room = r)),
      const SizedBox(height: OmniSpace.md),
      OmniButton(
        key: const ValueKey('organize-save'),
        label: 'Save',
        onPressed: _saving || _name.text.trim().isEmpty ? null : _save,
      ),
    ],
  );
}
