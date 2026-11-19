import 'dart:async';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'houses.dart' show firstHouseId;
import 'mode_commands.dart' show HomeFile;
import '../devices/device.dart';
import '../storage/database.dart';

/// The built-in alerts: a device that has been offline for [offlineAfter]
/// (once, and once more when it is back), off until the user turns it on
/// in Settings, and a battery under [lowBattery] percent, on until the user
/// turns it off. They go out as `flow.announce` notifications, as a notify
/// step's do, with `alert` saying which.
///
/// Offline is only judged while the hub polls, counted from the later of
/// a device's last word and when polling started, so a stopped hub or a
/// long gap before a restart is not taken for devices going quiet. Nor is
/// it judged while the phone this engine runs on is away from the house
/// ([EngineCore.hostAwayFrom]): its devices are out of reach then, not
/// broken, and the count starts again once it is back. What was already
/// told is kept in `home.json`, so a restart does not tell it again, and
/// "answering again" goes only for a device told as not answering.
class HouseAlerts {
  HouseAlerts(
    this._core,
    this._file, {
    this.every = const Duration(minutes: 1),
    bool Function()? hubRunning,
    this.house = firstHouseId,
    this._hostAway,
  }) : _hubRunning = hubRunning ?? _always;

  final EngineCore _core;

  /// The house whose things these alerts watch. A thing every house shares
  /// (a phone) is the first house's to alert on, so it is told once.
  final String house;

  bool _owns(String id) {
    final h = _core.houses.thingHouses[id];
    return h == null ? house == _core.houses.defaultId : h == house;
  }

  final HomeFile _file;
  final bool Function() _hubRunning;
  final bool Function(String house)? _hostAway;

  bool get _away => (_hostAway ?? _core.hostAwayFrom)(house);

  static bool _always() => true;

  /// When the hub's polling was first seen running, or null while stopped.
  DateTime? _pollingSince;

  /// How often devices are checked for being offline.
  final Duration every;

  static const offlineAfter = Duration(minutes: 10);

  /// The `alerts` key keeping whether the offline alert is on. A new key:
  /// the old `offline` was saved as on by every change to the battery
  /// switch, so it does not say the user chose it.
  static const _offlineKey = 'answering';

  /// The `home.json` key keeping which devices were told offline or low.
  static const _toldKey = 'alertsTold';

  static const lowBattery = 15;

  /// A battery counts as charged again from here, so one hovering at the
  /// line does not alert on every reading.
  static const _batteryBack = 20;

  var offline = false;
  var battery = true;
  final _offline = <String>{};
  final _low = <String>{};
  Timer? _timer;
  StreamSubscription<Map<String, Object?>>? _sub;

  Map<String, CommandHandler> get commands => {
    'alerts.get': get,
    'alerts.set': set,
  };

  Future<void> open() async {
    final saved = (await _file.read())['alerts'];
    if (saved is Map) {
      offline = saved[_offlineKey] == true;
      battery = saved['battery'] != false;
    }
    final told = (await _file.read())[_toldKey];
    if (told is Map) {
      for (final (key, into) in [('offline', _offline), ('battery', _low)]) {
        into.addAll((told[key] as List? ?? const []).whereType<String>());
      }
    }
    // Told while the alert was on: nothing to say "answering again" for
    // until it is on again and tells anew.
    if (!offline) _offline.clear();
    _sub = _core.events.listen(_observe);
    _timer = Timer.periodic(every, (_) => _core.track(check()));
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
  }

  Map<String, Object?> _json() => {
    'offline': offline,
    'battery': battery,
    'offlineMinutes': offlineAfter.inMinutes,
    'lowBatteryPercent': lowBattery,
    'house': house,
  };

  Future<Map<String, Object?>> get(Map<String, Object?> _) async => _json();

  /// `{offline?, battery?}`: turns each alert on or off.
  Future<Map<String, Object?>> set(Map<String, Object?> args) async {
    for (final key in const ['offline', 'battery']) {
      if (args[key] != null && args[key] is! bool) {
        throw ApiError('invalid', '$key must be true or false');
      }
    }
    if (args['offline'] case final bool on) {
      offline = on;
      if (!on) _offline.clear();
    }
    if (args['battery'] case final bool on) {
      battery = on;
      if (!on) _low.clear();
    }
    await _file.update({
      'alerts': {_offlineKey: offline, 'battery': battery},
      _toldKey: _toldJson(),
    });
    return _json();
  }

  Map<String, Object?> _toldJson() => {
    'offline': _offline.toList()..sort(),
    'battery': _low.toList()..sort(),
  };

  Future<void> _saveTold() => _file.update({_toldKey: _toldJson()});

  void _notify(String kind, Device d, String title, String body) => _core.emit({
    'event': 'flow.announce',
    'type': 'notify',
    'title': title,
    'body': body,
    'alert': kind,
    'thing': d.id,
  });

  /// Looks at every device that reports in regularly, as at [at]. One
  /// offline (unseen for its online window) for [offlineAfter] alerts once.
  Future<void> check({DateTime? at}) async {
    final now = at ?? DateTime.now();
    if (!offline || !_hubRunning() || _away) {
      _pollingSince = null;
      return;
    }
    final since = _pollingSince ??= now;
    var changed = false;
    for (final d in await DriftDeviceStore(_core.db).all()) {
      if (!_owns(d.id)) continue;
      final window = _core.onlineWindowOf(d);
      if (window == null) continue;
      final seen = d.lastSeen;
      if (d.isOnline(now, window)) {
        if (_offline.remove(d.id)) {
          changed = true;
          _notify('online', d, '${d.name} is answering again', 'It is back');
        }
        continue;
      }
      if (seen == null) continue;
      final quiet = seen.isAfter(since) ? seen : since;
      if (now.difference(quiet) < window + offlineAfter) continue;
      if (_offline.add(d.id)) {
        changed = true;
        _notify(
          'offline',
          d,
          '${d.name} is not answering',
          'Not heard from for ${durationWords(now.difference(seen))}',
        );
      }
    }
    if (changed) await _saveTold();
  }

  void _observe(Map<String, Object?> e) {
    if (!battery || e['event'] != 'device.stateChanged') return;
    final device = e['device'];
    if (device is! Map) return;
    final id = device['id'];
    final state = device['state'];
    if (id is! String || state is! Map || !_owns(id)) return;
    final level = state['battery'];
    if (level is! num) return;
    if (level >= _batteryBack) {
      if (_low.remove(id)) _core.track(_saveTold());
    } else if (level < lowBattery && _low.add(id)) {
      _core.track(_saveTold());
      _core.emit({
        'event': 'flow.announce',
        'type': 'notify',
        'title': '${device['name'] ?? id} battery is low',
        'body': '${level.round()}% left',
        'alert': 'battery',
        'thing': id,
      });
    }
  }
}

/// [d] in plain words, to the unit that reads best: "12 minutes",
/// "3 hours", "5 days".
String durationWords(Duration d) {
  String of(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  if (d.inMinutes < 120) return of(d.inMinutes, 'minute');
  if (d.inHours < 48) return of(d.inHours, 'hour');
  return of(d.inDays, 'day');
}
