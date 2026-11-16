import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../automations/automations_state.dart';

/// The lists Home, Devices and Settings read besides the live devices.
/// Each is a plain engine read; screens invalidate the one they change.

/// Every driver by id, for a device's driver name and category.
final driversProvider = FutureProvider<Map<String, Json>>((ref) async {
  final reply = await ref.watch(engineApiProvider).drivers();
  return {for (final d in reply.or(const [])) '${d['id']}': d};
});

/// The rooms in their order.
final roomsProvider = FutureProvider<List<Room>>((ref) async {
  // A device added or moved in from the CLI or an agent can bring a room.
  ref.watch(deviceChangesProvider);
  return (await ref.watch(engineApiProvider).rooms()).or(const []);
});

/// The scenes, reloaded whenever the automations list is, so a scene
/// changed in Scenes shows on Home.
final scenesProvider = FutureProvider<List<Scene>>((ref) async {
  ref.watch(automationsProvider);
  return (await ref.watch(engineApiProvider).scenes()).or(const []);
});

/// Every automation as automation.list words it: the Automations tab's
/// list, so both reload together.
final summariesProvider = Provider<AsyncValue<List<AutomationSummary>>>(
  (ref) => ref.watch(automationsProvider),
);

/// The automations that use one device, for its page.
final usedInProvider = FutureProvider.family<List<AutomationSummary>, String>((
  ref,
  id,
) async {
  ref.watch(automationsProvider);
  return (await ref.watch(engineApiProvider).automations(device: id))
      .or(const []);
});

/// Whether the first-run screen was finished on this phone.
abstract interface class FirstRunStore {
  Future<bool> done();
  Future<void> markDone();
}

/// Kept in the app's shared preferences through flutter_foreground_task.
/// Where they cannot be read (tests, a broken store) the first run counts
/// as done, so the app never stays stuck on it.
class PrefsFirstRunStore implements FirstRunStore {
  const PrefsFirstRunStore();

  static const _key = 'first_run_done';

  @override
  Future<bool> done() async {
    try {
      return await FlutterForegroundTask.getData<bool>(key: _key) ?? false;
    } on Object {
      return true;
    }
  }

  @override
  Future<void> markDone() async {
    try {
      await FlutterForegroundTask.saveData(key: _key, value: true);
    } on Object {
      return;
    }
  }
}

final firstRunStoreProvider = Provider<FirstRunStore>(
  (ref) => const PrefsFirstRunStore(),
);

final firstRunDoneProvider = FutureProvider<bool>(
  (ref) => ref.watch(firstRunStoreProvider).done(),
);
