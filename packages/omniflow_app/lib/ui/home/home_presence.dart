import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../devices/device_text.dart' show personOf;
import '../settings/places_page.dart' show zonesProvider;

/// What Home, Settings and Places say about where the person is.
enum PresenceShown {
  home,
  away,

  /// No place has Wi-Fi or a beacon and nobody said where they are, so
  /// nothing can tell. The engine's "not home" is only its starting value.
  notSetUp,

  /// Something can tell, but has not reported yet.
  unknown,
}

/// What to say about [presence], with [zones] the places that have a
/// Wi-Fi network or a beacon (null while they load). Null with no person.
PresenceShown? presenceShown(Presence? presence, List<Json>? zones) {
  if (presence == null) return null;
  if (presence.source == PresenceSource.unknown &&
      zones != null &&
      !zones.any(zoneDetects)) {
    return PresenceShown.notSetUp;
  }
  return switch (presence.home) {
    true => PresenceShown.home,
    false => PresenceShown.away,
    null => PresenceShown.unknown,
  };
}

/// Whether a place in `zone.list` can see someone arrive: a home Wi-Fi
/// network or a beacon.
bool zoneDetects(Json zone) {
  final wifi = zone['wifi'];
  final named = wifi is Map
      ? [...?(wifi['ssids'] as List?), ...?(wifi['bssids'] as List?)]
      : const [];
  return named.isNotEmpty || zone['ble'] is Map;
}

/// [presenceShown] for the household person in [devices].
PresenceShown? watchPresence(WidgetRef ref, List<DeviceView> devices) {
  final person = personOf(devices);
  return presenceShown(
    person == null ? null : Presence.of(person.json),
    ref.watch(zonesProvider).value,
  );
}

/// The words for a person that nothing detects.
const presenceNotSetUp = 'Presence not set up';
