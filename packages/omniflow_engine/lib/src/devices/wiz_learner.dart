import 'dart:async';

import '../manifest/driver_registry.dart';
import 'device_service.dart';
import 'wiz_pilot.dart';

/// Asks each WiZ bulb once what it is (`getSystemConfig`, `getModelConfig`)
/// and keeps the answer in its [wizBulbSetting], which narrows its
/// capabilities and sliders to what it can do.
///
/// A bulb is asked the first time it reports its own state (a push or a
/// poll), so an address nothing answers at is never probed.
class WizLearner {
  WizLearner(this._devices, this._registry, {this.track});

  final DeviceService _devices;
  final DriverRegistry _registry;

  /// Keeps the engine open until a lookup in flight finishes.
  final void Function(Future<void> work)? track;
  final _asked = <String>{};

  void observe(DeviceStateChanged e) {
    final d = e.device;
    if (e.by != null || d.lastSeen == null) return;
    if (!isWizPilot(_registry[d.driverId])) return;
    if (d.settings[wizBulbSetting] is Map || !_asked.add(d.id)) return;
    final work = learn(d.id).then<void>((_) {}, onError: (Object _) {});
    track?.call(work);
  }

  /// Reads what bulb [deviceId] is and stores it. A bulb whose firmware
  /// has no `getModelConfig` is described from `getSystemConfig` alone.
  Future<WizBulb> learn(String deviceId) async {
    Future<Map?> read(String method) async {
      try {
        final reply = await _devices.sendCommand(deviceId, {
          'method': method,
          'params': <String, Object?>{},
        });
        final result = reply.json?['result'];
        return result is Map ? result : null;
      } on Exception {
        return null;
      }
    }

    final system = await read('getSystemConfig');
    final model = await read('getModelConfig');
    final bulb = WizBulb.from(system: system, model: model);
    if (bulb.module != null || bulb.hasWhiteRange) {
      await _devices.updateDevice(
        deviceId,
        (d) => d.copyWith(
          settings: {...d.settings, wizBulbSetting: bulb.toJson()},
        ),
      );
    }
    return bulb;
  }

  void forget(String deviceId) => _asked.remove(deviceId);
}
