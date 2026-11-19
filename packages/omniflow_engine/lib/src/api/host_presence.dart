import 'dart:async';

import 'engine_core.dart';
import 'presence_view.dart' show housePresence, presenceNotSetUp;
import 'rules_core_commands.dart' show RulesCoreCommands;
import 'things_runtime.dart'
    show defaultPhoneId, personDriverId, phoneDriverId, placeDriverId;
import '../devices/device.dart';
import '../storage/database.dart';

/// Whether the phone this engine runs on is away from a house. A phone that
/// left home has left its Wi-Fi too, so every device there stops answering
/// at once. That is the phone being out, not the devices failing, so the
/// answering alerts and the "stopped answering" history wait until it is
/// back.
///
/// The household person's presence for the house says it when a place of
/// that house can tell. Otherwise the phone's last Wi-Fi reading does: off
/// every network of the house's places (and, for the first house, of
/// `$HomeSsids`) is away. With neither, nothing is known and the phone
/// counts as there. An engine on a computer (a hub) stays where it is, so
/// it is never away.
class HostPresence {
  HostPresence(
    this._core, {
    required this._householdPerson,
    bool Function()? onPhone,
  }) : _onPhone = onPhone ?? (() => RulesCoreCommands.onPhone());

  final EngineCore _core;
  final Future<String?> Function() _householdPerson;
  final bool Function() _onPhone;

  /// The people, places and phones, as last read.
  var _devices = const <Device>[];
  String? _person;
  StreamSubscription<Map<String, Object?>>? _sub;
  Future<void> _reading = Future.value();

  static const _drivers = {personDriverId, placeDriverId, phoneDriverId};

  /// The events after which where the phone is may have changed.
  static const _moves = {
    'zone.changed',
    'wifi.changed',
    'house.changed',
    'house.thingMoved',
    'device.changed',
  };

  Future<void> open() async {
    await refresh();
    _sub = _core.events.listen(_observe);
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _observe(Map<String, Object?> e) {
    final event = e['event'];
    final device = e['device'];
    if (_moves.contains(event) ||
        (event == 'device.stateChanged' &&
            device is Map &&
            _drivers.contains(device['driver']))) {
      _core.track(refresh());
    }
  }

  /// Reads the people, places and phones again, one read after another.
  Future<void> refresh() => _reading = _reading.then((_) async {
    final all = await DriftDeviceStore(_core.db).all();
    _devices = [
      for (final d in all)
        if (_drivers.contains(d.driverId)) d,
    ];
    _person = await _householdPerson();
  });

  /// Whether this engine's phone is away from [house].
  bool awayFrom(String house) {
    if (!_onPhone()) return false;
    final person = _devices
        .where((d) => d.id == _person && d.driverId == personDriverId)
        .firstOrNull;
    if (person != null) {
      final presence = housePresence(person, _devices, _core.houses, house);
      if (presence != presenceNotSetUp) return presence == 'away';
    }
    return _offWifiOf(house);
  }

  /// Whether the phone's last Wi-Fi reading is none of [house]'s networks.
  /// False when the phone never said, or the house has no network to
  /// compare with.
  bool _offWifiOf(String house) {
    final phone = _devices.where((d) => d.id == defaultPhoneId).firstOrNull;
    if (phone == null || !phone.state.containsKey('wifi_ssid')) return false;
    final ssid = phone.state['wifi_ssid'];
    final bssid = phone.state['wifi_bssid'];
    final ssids = <String>{};
    final bssids = <String>{};
    for (final place in _devices) {
      if (place.driverId != placeDriverId ||
          (_core.houses.thingHouses[place.id] ?? _core.houses.defaultId) !=
              house) {
        continue;
      }
      final wifi = place.settings['wifi'];
      if (wifi is! Map) continue;
      ssids.addAll((wifi['ssids'] as List? ?? const []).map((s) => '$s'));
      bssids.addAll(
        (wifi['bssids'] as List? ?? const []).map((b) => '$b'.toLowerCase()),
      );
    }
    if (house == _core.houses.defaultId) {
      final homes = _core.flows.globals['HomeSsids'];
      if (homes is List) ssids.addAll(homes.map((s) => '$s'));
    }
    if (ssids.isEmpty && bssids.isEmpty) return false;
    return !((ssid is String && ssids.contains(ssid)) ||
        (bssid is String && bssids.contains(bssid.toLowerCase())));
  }
}
