import '../devices/device.dart';
import 'things_runtime.dart' show personDriverId, placeDriverId;

/// What a person's `presence` reads when nothing can tell whether they are
/// home: no place has a Wi-Fi network or a beacon, and nothing has said
/// so by hand.
const presenceNotSetUp = 'not_set_up';

/// Whether anything can tell if [person] is home: a place with a Wi-Fi
/// network or a beacon, or a reading that already decided (`homeSource`).
bool presenceDetectable(Device person, Iterable<Device> devices) {
  if (person.state['homeSource'] != null) return true;
  for (final d in devices) {
    if (d.driverId != placeDriverId) continue;
    final wifi = d.settings['wifi'];
    if (wifi is Map && (wifi['ssids'] as List? ?? const []).isNotEmpty) {
      return true;
    }
    final ble = d.settings['ble'];
    if (ble is Map && ble.isNotEmpty) return true;
    if (ble is String && ble.isNotEmpty) return true;
  }
  return false;
}

/// A device row as `device.list` and `device.get` give it, with a person
/// nothing can detect read as `home: null` and `presence: not_set_up`, so
/// the app, the CLI and an agent never read "away" for someone no reading
/// has placed. The stored state, which automations read, is left as it is.
Map<String, Object?> withPresence(
  Map<String, Object?> row,
  Device device,
  Iterable<Device> devices,
) {
  if (device.driverId != personDriverId) return row;
  if (presenceDetectable(device, devices)) return row;
  final state = row['state'];
  return {
    ...row,
    'state': {
      if (state is Map) ...Map<String, Object?>.from(state),
      'home': null,
      'presence': presenceNotSetUp,
    },
  };
}
