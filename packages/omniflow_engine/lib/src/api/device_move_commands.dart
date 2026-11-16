import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'smart_home.dart' show EngineCall;

/// `device.move {id, host, port?, stableId?}`: a device found again at a new
/// address. It is added again in place under the same id, so it keeps its
/// driver, name, room, settings and automations, and only where it is
/// changes. The app's Find again sheet and `omni device move` both send it.
class DeviceMoveCommands {
  DeviceMoveCommands(this._core, this._call);

  final EngineCore _core;
  final EngineCall _call;

  Map<String, CommandHandler> get commands => {'device.move': move};

  Future<Map<String, Object?>> move(Map<String, Object?> args) async {
    final device = await _core.device(stringArg(args, 'id'));
    final host = stringArg(args, 'host');
    if (host.trim().isEmpty) throw ApiError('invalid', 'host is empty');
    final port = optIntArg(args, 'port');
    if (port != null && (port < 1 || port > 65535)) {
      throw ApiError('invalid', 'port must be 1 to 65535');
    }
    final reply = await _call('thing.add', {
      'driver': device.driverId,
      'host': host.trim(),
      'port': ?port,
      'stableId': ?(optStringArg(args, 'stableId') ?? device.stableId),
      'id': device.id,
      'name': device.name,
      'room': ?device.room,
      'settings': device.settings,
      'replace': true,
    });
    if (reply['ok'] != true) {
      final error = reply['error'] as Map? ?? const {};
      throw ApiError(
        '${error['type'] ?? 'unavailable'}',
        '${error['message'] ?? 'could not move ${device.name}'}',
      );
    }
    return {
      ...reply..remove('ok'),
      'id': device.id,
      'host': host.trim(),
      'message': '${device.name} is at ${host.trim()} now',
    };
  }
}
