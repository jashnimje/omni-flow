import 'package:flutter/material.dart';

import '../design/design.dart';
import 'room_field.dart';

/// Asks for a name and, with [withRoom], a room (by id). Null when the
/// user closes the sheet.
Future<({String name, String? room})?> askName(
  BuildContext context, {
  required String title,
  String name = '',
  String? room,
  bool withRoom = true,
}) => SheetTemplate.show<({String name, String? room})>(
  context,
  builder: (_) =>
      _NameSheet(title: title, name: name, room: room, withRoom: withRoom),
);

class _NameSheet extends StatefulWidget {
  const _NameSheet({
    required this.title,
    required this.name,
    required this.room,
    required this.withRoom,
  });

  final String title;
  final String name;
  final String? room;
  final bool withRoom;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final _name = ReplaceableText(widget.name);
  late var _room = widget.room ?? '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    return SheetTemplate(
      title: widget.title,
      primaryLabel: 'Add',
      primaryKey: const ValueKey('add-confirm'),
      missing: 'Give it a name first.',
      onPrimary: name.isEmpty
          ? null
          : () =>
                Navigator.of(context)
                    .pop((name: name, room: _room.isEmpty ? null : _room)),
      children: (context) => [
        TextField(
          key: const ValueKey('add-name'),
          controller: _name,
          onTap: _name.firstTap,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (_) => setState(() {}),
        ),
        if (widget.withRoom) ...[
          const SizedBox(height: OmniSpace.sm),
          RoomField(value: _room, onChanged: (r) => setState(() => _room = r)),
        ],
      ],
    );
  }
}
