import 'dart:io';

import 'alerts.dart';
import 'auto_backup.dart';
import 'automation_commands.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'house_things.dart';
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
class HouseHelpers {
  HouseHelpers._(
    this._core,
    this.modes,
    this.timers,
    this.alerts,
    this._rooms,
    this._scenes,
    this.backups,
  );

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
      HouseModes(core, file),
      HouseTimers(core, home),
      HouseAlerts(core, file, hubRunning: hubRunning),
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
    );
    await helpers.modes.open();
    await helpers.alerts.open();
    await helpers.backups.open();
    core.builtInThings[houseModeThing] = helpers.modes.invoke;
    core.builtInThings[timersThing] = helpers.timers.invoke;
    await helpers.timers.open();
    return helpers;
  }

  final EngineCore _core;
  final HouseModes modes;
  final HouseTimers timers;
  final HouseAlerts alerts;
  final RoomControl _rooms;
  final SceneCapture _scenes;

  /// The daily backup into the engine home's `backups/`.
  final AutoBackup backups;

  Map<String, CommandHandler> get commands => {
    ...modes.commands,
    ...timers.commands,
    ...alerts.commands,
    ..._rooms.commands,
    ..._scenes.commands,
    ...backups.commands,
  };

  /// What a backup keeps of them under `home`.
  Map<String, Object?> backupJson() => {
    ...modes.backupJson(),
    'alerts': {'offline': alerts.offline, 'battery': alerts.battery},
  };

  /// Takes what a backup's `home` holds of them.
  Future<void> restore(Object? home) async {
    if (home is! Map) return;
    await modes.restore(home);
    final saved = home['alerts'];
    if (saved is Map) {
      await alerts.set({
        if (saved['offline'] is bool) 'offline': saved['offline'],
        if (saved['battery'] is bool) 'battery': saved['battery'],
      });
    }
  }

  Future<void> close() async {
    _core.builtInThings.clear();
    await timers.close();
    await alerts.close();
    await backups.close();
    await modes.close();
  }
}
