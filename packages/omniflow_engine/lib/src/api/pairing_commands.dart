import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';
import '../storage/secret_store.dart';

/// `device.pair`: runs the pairing the device's driver needs, and says what
/// the user must do. The prompt to show first is the device's
/// `pairing.prompt` in device JSON.
class PairingCommands {
  PairingCommands(this._core);

  final EngineCore _core;

  /// `{id, appName?}`. Returns `{id, method, paired, message}` plus what the
  /// method adds. A refused or unanswered pairing fails with
  /// `pairing_failed`, an unreachable device with `timeout`.
  Future<Map<String, Object?>> pair(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final device = await _core.device(id);
    final manifest =
        _core.registry[device.driverId] ??
        (throw ApiError('not_found', 'no driver ${device.driverId}'));
    final spec =
        manifest.pairingSpec ??
        (throw ApiError('invalid', '$id (${manifest.id}) needs no pairing'));
    final base = {'id': id, 'method': spec.method.wireName};
    switch (spec.method) {
      case PairingMethod.adb:
        final prompted = await _core.adb.pair(device, manifest);
        return {
          ...base,
          'paired': true,
          'prompted': prompted,
          'message': prompted
              ? '$id accepted the key. Commands now run without a prompt'
              : '$id already trusts this key',
        };
      case PairingMethod.tv:
        final newKey = await _core.tv.pair(device, manifest);
        return {
          ...base,
          'paired': true,
          'newKey': newKey,
          'message': newKey
              ? '$id is paired and its key is stored'
              : '$id was already paired',
        };
      case PairingMethod.hueBridge:
        final port = device.port ?? manifest.transport.port ?? 80;
        // One username serves every light on the bridge, so each of them
        // gets it and the button is pressed once.
        final ids = [
          for (final d in await DriftDeviceStore(_core.db).all())
            if (d.driverId == device.driverId &&
                d.host == device.host &&
                (d.port ?? manifest.transport.port ?? 80) == port)
              d.id,
        ];
        await _core.http.pairHueBridge(
          host: device.host,
          port: port,
          deviceIds: ids,
          appName: optStringArg(args, 'appName') ?? 'omniflow',
        );
        return {
          ...base,
          'paired': true,
          'devices': ids,
          'message': 'The bridge username is stored for ${ids.join(', ')}',
        };
      case PairingMethod.secret:
        final key = spec.secret!;
        final stored =
            await _core.secrets.read(deviceSecretKey(id, key)) != null;
        return {
          ...base,
          'paired': stored,
          'secret': key,
          'message': stored
              ? '$key is stored for $id'
              : pairingPrompt(spec, device),
        };
    }
  }
}
