import '../devices/device.dart';
import 'houses.dart';
import 'things_runtime.dart' show personDriverId, placeDriverId;

/// What a person's `presence` reads when nothing can tell whether they are
/// home: no place has a Wi-Fi network or a beacon, and nothing has said
/// so by hand.
const presenceNotSetUp = 'not_set_up';

/// Whether anything can tell if [person] is home: a place with a Wi-Fi
/// network or a beacon, or a reading that already decided (`homeSource`).
bool presenceDetectable(Device person, Iterable<Device> devices) {
  if (person.state['homeSource'] != null) return true;
  return devices.any(placeDetects);
}

/// Whether the place [d] can see someone arrive: a Wi-Fi network or a
/// beacon. False for anything that is not a place.
bool placeDetects(Device d) {
  if (d.driverId != placeDriverId) return false;
  final wifi = d.settings['wifi'];
  if (wifi is Map && (wifi['ssids'] as List? ?? const []).isNotEmpty) {
    return true;
  }
  final ble = d.settings['ble'];
  if (ble is Map && ble.isNotEmpty) return true;
  return ble is String && ble.isNotEmpty;
}

/// Whether anything can tell if [person] is at [house]: a place of that
/// house with a Wi-Fi network or a beacon. In the house of the person's
/// home place a reading that already decided counts too (saying "I am
/// home" by hand), as before houses. A place with no house yet belongs to
/// the first house.
bool presenceDetectableIn(
  Device person,
  Iterable<Device> devices,
  Houses houses,
  String house,
) {
  if (houses.homeHouseOf(person) == house &&
      person.state['homeSource'] != null) {
    return true;
  }
  return devices.any(
    (d) =>
        placeDetects(d) &&
        (houses.thingHouses[d.id] ?? houses.defaultId) == house,
  );
}

/// Where [person] is for [house]: `home` when at one of its places (in the
/// house of their home place, when their home place sees them), `away`,
/// or [presenceNotSetUp] when no place of that house can tell.
String housePresence(
  Device person,
  Iterable<Device> devices,
  Houses houses,
  String house,
) {
  if (!presenceDetectableIn(person, devices, houses, house)) {
    return presenceNotSetUp;
  }
  return houses.personIn(person, house) ? 'home' : 'away';
}

/// A device row as `device.list` and `device.get` give it. A person reads
/// for [house] (the house in view, else the house of their home place):
/// `home` is whether they are at that house, `presence` says `home`,
/// `away` or [presenceNotSetUp], and a house no place of which can tell
/// reads `home: null` with no source, so the app, the CLI and an agent
/// never read "home" or "away" for a house no reading has placed them in.
/// The stored state, which automations read, is left as it is.
Map<String, Object?> withPresence(
  Map<String, Object?> row,
  Device device,
  Iterable<Device> devices, {
  Houses? houses,
  String? house,
}) {
  if (device.driverId != personDriverId) return row;
  final raw = row['state'];
  final state = <String, Object?>{
    if (raw is Map) ...Map<String, Object?>.from(raw),
  };
  if (houses == null) {
    if (presenceDetectable(device, devices)) return row;
    return {
      ...row,
      'state': {...state, 'home': null, 'presence': presenceNotSetUp},
    };
  }
  final shown = house ?? houses.homeHouseOf(device);
  final presence = housePresence(device, devices, houses, shown);
  final ownHome = houses.homeHouseOf(device) == shown;
  // The house of their home place reads the stored state, as before.
  if (ownHome && presence != presenceNotSetUp) return row;
  return {
    ...row,
    'state': {
      ...state,
      'presence': presence,
      'presenceHouse': shown,
      if (presence == presenceNotSetUp) ...{
        'home': null,
        'homeSource': null,
        'homeSince': null,
      } else ...{
        'home': presence == 'home',
        // Since when is about the home place, so another house says none.
        if (!ownHome) 'homeSince': null,
      },
    },
  };
}
