import 'dart:async';
import 'dart:io';

import 'alerts.dart';
import 'api_error.dart';
import 'auto_backup.dart';
import 'automation_commands.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'house_things.dart';
import 'houses.dart';
import 'mode_commands.dart';
import 'room_control.dart';
import 'scene_capture.dart';
import 'stored_flows.dart';
import 'timer_commands.dart';

/// The home helpers: house modes, named timers, a room as one light,
/// scenes saved from how things are now, the built-in alerts, and the
/// daily automatic backup. The
/// engine opens them once its flows are loaded, so a timer that ended
/// while it was closed starts its rules.
///
/// The mode and the alerts are each house's own: one [HouseModes] and one
/// [HouseAlerts] per house, chosen by a command's `house` (the first house
/// when it names none). The timers carry their house.
class HouseHelpers {
  HouseHelpers._(
    this._core,
    this._home,
    this.timers,
    this._rooms,
    this._scenes,
    this.backups, {
    this._hubRunning,
  });

  static Future<HouseHelpers> open(
    EngineCore core,
    Directory home,
    StoredFlows stored,
    AutomationCommands automations, {
    bool Function()? hubRunning,
    Future<Map<String, Object?>> Function()? exportBackup,
  }) async {
    final file = HomeFile(home);
    final helpers = HouseHelpers._(
      core,
      home,
      HouseTimers(core, home),
      RoomControl(core, stored),
      SceneCapture(core, stored, automations),
      AutoBackup(
        core,
        home,
        file,
        export:
            exportBackup ??
            () async => throw StateError('this engine cannot export'),
        hubRunning: hubRunning,
      ),
      hubRunning: hubRunning,
    );
    await helpers._openHouses();
    await helpers.backups.open();
    await helpers.timers.open();
    helpers._sub = core.events.listen((e) {
      if (e['event'] == housesChangedEvent) {
        core.track(helpers._opening = helpers._openHouses());
      }
    });
    return helpers;
  }

  final EngineCore _core;
  final Directory _home;
  final bool Function()? _hubRunning;
  final HouseTimers timers;
  final RoomControl _rooms;
  final SceneCapture _scenes;
  StreamSubscription<Map<String, Object?>>? _sub;

  /// The houses opening after one is added, which a command waits for.
  Future<void>? _opening;

  /// Each house's mode, by house id.
  final _modes = <String, HouseModes>{};

  /// Each house's alerts, by house id.
  final _alerts = <String, HouseAlerts>{};

  /// The daily backup into the engine home's `backups/`.
  final AutoBackup backups;

  /// The mode of [house], or of the first house.
  HouseModes modesOf([String? house]) {
    final id = house ?? _core.houses.defaultId;
    return _modes[id] ?? (throw ApiError('not_found', 'There is no house $id'));
  }

  HouseModes get modes => modesOf();

  /// The alerts of [house], or of the first house.
  HouseAlerts alertsOf([String? house]) {
    final id = house ?? _core.houses.defaultId;
    return _alerts[id] ??
        (throw ApiError('not_found', 'There is no house $id'));
  }

  HouseAlerts get alerts => alertsOf();

  /// Opens the mode and the alerts of every house that has none yet, and
  /// closes those of a removed house.
  Future<void> _openHouses() async {
    final ids = {for (final h in _core.houses.all) h.id};
    if (ids.isEmpty) ids.add(firstHouseId);
    for (final gone in _modes.keys.where((k) => !ids.contains(k)).toList()) {
      await _modes.remove(gone)!.close();
      await _alerts.remove(gone)?.close();
      _core.builtInThings.remove(houseThingId(houseModeThing, gone));
      _core.builtInThings.remove(houseThingId(timersThing, gone));
      _core.flows.deviceStates.remove(houseThingId(houseModeThing, gone));
    }
    for (final id in ids) {
      if (_modes.containsKey(id)) continue;
      final file = HomeFile.house(_home, id);
      final modes = _modes[id] = HouseModes(_core, file, house: id);
      await modes.open();
      final alerts = _alerts[id] = HouseAlerts(
        _core,
        file,
        hubRunning: _hubRunning,
        house: id,
      );
      await alerts.open();
      _core.builtInThings[houseThingId(houseModeThing, id)] = modes.invoke;
      _core.builtInThings[houseThingId(timersThing, id)] = (
        capability,
        params, {
        by,
      }) => timers.invoke(capability, params, by: by, house: id);
    }
    // The plain ids a flow names: its own house's thing, from the flow
    // that runs the step.
    _core.builtInThings[houseModeThing] = (capability, params, {by}) =>
        modesOf(_houseOfFlow(by)).invoke(capability, params, by: by);
    _core.builtInThings[timersThing] = (capability, params, {by}) =>
        timers.invoke(capability, params, by: by, house: _houseOfFlow(by));
  }

  String _houseOfFlow(String? flowId) =>
      (flowId == null ? null : _core.houses.flowHouses[flowId]) ??
      _core.houses.defaultId;

  Future<HouseModes> _modesFor(Map<String, Object?> args) async {
    await _opening;
    return modesOf(_core.houses.resolve(args['house']));
  }

  Future<HouseAlerts> _alertsFor(Map<String, Object?> args) async {
    await _opening;
    return alertsOf(_core.houses.resolve(args['house']));
  }

  Map<String, CommandHandler> get commands => {
    'home.mode': (args) async => (await _modesFor(args)).get(args),
    'home.mode.set': (args) async => (await _modesFor(args)).set(args),
    ...timers.commands,
    'alerts.get': (args) async => (await _alertsFor(args)).get(args),
    'alerts.set': (args) async => (await _alertsFor(args)).set(args),
    ..._rooms.commands,
    ..._scenes.commands,
    ...backups.commands,
  };

  /// What a backup keeps of them under `home`: the first house's (or
  /// [house]'s) settings, as before houses.
  Map<String, Object?> backupJson([String? house]) {
    final alerts = alertsOf(house);
    return {
      ...modesOf(house).backupJson(),
      'alerts': {'offline': alerts.offline, 'battery': alerts.battery},
    };
  }

  /// Each house's settings, by house id, for a backup of every house.
  Map<String, Object?> housesBackupJson() => {
    for (final id in _modes.keys) id: backupJson(id),
  };

  /// Takes what a backup's `home` holds of them, into [house].
  Future<void> restore(Object? home, [String? house]) async {
    if (home is! Map) return;
    await _opening;
    await modesOf(house).restore(home);
    final saved = home['alerts'];
    if (saved is Map) {
      await alertsOf(house).set({
        if (saved['offline'] is bool) 'offline': saved['offline'],
        if (saved['battery'] is bool) 'battery': saved['battery'],
      });
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    _core.builtInThings.clear();
    await timers.close();
    for (final a in _alerts.values) {
      await a.close();
    }
    await backups.close();
    for (final m in _modes.values) {
      await m.close();
    }
  }
}
