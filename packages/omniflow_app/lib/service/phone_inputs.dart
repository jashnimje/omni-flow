import 'dart:async';

import 'package:flutter/services.dart';

import '../api/engine_calls.dart';
import '../api/engine_client.dart';
import 'notifier.dart';

/// Feeds the phone thing from Android, inside the service so it keeps
/// working with the screen off. Readings come from PhoneSensorsBridge.kt
/// (and NotificationTriggers.kt through it) on the `omniflow/phone_sensors`
/// event channel of the service's engine:
///
/// - `{"kind": "battery", "level": 0..100, "charging": bool}`
/// - `{"kind": "wifi", "connected": bool, "ssid"?: String, "bssid"?: String,
///   "locationOn"?: bool}`
/// - `{"kind": "location", "on": bool}`, the location switch
/// - `{"kind": "app", "package", "label"?, "event": "opened" | "closed"}`
/// - `{"kind": "notification", "package", "label"?, "title"?, "text"?}`
/// - `{"kind": "bluetooth", "name", "address", "connected": bool}`
/// - `{"kind": "screen", "on": bool}` and `{"kind": "dnd", "on": bool}`
///
/// A notification's text is only passed on to the engine, never kept or
/// logged here.
class PhoneInputs {
  PhoneInputs(
    this._engine, {
    Stream<Object?>? readings,
    PostSettingsNotice? post,
  }) : _readings =
           readings ?? const EventChannel(channelName).receiveBroadcastStream(),
       _post = post ?? AutomationNotifier.platformPost;

  final PostSettingsNotice _post;

  /// Called when the phone joins or leaves a Wi-Fi network, so the service
  /// stays awake while presence settles.
  void Function()? onWifiChanged;

  /// The location switch, as last read. With it off Android hides the
  /// Wi-Fi name, so a Wi-Fi place cannot see the phone arrive. Null until
  /// the phone says.
  bool? get locationOn => _locationOn;
  bool? _locationOn;
  var _toldLocationOff = false;

  static const channelName = 'omniflow/phone_sensors';

  static const phoneApp = 'phone.app';
  static const phoneNotification = 'phone.notification';
  static const phoneBluetooth = 'phone.bluetooth';
  static const phoneScreen = 'phone.screen';
  static const phoneDnd = 'phone.dnd';

