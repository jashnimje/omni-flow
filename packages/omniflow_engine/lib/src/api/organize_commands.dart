import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../storage/database.dart';

final _roomId = RegExp(r'^[a-z][a-z0-9_]*$');

/// Rooms as their own list, and how each device is organized: its name,
/// room, favourite mark and place in its room.
class OrganizeCommands {
  OrganizeCommands(this._core);

  final EngineCore _core;

  DriftRoomStore get _rooms => DriftRoomStore(_core.db);

  Map<String, CommandHandler> get commands => {
    'room.list': list,
    'room.save': save,
    'room.remove': remove,
    'room.order': order,
    'device.organize': organize,
  };

  Future<Map<String, Object?>> list(Map<String, Object?> _) async {
    final counts = <String, int>{};
    for (final d in await DriftDeviceStore(_core.db).all()) {
      if (d.room != null) counts[d.room!] = (counts[d.room!] ?? 0) + 1;
    }
    return {
      'rooms': [
        for (final r in await _rooms.all())
          {
            'id': r.id,
            'name': r.name,
            'order': r.order,
            'deviceCount': counts[r.id] ?? 0,
          },
      ],
    };
  }

  /// `{id?, name, order?}`: renames or moves a room, or adds one. A new
  /// room with no id gets one from its name, and with no order goes last.
  Future<Map<String, Object?>> save(Map<String, Object?> args) async {
    final name = stringArg(args, 'name').trim();
    if (name.isEmpty) throw ApiError('invalid', 'name is required');
    final id = optStringArg(args, 'id');
    final order = optIntArg(args, 'order');
    final rooms = await _rooms.all();
    final existing = rooms.where((r) => r.id == id).firstOrNull;
    final same = rooms
        .where((r) => r.id != id && _sameName(r.name, name))
        .firstOrNull;
    if (same != null) {
      throw ApiError('exists', 'the room ${same.id} is called ${same.name}');
    }
    if (id != null && existing == null && !_roomId.hasMatch(id)) {
      throw ApiError('invalid', 'a room id is lower snake case, like study');
    }
    final room = Room(
      id: id ?? uniqueRoomId(name, {for (final r in rooms) r.id}),
      name: name,
      order: order ?? existing?.order ?? _nextOrder(rooms),
    );
    await _rooms.put(room);
    await _core.loadRooms();
    return {'room': await _roomJson(room)};
  }

  /// Removes a room. Its devices stay, with no room.
  Future<Map<String, Object?>> remove(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final moved = <String>[];
    for (final d in await DriftDeviceStore(_core.db).all()) {
      if (d.room != id) continue;
      await _core.devices.updateDevice(
        d.id,
        (old) => old.placed(room: null, order: old.order),
      );
      moved.add(d.id);
    }
    final removed = await _rooms.remove(id);
    await _core.loadRooms();
    return {'removed': removed, 'devices': moved};
  }

  /// `{ids}`: the rooms in this order first, the rest after them as they were.
  Future<Map<String, Object?>> order(Map<String, Object?> args) async {
    final ids = args['ids'];
    if (ids is! List || ids.any((i) => i is! String)) {
      throw ApiError('invalid', 'ids must be a list of room ids');
    }
    if (ids.toSet().length != ids.length) {
      throw ApiError('invalid', 'ids names a room twice');
    }
    final rooms = {for (final r in await _rooms.all()) r.id: r};
    final unknown = ids.where((i) => !rooms.containsKey(i)).toList();
    if (unknown.isNotEmpty) {
      throw ApiError('not_found', 'no room ${unknown.join(', ')}');
    }
    final ordered = [
      for (final id in ids.cast<String>()) rooms[id]!,
      for (final r in rooms.values)
        if (!ids.contains(r.id)) r,
    ];
    for (var i = 0; i < ordered.length; i++) {
      await _rooms.put(
        Room(id: ordered[i].id, name: ordered[i].name, order: i),
      );
    }
    await _core.loadRooms();
    return list(const {});
  }

  /// `{id, name?, room?, favourite?, order?}`: changes only the keys given.
  /// `room` is a room id or name, a new name adds the room, and null takes
  /// the device out of its room. `order: null` clears its place.
  Future<Map<String, Object?>> organize(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    await _core.device(id);
    final name = optStringArg(args, 'name')?.trim();
    if (name != null && name.isEmpty) {
      throw ApiError('invalid', 'name cannot be empty');
    }
    final favourite = args['favourite'];
    if (favourite != null && favourite is! bool) {
      throw ApiError('invalid', 'favourite must be true or false');
    }
    final order = optIntArg(args, 'order');
    final room = args.containsKey('room')
        ? await resolveRoom(_core, optStringArg(args, 'room'))
        : null;
    final updated = await _core.devices.updateDevice(
      id,
      (d) => d
          .copyWith(name: name, favourite: favourite as bool?)
          .placed(
            room: args.containsKey('room') ? room : d.room,
            order: args.containsKey('order') ? order : d.order,
          ),
    );
    return {'device': _core.deviceJson(updated)};
  }

  Future<Map<String, Object?>> _roomJson(Room r) async => {
    'id': r.id,
    'name': r.name,
    'order': r.order,
    'deviceCount': [
      for (final d in await DriftDeviceStore(_core.db).all())
        if (d.room == r.id) d,
    ].length,
  };
}

bool _sameName(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

int _nextOrder(List<Room> rooms) => rooms.isEmpty
    ? 0
    : rooms.map((r) => r.order).reduce((a, b) => a > b ? a : b) + 1;

/// The id of the room [value] names: a room id, or a room name (any case).
/// A name no room has adds that room last. Null or blank is no room.
Future<String?> resolveRoom(EngineCore core, String? value) async {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  final store = DriftRoomStore(core.db);
  final rooms = await store.all();
  final match =
      rooms.where((r) => r.id == text).firstOrNull ??
      rooms.where((r) => _sameName(r.name, text)).firstOrNull;
  if (match != null) return match.id;
  final room = Room(
    id: uniqueRoomId(text, {for (final r in rooms) r.id}),
    name: text,
    order: _nextOrder(rooms),
  );
  await store.put(room);
  await core.loadRooms();
  return room.id;
}
