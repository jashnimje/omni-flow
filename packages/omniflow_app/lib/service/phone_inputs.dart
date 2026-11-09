import 'dart:async';

import 'package:flutter/services.dart';

import '../api/engine_calls.dart';
import '../api/engine_client.dart';

/// Feeds the phone thing from Android, inside the service so it keeps
/// working with the screen off: the battery level and charging, and the
/// Wi-Fi network. Readings come from PhoneSensorsBridge.kt on the
/// `omniflow/phone_sensors` event channel of the service's engine:
///
/// - `{"kind": "battery", "level": 0..100, "charging": bool}`
/// - `{"kind": "wifi", "connected": bool, "ssid"?: String, "bssid"?: String}`
class PhoneInputs {
  PhoneInputs(this._engine, {Stream<Object?>? readings})
    : _readings =
          readings ?? const EventChannel(channelName).receiveBroadcastStream();

  static const channelName = 'omniflow/phone_sensors';

  final EngineClient _engine;
  final Stream<Object?> _readings;
  StreamSubscription<Object?>? _sub;
  ({int? level, bool? charging})? _battery;
  ({String? ssid, String? bssid})? _wifi;

  void start() {
    _sub ??= _readings.listen(
      (r) => unawaited(_on(r)),
      // A phone or build without the bridge has no readings to send.
      onError: (Object _) {},
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Android repeats the battery broadcast for voltage and temperature
  /// changes, so only a new level or charging state is sent.
  Future<void> _on(Object? reading) async {
    if (reading is! Map) return;
    switch (reading['kind']) {
      case 'battery':
        final level = (reading['level'] as num?)?.round();
        final charging = reading['charging'] as bool?;
        if (level == null && charging == null) return;
        final next = (level: level, charging: charging);
        if (next == _battery) return;
        _battery = next;
        await _send(
          EngineCalls.phoneBattery,
          EngineCalls.batteryArgs(level: level, charging: charging),
        );
      case 'wifi':
        final connected = reading['connected'] == true;
        final ssid = reading['ssid'] as String?;
        // Connected with the name hidden (no location access) says nothing
        // about where the phone is, so it must not read as "off Wi-Fi".
        if (connected && ssid == null) return;
        final next = connected
            ? (ssid: ssid, bssid: reading['bssid'] as String?)
            : (ssid: null, bssid: null);
        if (next == _wifi) return;
        _wifi = next;
        await _send(
          EngineCalls.phoneWifi,
          EngineCalls.wifiArgs(ssid: next.ssid, bssid: next.bssid),
        );
    }
  }

  Future<void> _send(String command, Json args) async {
    try {
      await _engine.call(command, args);
    } on Object {
      return;
    }
  }
}
