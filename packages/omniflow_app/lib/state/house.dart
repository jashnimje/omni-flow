import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show thingIdFor;
import 'package:path_provider/path_provider.dart';

import '../api/engine_calls.dart' show EngineCalls, Json;
import '../api/engine_client.dart';
import '../api/houses_calls.dart';
import '../ui/settings/shake_scene.dart' show thisPhoneIdProvider;
import 'clock.dart';
import 'providers.dart';

export '../api/houses_calls.dart' show House;

/// Which house this phone shows, kept on this phone only: another phone or
/// a CLI can look at another house.
abstract interface class HouseViewStore {
  Future<String?> read();
  Future<void> write(String house);
}

/// A small JSON file next to the app's own data. Where it cannot be read
/// (tests, a first launch) the first house is shown.
class FileHouseViewStore implements HouseViewStore {
  const FileHouseViewStore();

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/house_view.json');

  @override
  Future<String?> read() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      return json is Map && json['house'] is String
          ? json['house'] as String
          : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String house) async {
    try {
      await (await _file()).writeAsString(jsonEncode({'house': house}));
    } on Object {
      // Kept for this session only: the next launch shows the first house.
    }
  }
}

/// Holds the choice in memory, for tests.
class MemoryHouseViewStore implements HouseViewStore {
  MemoryHouseViewStore([this.saved]);

  String? saved;

  @override
  Future<String?> read() async => saved;

  @override
  Future<void> write(String house) async => saved = house;
}

final houseViewStoreProvider = Provider<HouseViewStore>(
  (ref) => const FileHouseViewStore(),
);

final housesApiProvider = Provider<HousesApi>(
  (ref) => HousesApi(ref.watch(engineConnectionProvider)),
);

/// Every house, read again when one is added, renamed or removed. Empty
/// when the engine has no houses (an older engine) or did not answer.
class HousesNotifier extends AsyncNotifier<List<House>> {
  @override
  Future<List<House>> build() async {
    final client = ref.watch(engineConnectionProvider);
    final sub = client.events
        .where((e) => e['event'] == HousesCalls.changedEvent)
        .listen((_) => refresh());
    ref.onDispose(sub.cancel);
    return _load();
  }

  Future<List<House>> _load() async {
    try {
      final r = await ref.read(housesApiProvider).list();
      return r['ok'] == true ? housesOf(r) : const [];
    } on Object {
      return const [];
    }
  }

  Future<void> refresh() async {
    final next = await _load();
    if (ref.mounted) state = AsyncData(next);
  }
}

final housesProvider = AsyncNotifierProvider<HousesNotifier, List<House>>(
  HousesNotifier.new,
);

/// The house this phone shows: the one chosen here last, else the first.
/// It switches by itself when this phone's person arrives at a house, and
/// a switch by hand stays until the next arrival.
class HouseInViewNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final client = ref.watch(engineConnectionProvider);
    final sub = client.events
        .where((e) => e['event'] == HousesCalls.arrivedEvent)
        .listen(_onArrived);
    ref.onDispose(sub.cancel);
    // Again when a house is added, renamed or removed: the one shown may
    // be gone.
    final List<House> houses =
        ref.watch(housesProvider.select((v) => v.value)) ??
        await ref.read(housesProvider.future);
    if (houses.isEmpty) return null;
    final stored = await ref.read(houseViewStoreProvider).read();
    // A choice made while this read was under way wins.
    return pickHouse(houses, ref.read(_chosenProvider) ?? stored);
  }

  /// Shows [house] and keeps it for the next launch.
  Future<void> show(String house) async {
    ref.read(_chosenProvider.notifier).set(house);
    state = AsyncData(house);
    await ref.read(houseViewStoreProvider).write(house);
  }

  Future<void> _onArrived(Json e) async {
    final house = e['house'];
    if (house is! String) return;
    final person = e['person'];
    final mine = await _thisPhonesPerson();
    if (!ref.mounted || (mine != null && person != mine)) return;
    final before = state.value;
    if (before == house) return;
    final houses = await ref.read(housesProvider.future);
    final arrived = houses.where((h) => h.id == house).firstOrNull;
    if (arrived == null || !ref.mounted) return;
    await show(house);
    showMessage(
      'Now showing ${arrived.name}',
      action: before == null ? null : 'Undo',
      onAction: before == null ? null : () => unawaited(show(before)),
    );
  }

  /// The person this phone belongs to: the phone thing's person, else the
  /// only person there is. Null when that cannot be told, and then any
  /// arrival counts.
  Future<String?> _thisPhonesPerson() async {
    final client = ref.read(engineConnectionProvider);
    try {
      final id = await ref
          .read(thisPhoneIdProvider.future)
          .then((id) => id, onError: (Object _) => 'phone');
      final phone = await client.call(EngineCalls.deviceGet, {'id': id});
      final settings = (phone['device'] as Map?)?['settings'];
      final person = settings is Map ? settings['person'] : null;
      if (person is String && person.isNotEmpty) return person;
      final list = await client.call(EngineCalls.deviceList);
      final people = [
        for (final d in (list['devices'] as List? ?? const []))
          if (d is Map && d['driver'] == 'person') '${d['id']}',
      ];
      return people.length == 1 ? people.single : null;
    } on Object {
      return null;
    }
  }
}

