import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../devices/adb/adb_pairing.dart';
import '../manifest/driver_manifest.dart';

/// Android Wireless Debugging pairing with the six-digit code the phone
/// shows. Finding the phones is `android.find`.
class AndroidPairCommands {
  AndroidPairCommands(this._core);

  final EngineCore _core;

  Map<String, CommandHandler> get commands => {'android.pair': pair};

  /// `{host, port, code, id?}`: pairs with the phone's "Pair device with
  /// pairing code" screen at [host]:[port]. Returns `{guid, message}`, and
  /// `{id}` when [id] names an ADB device, whose stable id becomes the guid
  /// so the engine can follow it to a new connect port. The code is never
  /// logged, stored or put in an error.
  Future<Map<String, Object?>> pair(Map<String, Object?> args) async {
    final host = stringArg(args, 'host');
    final port = optIntArg(args, 'port');
    if (port == null || port < 1 || port > 65535) {
      throw ApiError('invalid', 'port must be the pairing port, 1 to 65535');
    }
    final code = args['code'];
    if (code is! String || !adbPairingCodePattern.hasMatch(code)) {
      throw ApiError(
        'invalid',
        'code must be the six digits the phone shows under Pair device with '
            'pairing code',
      );
    }
    final id = optStringArg(args, 'id');
    if (id != null) {
      final device = await _core.device(id);
      final driver = _core.registry[device.driverId];
      if (driver == null || driver.transport.type != TransportType.adb) {
        throw ApiError('invalid', '$id is not an Android device over ADB');
      }
    }
    final AdbPairingResult result;
    try {
      result = await pairAdbDevice(
        host: host,
        port: port,
        code: code,
        key: await _core.adb.hostKey(),
        keyName: _core.adb.keyName,
      );
    } on AdbPairingFailedException catch (e) {
      throw switch (e.failure) {
        AdbPairingFailure.unreachable => ApiError(
          'timeout',
          '${e.message}. Open Pair device with pairing code on the phone, '
              'and use the address and port it shows',
        ),
        AdbPairingFailure.timeout => ApiError('timeout', e.message),
        AdbPairingFailure.wrongCode => ApiError(
          'pairing_failed',
          '${e.message}. Check the six digits and pair again before the '
              'phone closes the code',
        ),
        AdbPairingFailure.tls ||
        AdbPairingFailure.protocol => ApiError('pairing_failed', e.message),
      };
    }
    if (id != null) {
      // A new pairing is the user's say that this is the phone: its first
      // TLS connection pins its identity again. The pairing port's own
      // certificate is made fresh for each pairing, so it is no identity.
      await _core.adb.forgetIdentity(id);
      await _core.devices.updateDevice(
        id,
        (d) => d.copyWith(stableId: result.guid),
      );
    }
    return {
      'guid': result.guid,
      'id': ?id,
      'message':
          'Paired with ${result.guid}. Connect to the port under Wireless '
          'debugging, IP address and Port',
    };
  }
}

/// Saves that [deviceId] answers at [host]:[port] now, as the ADB channel
/// found it on mDNS by its guid, and says so with `device.moved`.
Future<void> recordAdbMove(
  EngineCore core,
  String deviceId,
  String host,
  int port,
) async {
  final before = await core.device(deviceId);
  await core.devices.updateDevice(
    deviceId,
    (d) => d.copyWith(host: host, port: port),
  );
  core.emit({
    'event': 'device.moved',
    'deviceId': deviceId,
    'from': '${before.host}:${before.port ?? ''}',
    'to': '$host:$port',
  });
}
