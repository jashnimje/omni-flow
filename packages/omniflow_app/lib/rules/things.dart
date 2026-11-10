import '../api/engine_calls.dart' show Json;

/// What a rule can name, read from `device.list` with capabilities: every
/// device, and the phone, people, places and tags, which the engine lists
/// the same way.
class Thing {
  Thing(this.json);

  final Json json;

  String get id => '${json['id']}';
  String get name => '${json['name'] ?? id}';
  String get driver => '${json['driver'] ?? ''}';
  bool get isBoard => json['board'] == true;

  /// Phone, People, Places, Tags or Devices, for grouping in a picker.
  String get group => switch (driver) {
    'phone' => 'Phone',
    'person' => 'People',
    'place' => 'Places',
    'nfc_tag' => 'Tags',
    _ => 'Devices',
  };

  List<Json> get capabilities => [
    for (final c in (json['capabilities'] as List? ?? const []))
      Map<String, Object?>.from(c as Map),
  ];

  Json get state => Map<String, Object?>.from(json['state'] as Map? ?? {});

  /// The state keys a capability reads, then any other key the thing
  /// reports now, each with a label.
  List<({String key, String label})> get stateKeys {
    final out = <({String key, String label})>[];
    final seen = <String>{};
    for (final c in capabilities) {
      final key = c['stateKey'];
      if (key is String && seen.add(key)) {
        out.add((key: key, label: '${c['label'] ?? key}'));
      }
    }
    for (final key in state.keys) {
      if (seen.add(key)) out.add((key: key, label: key));
    }
    return out;
  }

  /// The events the thing's driver declares. A board raises events its
  /// firmware names, so it also takes a typed event.
  List<({String key, String label})> get events => [
    for (final c in capabilities)
      if (c['type'] == 'event') (key: '${c['id']}', label: '${c['label']}'),
  ];

  /// The capabilities a step can run: everything that takes a command.
  List<Json> get actions => [
    for (final c in capabilities)
      if (c['type'] != 'sensor' && c['type'] != 'event') c,
  ];

  /// The on/off capabilities a toggle step can flip.
  List<Json> get toggles => [
    for (final c in capabilities)
      if (c['type'] == 'toggle' && c['stateKey'] != null) c,
  ];

  /// True for a thing turned on and off by its wake and sleep actions (a
  /// TV), which a template takes as `id.power`.
  bool get wakesAndSleeps => [
    'wake',
    'sleep',
    'power',
  ].every((id) => capability(id)?['type'] == 'action');

  Json? capability(String id) =>
      capabilities.where((c) => c['id'] == id).firstOrNull;

  String labelOf(String key) =>
      [...stateKeys, ...events].where((k) => k.key == key).firstOrNull?.label ??
      capability(key)?['label'] as String? ??
      key;
}

/// The things in a device.list result, phone first, then people, places,
/// tags and devices.
List<Thing> thingsOf(List<Json> devices) {
  const order = ['Phone', 'People', 'Places', 'Tags', 'Devices'];
  final things = [for (final d in devices) Thing(d)];
  things.sort((a, b) {
    final g = order.indexOf(a.group).compareTo(order.indexOf(b.group));
    return g != 0 ? g : a.name.compareTo(b.name);
  });
  return things;
}

/// How a `thing.key` reads to a person: `Desk lamp Power`.
String describeRef(List<Thing> things, String thing, String key) {
  final t = things.where((t) => t.id == thing).firstOrNull;
  return t == null ? '$thing.$key' : '${t.name} ${t.labelOf(key)}';
}