  final EngineClient _engine;
  final Stream<Object?> _readings;
  StreamSubscription<Object?>? _sub;
  ({int? level, bool? charging})? _battery;
  ({String? ssid, String? bssid})? _wifi;
  bool? _screenOn;
  bool? _dndOn;

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
        if (reading['locationOn'] case final bool on) _locationOn = on;
        // Connected with the name hidden (location off, or no location
        // access) says nothing about where the phone is, so it must not
        // read as "off Wi-Fi".
        if (connected && ssid == null) {
          if (_locationOn == false) await _tellLocationOff();
          return;
        }
        final next = connected
            ? (ssid: ssid, bssid: reading['bssid'] as String?)
            : (ssid: null, bssid: null);
        if (next == _wifi) return;
        _wifi = next;
        onWifiChanged?.call();
        await _send(
          EngineCalls.phoneWifi,
          EngineCalls.wifiArgs(ssid: next.ssid, bssid: next.bssid),
        );
      case 'app':
        final package = _text(reading['package']);
        final event = reading['event'];
        if (package == null || (event != 'opened' && event != 'closed')) {
          return;
        }
        await _send(phoneApp, {
          'package': package,
          'label': ?_text(reading['label']),
          'event': event,
        });
      case 'notification':
        final package = _text(reading['package']);
        if (package == null) return;
        await _send(phoneNotification, {
          'package': package,
          'label': ?_text(reading['label']),
          'title': ?_text(reading['title']),
          'text': ?_text(reading['text']),
        });
      case 'bluetooth':
        final address = _text(reading['address']);
        final connected = reading['connected'];
        if (address == null || connected is! bool) return;
        await _send(phoneBluetooth, {
          'name': _text(reading['name']) ?? address,
          'address': address,
          'connected': connected,
        });
      case 'location':
        final on = reading['on'];
        if (on is! bool) return;
        _locationOn = on;
        if (on) {
          // Told again the next time it goes off.
          _toldLocationOff = false;
        } else {
          await _tellLocationOff();
        }
      case 'screen':
        final on = reading['on'];
        if (on is! bool || on == _screenOn) return;
        _screenOn = on;
        await _send(phoneScreen, {'on': on});
      case 'dnd':
        final on = reading['on'];
        if (on is! bool || on == _dndOn) return;
        _dndOn = on;
        await _send(phoneDnd, {'on': on});
      default:
        await _more(reading);
    }
  }

  static const phoneAlarm = 'phone.alarm';
  static const phoneCall = 'phone.call';
  static const phoneMedia = 'phone.media';
  static const phoneShake = 'phone.shake';
  static const phoneFaceDown = 'phone.faceDown';
  static const phoneHeadphones = 'phone.headphones';
  static const phoneBoot = 'phone.boot';
  static const phonePackage = 'phone.package';

  int? _alarmMs = -1;
  bool? _faceDown;
  bool? _headphones;
  bool? _playing;

  /// The readings PhoneActionsBridge.kt adds, each only while an
  /// automation uses it:
  ///
  /// - `{"kind": "alarm", "atMs"?: int}`, the next alarm, none when absent
  /// - `{"kind": "call", "state": "ringing" | "answered" | "ended"}`, with
  ///   no number
  /// - `{"kind": "media", "playing": bool, "package"?, "label"?, "title"?}`
  /// - `{"kind": "shake"}` and `{"kind": "face_down", "on": bool}`
  /// - `{"kind": "headphones", "plugged": bool}`
  /// - `{"kind": "boot"}` once after the phone started up
  /// - `{"kind": "package", "package", "label"?, "updated": bool}`
  Future<void> _more(Map reading) async {
    switch (reading['kind']) {
      case 'alarm':
        final at = reading['atMs'];
        final ms = at is int && at > 0 ? at : null;
        if (ms == _alarmMs) return;
        _alarmMs = ms;
        await _send(phoneAlarm, {
          if (ms != null)
            'at': DateTime.fromMillisecondsSinceEpoch(
              ms,
              isUtc: true,
            ).toIso8601String(),
        });
      case 'call':
        final state = reading['state'];
        if (!const {'ringing', 'answered', 'ended'}.contains(state)) return;
        await _send(phoneCall, {'state': state});
      case 'media':
        final playing = reading['playing'];
        if (playing is! bool || playing == _playing) return;
        _playing = playing;
        await _send(phoneMedia, {
          'playing': playing,
          'package': ?_text(reading['package']),
          'label': ?_text(reading['label']),
          'title': ?_text(reading['title']),
        });
      case 'shake':
        await _send(phoneShake, const {});
      case 'face_down':
        final on = reading['on'];
        if (on is! bool || on == _faceDown) return;
        _faceDown = on;
        await _send(phoneFaceDown, {'on': on});
      case 'headphones':
        final plugged = reading['plugged'];
        if (plugged is! bool || plugged == _headphones) return;
        _headphones = plugged;
        await _send(phoneHeadphones, {'plugged': plugged});
      case 'boot':
        await _send(phoneBoot, const {});
      case 'package':
        final package = _text(reading['package']);
        if (package == null) return;
        await _send(phonePackage, {
          'package': package,
          'label': ?_text(reading['label']),
          'updated': reading['updated'] == true,
        });
    }
  }

  static const locationNoticeId = 0x10ca7;

  /// Once per time location goes off, and only when a place is found by
  /// Wi-Fi: a notification that says arriving home cannot be seen, and
  /// opens the location switch.
  Future<void> _tellLocationOff() async {
    if (_toldLocationOff || !await _hasWifiPlace()) return;
    _toldLocationOff = true;
    await _post(
      channel: 'problems',
      id: locationNoticeId,
      title: 'Location is off',
      body:
          'Android hides the Wi-Fi name while location is off, so OmniFlow '
          'cannot see you arrive at a Wi-Fi place. Tap to turn location on.',
      open: 'location',
    );
  }

  Future<bool> _hasWifiPlace() async {
    try {
      final reply = await _engine.call('device.list');
      for (final d in reply['devices'] as List? ?? const []) {
        if (d is! Map || d['driver'] != 'place') continue;
        final settings = d['settings'];
        if (settings is Map && settings['wifi'] != null) return true;
      }
    } on Object {
      return false;
    }
    return false;
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  Future<void> _send(String command, Json args) async {
    try {
      await _engine.call(command, args);
    } on Object {
      return;
    }
  }
}
