import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/automations/automations_state.dart';
import '../ui/home/home_data.dart';
import '../ui/settings/places_page.dart' show zonesProvider;
import 'providers.dart';

/// Reads everything about the home again after a change that touches more
/// than one list: a rename or a removal changes the sentences automations
/// show, and a restore changes every list. The engine sends events for
/// device state only.
Future<void> reloadHome(WidgetRef ref) async {
  ref
    ..invalidate(roomsProvider)
    ..invalidate(scenesProvider)
    ..invalidate(zonesProvider);
  await Future.wait([
    ref.read(devicesProvider.notifier).refresh(),
    ref.read(automationsProvider.notifier).refresh(),
  ]);
}
