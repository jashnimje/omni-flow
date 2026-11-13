import 'api_error.dart';
import 'command_args.dart';
import 'device_commands.dart';
import 'engine_core.dart';
import 'things_runtime.dart';
import '../dag/flow_engine.dart';
import '../storage/database.dart';
import '../zones/zones.dart';

/// The state flows read besides devices: global variables, and the phone's
/// inputs, which place the household person in places. `zone.*` and
/// `sensor.*` are the earlier names for places and the phone's Wi-Fi and
/// BLE inputs, kept as aliases for one release.
class StateCommands {
  StateCommands(this._core, this._things, this._devices);

  final EngineCore _core;
  final ThingsRuntime _things;
  final DeviceCommands _devices;

  OmniDatabase get _db => _core.db;
  FlowEngine get _flows => _core.flows;

  Future<Map<String, Object?>> varList(Map<String, Object?> _) async => {
    'variables': await DriftGlobalStore(_db).all(),
  };

  Future<Map<String, Object?>> varSet(Map<String, Object?> args) async {
    final name = stringArg(args, 'name');
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ApiError('invalid', 'a variable name is letters, digits and _');
    }
    await _flows.setGlobal(name, args['value']);
    return {'name': name, 'value': args['value']};
  }

  Future<Map<String, Object?>> varRemove(Map<String, Object?> args) async {
    final name = stringArg(args, 'name');
    _flows.globals.remove(name);
    return {'removed': await DriftGlobalStore(_db).remove(name)};
  }

  /// Saves a zone as the place thing that answers to its id.
  Future<Map<String, Object?>> zoneSave(Map<String, Object?> args) async {
    final zone = ZoneSpec.parse(objectArg(args, 'zone'));
    final place = await _things.saveZone(zone);
    return {'id': zone.id, 'place': place};
  }

  Future<Map<String, Object?>> zoneList(Map<String, Object?> _) =>
      _things.listZones();

  /// Removes the place a zone became, as `device.remove` does: the flows
  /// that name it are disabled.
  Future<Map<String, Object?>> zoneRemove(Map<String, Object?> args) async {
    final place = await _things.placeForZone(stringArg(args, 'id'));
    if (place == null) return {'removed': false};
    return _devices.remove({'id': place.id});
  }

  Future<Map<String, Object?>> phoneBle(Map<String, Object?> args) async {
    final rssi = args['rssi'];
    if (rssi is! num) throw ApiError('invalid', 'rssi must be a number');
    await _things.ble(
      stringArg(args, 'name'),
      rssi.toDouble(),
      optDateArg(args, 'at') ?? DateTime.now(),
    );
    return {'zones': _things.zoneStates};
  }

  Future<Map<String, Object?>> phoneWifi(Map<String, Object?> args) async {
    await _things.wifi(
      optStringArg(args, 'ssid'),
      optStringArg(args, 'bssid'),
      optDateArg(args, 'at') ?? DateTime.now(),
      phoneId: optStringArg(args, 'phone'),
    );
    return {'zones': _things.zoneStates};
  }

  /// `{home, person?}`: the user says whether they are home. The person
  /// reports `homeSource: manual` until a reading decides again.
  Future<Map<String, Object?>> presenceSet(Map<String, Object?> args) async {
    final home = args['home'];
    if (home is! bool) throw ApiError('invalid', 'home must be true or false');
    return {
      'state': await _things.setHome(
        home,
        personId: optStringArg(args, 'person'),
      ),
    };
  }

  /// `{package, label?, event: opened | closed, phone?}`.
  Future<Map<String, Object?>> phoneApp(Map<String, Object?> args) async {
    final event = args['event'];
    if (event != 'opened' && event != 'closed') {
      throw ApiError('invalid', 'event must be opened or closed');
    }
    return {
      'state': await _things.phoneApp(
        package: _package(args),
        label: optStringArg(args, 'label'),
        opened: event == 'opened',
        phoneId: optStringArg(args, 'phone'),
      ),
    };
  }

  /// `{package, label?, title?, text?, phone?}`. The reply carries no
  /// words of the notification.
  Future<Map<String, Object?>> phoneNotification(
    Map<String, Object?> args,
  ) async {
    await _things.phoneNotification(
      package: _package(args),
      label: optStringArg(args, 'label'),
      title: optStringArg(args, 'title'),
      text: optStringArg(args, 'text'),
      phoneId: optStringArg(args, 'phone'),
    );
    return {'received': true};
  }

  /// `{name, address?, connected, phone?}`.
  Future<Map<String, Object?>> phoneBluetooth(Map<String, Object?> args) async {
    final connected = args['connected'];
    if (connected is! bool) {
      throw ApiError('invalid', 'connected must be true or false');
    }
    final name = optStringArg(args, 'name')?.trim();
    if (name == null || name.isEmpty) {
      throw ApiError('invalid', 'name is the Bluetooth device\'s name');
    }
    return {
      'state': await _things.phoneBluetooth(
        name: name,
        address: optStringArg(args, 'address'),
        connected: connected,
        phoneId: optStringArg(args, 'phone'),
      ),
    };
  }

  /// `{on, phone?}`: the screen turned on or off.
  Future<Map<String, Object?>> phoneScreen(Map<String, Object?> args) =>
      _flag(args, 'screen_on');

  /// `{on, phone?}`: Do Not Disturb turned on or off.
  Future<Map<String, Object?>> phoneDnd(Map<String, Object?> args) =>
      _flag(args, 'dnd_on');

  Future<Map<String, Object?>> _flag(
    Map<String, Object?> args,
    String key,
  ) async {
    final on = args['on'];
    if (on is! bool) throw ApiError('invalid', 'on must be true or false');
    return {
      'state': await _things.phoneFlag(
        key,
        on,
        phoneId: optStringArg(args, 'phone'),
      ),
    };
  }

  static String _package(Map<String, Object?> args) {
    final package = optStringArg(args, 'package')?.trim();
    if (package == null || package.isEmpty) {
      throw ApiError('invalid', 'package is the app\'s package name');
    }
    return package;
  }

  Future<Map<String, Object?>> phoneBattery(Map<String, Object?> args) async {
    final charging = args['charging'];
    if (charging != null && charging is! bool) {
      throw ApiError('invalid', 'charging must be true or false');
    }
    return {
      'state': await _things.battery(
        level: optNumArg(args, 'level'),
        charging: charging as bool?,
        phoneId: optStringArg(args, 'phone'),
      ),
    };
  }
}