/// The house chosen in this session, by hand or by arriving, so a read of
/// the houses that was already under way cannot undo it.
class _Chosen extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String house) => state = house;
}

final _chosenProvider = NotifierProvider<_Chosen, String?>(_Chosen.new);

final houseInViewProvider = AsyncNotifierProvider<HouseInViewNotifier, String?>(
  HouseInViewNotifier.new,
);

/// The house in view, or null while it loads or with no houses.
final houseShownProvider = Provider<House?>((ref) {
  final id = ref.watch(houseInViewProvider).value;
  final houses = ref.watch(housesProvider).value ?? const <House>[];
  return houses.where((h) => h.id == id).firstOrNull;
});

/// The house to show: [saved] while it exists, else the first. Null with
/// no houses.
String? pickHouse(List<House> houses, String? saved) {
  if (houses.isEmpty) return null;
  return houses.any((h) => h.id == saved) ? saved : houses.first.id;
}

/// How long a call waits for the house in view before going without one,
/// so a slow house list or saved choice never leaves a screen spinning.
const houseLookupLimit = Duration(seconds: 3);

Future<String?> _firstHouse(EngineClient raw, HouseViewStore store) async {
  try {
    final houses = housesOf(
      await HousesApi(raw).list().timeout(houseLookupLimit),
    );
    if (houses.isEmpty) return null;
    final saved = await store.read().timeout(
      houseLookupLimit,
      onTimeout: () => null,
    );
    return pickHouse(houses, saved);
  } on Object {
    return null;
  }
}

/// The place a house's Wi-Fi is first saved on: the house's own name, so
/// each house has its own. "Home" for an engine with no houses.
Json newHomePlace(House? house) {
  final name = house?.name ?? 'Home';
  return {'id': thingIdFor(name), 'name': name};
}

/// The engine scoped to the house in view, for [engineClientProvider].
/// Every call also carries this phone's clock setting where words hold a
/// time ([ClockClient]).
EngineClient scopedEngine(Ref ref) =>
    ClockClient(_houseScoped(ref), hour12: ref.watch(hour12Provider));

HouseScopedClient _houseScoped(Ref ref) {
  final raw = ref.watch(engineConnectionProvider);
  // Only the house itself: reading the list of houses again, or an engine
  // with no houses finishing its read, changes nothing for the screens.
  final (known, house) = ref.watch(
    houseInViewProvider.select((v) => (v.hasValue, v.value)),
  );
  // Once the house in view is known, even as none (an engine with no
  // houses), calls go straight through: no fresh lookup per rebuild.
  if (known) return HouseScopedClient(raw, house: house);
  // Calls made before the house in view is known wait for it, read here
  // on its own so they do not hang on the provider's lifecycle.
  return HouseScopedClient(
    raw,
    pending: _firstHouse(raw, ref.read(houseViewStoreProvider)),
  );
}
