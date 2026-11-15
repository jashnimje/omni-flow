import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/house_calls.dart';
import '../ui/home/home_data.dart' show roomsProvider;
import 'providers.dart';

final houseApiProvider = Provider<HouseApi>(
  (ref) => HouseApi(ref.watch(engineClientProvider)),
);

/// The house mode, reloaded when it changes. Null when the engine has
/// none.
class HouseModeNotifier extends AsyncNotifier<HouseModes?> {
  @override
  Future<HouseModes?> build() async {
    final client = ref.watch(engineClientProvider);
    final sub = client.events
        .where((e) => e['event'] == HouseCalls.modeChanged)
        .listen((_) => refresh());
    ref.onDispose(sub.cancel);
    return _load();
  }

  Future<HouseModes?> _load() async {
    final r = await ref.read(houseApiProvider).modes();
    return r['ok'] == true ? HouseModes.fromJson(r) : null;
  }

  Future<void> refresh() async {
    final next = await _load();
    if (ref.mounted) state = AsyncData(next);
  }
}

final houseModeProvider = AsyncNotifierProvider<HouseModeNotifier, HouseModes?>(
  HouseModeNotifier.new,
);

/// The running and paused timers. Every change comes with the whole list.
class TimersNotifier extends AsyncNotifier<List<HouseTimer>> {
  @override
  Future<List<HouseTimer>> build() async {
    final client = ref.watch(engineClientProvider);
    final sub = client.events
        .where((e) => e['event'] == HouseCalls.timersChanged)
        .listen((e) => state = AsyncData(timersOf(e['timers'])));
    ref.onDispose(sub.cancel);
    final r = await ref.read(houseApiProvider).timers();
    return r['ok'] == true ? timersOf(r['timers']) : const [];
  }
}

final timersProvider = AsyncNotifierProvider<TimersNotifier, List<HouseTimer>>(
  TimersNotifier.new,
);

/// Each room that has lights, with how they are. It reads again when a
/// device's state changes, at most once per [settle].
class RoomLightsNotifier extends AsyncNotifier<List<RoomLights>> {
  static const settle = Duration(milliseconds: 400);
  Timer? _reload;

  @override
  Future<List<RoomLights>> build() async {
    final rooms = await ref.watch(roomsProvider.future);
    final sub = ref
        .watch(engineClientProvider)
        .events
        .where((e) => e['event'] == 'device.stateChanged')
        .listen(
          (_) => _reload ??= Timer(settle, () {
            _reload = null;
            refresh();
          }),
        );
    ref.onDispose(() {
      sub.cancel();
      _reload?.cancel();
    });
    return _load([for (final r in rooms) r.id]);
  }

  late List<String> _ids;

  Future<List<RoomLights>> _load(List<String> ids) async {
    _ids = ids;
    final api = ref.read(houseApiProvider);
    final out = <RoomLights>[];
    for (final id in ids) {
      final r = await api.roomState(id);
      if (r['ok'] != true) continue;
      final room = RoomLights.fromJson(r);
      if (room != null && room.lights > 0) out.add(room);
    }
    return out;
  }

  Future<void> refresh() async {
    final next = await _load(_ids);
    if (ref.mounted) state = AsyncData(next);
  }
}

final roomLightsProvider =
    AsyncNotifierProvider<RoomLightsNotifier, List<RoomLights>>(
      RoomLightsNotifier.new,
    );

/// The built-in alerts.
final houseAlertsProvider = FutureProvider<HouseAlerts>((ref) async {
  final r = await ref.watch(houseApiProvider).alerts();
  return HouseAlerts.fromJson(r);
});
