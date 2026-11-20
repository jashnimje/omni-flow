import 'engine_calls.dart' show Json;
import 'engine_client.dart';

/// Every call about houses (docs/design/houses-design.md), and the commands that
/// take the house in view.
abstract final class HousesCalls {
  static const list = 'house.list';
  static const add = 'house.add';
  static const rename = 'house.rename';
  static const remove = 'house.remove';

  /// The house a call is about, and the field every item carries.
  static const houseArg = 'house';

  /// A person reached a place of a house: `{person, house, name}`.
  static const arrivedEvent = 'house.arrived';

  /// A house was added, renamed or removed: `{houses, removed?}`.
  static const changedEvent = 'house.changed';

  /// Commands that list, create or save, or read or set a per-house
  /// setting. Each gets the house in view when it names none.
  static const scoped = {
    // Lists, search and suggestions.
    'device.list',
    'device.discover',
    'flow.list',
    'automation.list',
    'automation.templates',
    'automation.diagram',
    'scene.list',
    'room.list',
    'room.state',
    'link.list',
    'link.options',
    'var.list',
    'zone.list',
    'tag.list',
    'timer.list',
    'suggest.list',
    'command.interpret',
    'rule.parse',
    'rule.tokens',
    'rule.words',
    'energy.summary',
    'home.stats',
    // Things made or saved go into the house in view.
    'device.add',
    'thing.add',
    'wiz.import',
    'android.pair',
    'board.setup',
    'link.create',
    'flow.save',
    'automation.save',
    'scene.save',
    'scene.capture',
    'room.save',
    'room.order',
    'room.invoke',
    'var.set',
    'var.remove',
    'zone.save',
    'tag.save',
    'timer.start',
    'timer.cancel',
    'timer.pause',
    'timer.resume',
    // This house's settings.
    'home.location',
    'home.location.set',
    'home.mode',
    'home.mode.set',
    'sunlight.get',
    'sunlight.set',
    'sunlight.apply',
    'awaylight.get',
    'awaylight.set',
    'awaylight.preview',
    'energy.price',
    'energy.price.set',
    'alerts.get',
    'alerts.set',
    'weather.add',
    'weather.refresh',
  };

  /// [args] with [house] added when [command] takes a house and neither
  /// the args nor the item they carry (a rule, a zone, a scene) already
  /// names one: an item keeps the house it belongs to.
  static Json withHouse(String command, Json args, String house) {
    if (!scoped.contains(command) || _namesHouse(args)) return args;
    return {...args, houseArg: house};
  }

  static bool _namesHouse(Json args) {
    if (args[houseArg] is String) return true;
    for (final v in args.values) {
      if (v is Map && v[houseArg] is String) return true;
    }
    return false;
  }
}

/// One house, as `house.list` gives it.
class House {
  const House({required this.id, required this.name});

  factory House.fromJson(Json j) =>
      House(id: '${j['id']}', name: '${j['name'] ?? j['id']}');

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is House && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

List<House> housesOf(Json reply) => [
  for (final h in (reply['houses'] as List? ?? const []))
    if (h is Map && h['id'] is String)
      House.fromJson(Map<String, Object?>.from(h)),
];

/// The house calls, on the engine's own connection (not scoped to a
/// house). Each returns the engine's reply as it came.
class HousesApi {
  const HousesApi(this._client);

  final EngineClient _client;

  Future<Json> list() => _client.call(HousesCalls.list);

  Future<Json> add(String name) =>
      _client.call(HousesCalls.add, {'name': name});

  Future<Json> rename(String house, String name) =>
      _client.call(HousesCalls.rename, {'id': house, 'name': name});

  Future<Json> remove(String house) =>
      _client.call(HousesCalls.remove, {'id': house});
}

/// The engine as the app sees it: every call that lists, creates or saves
/// is about the house in view, added here once so no screen passes it.
/// [house] is null when the engine has no houses (an older engine); calls
/// then go as they are. While the house in view is still being read,
/// [pending] gives it, and calls wait for it.
class HouseScopedClient implements EngineClient {
  HouseScopedClient(this.inner, {this.house, this.pending});

  final EngineClient inner;
  final String? house;
  final Future<String?>? pending;

  @override
  Future<Json> call(String command, [Json args = const {}]) async {
    // A call about no house (a device, a scene run) never waits.
    if (!HousesCalls.scoped.contains(command)) {
      return inner.call(command, args);
    }
    final id = house ?? await pending;
    return inner.call(
      command,
      id == null ? args : HousesCalls.withHouse(command, args, id),
    );
  }

  @override
  Stream<Json> get events => inner.events;

  /// The same connection and house: nothing that reads the engine has to
  /// load again. A client still waiting for the house and one that knows
  /// there is none read the same, so they count as equal.
  @override
  bool operator ==(Object other) =>
      other is HouseScopedClient &&
      identical(other.inner, inner) &&
      other.house == house;

  @override
  int get hashCode => Object.hash(identityHashCode(inner), house);
}
