import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'stored_flows.dart';
import '../dag/flow_engine.dart';
import '../storage/database.dart';
import '../zones/zones.dart';

/// The state flows read besides devices: global variables, zones, and the
/// BLE and Wi-Fi readings that place the user in a zone.
class StateCommands {
  StateCommands(this._core, this._stored);

  final EngineCore _core;
  final StoredFlows _stored;

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

  Future<Map<String, Object?>> zoneSave(Map<String, Object?> args) async {
    final zone = ZoneSpec.parse(objectArg(args, 'zone'));
    await DriftZoneStore(_db).put(zone.id, zone.toJson());
    await _stored.reloadZones();
    return {'id': zone.id};
  }

  Future<Map<String, Object?>> zoneList(Map<String, Object?> _) async => {
    'zones': [
      for (final z in await DriftZoneStore(_db).all())
        {...z, 'inside': _flows.zones.isInside(z['id'] as String)},
    ],
    'needBle': _flows.zones.zonesNeedingBle.toList(),
  };

  Future<Map<String, Object?>> zoneRemove(Map<String, Object?> args) async {
    final removed = await DriftZoneStore(_db).remove(stringArg(args, 'id'));
    await _stored.reloadZones();
    return {'removed': removed};
  }

  Future<Map<String, Object?>> sensorBle(Map<String, Object?> args) async {
    final rssi = args['rssi'];
    if (rssi is! num) throw ApiError('invalid', 'rssi must be a number');
    _flows.bleReading(
      stringArg(args, 'name'),
      rssi.toDouble(),
      optDateArg(args, 'at') ?? DateTime.now(),
    );
    return {'zones': _flows.zones.states};
  }

  Future<Map<String, Object?>> sensorWifi(Map<String, Object?> args) async {
    await _flows.wifi(
      optStringArg(args, 'ssid'),
      optStringArg(args, 'bssid'),
      DateTime.now(),
    );
    return {'zones': _flows.zones.states};
  }
}
