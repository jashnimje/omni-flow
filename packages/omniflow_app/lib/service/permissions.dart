import 'package:flutter/services.dart';

/// MainActivity's `omniflow/permissions` channel. Android hides the Wi-Fi
/// network's name from an app without location access, so a Wi-Fi place
/// cannot work until the user grants it. Android 17 also asks before an app
/// talks to devices on the local network (the nearby devices permission).
class Permissions {
  const Permissions([this._channel = const MethodChannel(channelName)]);

  static const channelName = 'omniflow/permissions';

  final MethodChannel _channel;

  Future<T?> _invoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Calls [method] on the channel, and is its answer, or false off
  /// Android.
  Future<bool> call(String method) async =>
      await _invoke<bool>(method) ?? false;

  /// Asks for location access, and is true when it is granted.
  Future<bool> askForWifiName() async =>
      await _invoke<bool>('wifiName') ?? false;

  /// Asks for location all the time, which a Wi-Fi place needs to work with
  /// the screen off. Android opens its settings page for it.
  Future<bool> askForWifiNameAlways() async =>
      await _invoke<bool>('wifiNameAlways') ?? false;

  /// Asks for local network access where Android has it, and is true when
  /// OmniFlow may reach the local network.
  Future<bool> askForLocalNetwork() async =>
      await _invoke<bool>('localNetwork') ?? false;

  /// `{location, locationAlways, localNetwork, localNetworkNeeded,
  /// usageAccess, notificationAccess, bluetooth, bluetoothNeeded,
  /// phoneState, calendar, dndAccess, fullScreen, locationOn, exactAlarms,
  /// serviceRunning}`, or null off Android. `locationOn` is the location
  /// switch: off, Android hides the Wi-Fi name and Wi-Fi places cannot see
  /// the phone arrive. `exactAlarms` is Alarms and reminders: off, a killed
  /// service cannot come back by itself and time triggers keep the phone
  /// awake.
  Future<Map<String, Object?>?> status() async {
    final map = await _invoke<Map<Object?, Object?>>('status');
    return map == null
        ? null
        : {for (final e in map.entries) '${e.key}': e.value};
  }

  /// Whether the location switch is on. Null off Android.
  Future<bool?> locationOn() async => (await status())?['locationOn'] as bool?;

  /// Opens Android's location switch page.
  Future<bool> openLocationSwitch() => call('locationSwitch');

  /// Opens Android's Alarms and reminders page for OmniFlow.
  Future<bool> askForExactAlarms() => call('exactAlarms');

  /// Where the phone last was, from a fix Android already has, or null
  /// without location access or a fix.
  Future<({double latitude, double longitude})?> lastLocation() async {
    final map = await _invoke<Map<Object?, Object?>>('lastLocation');
    final lat = map?['latitude'];
    final lon = map?['longitude'];
    return lat is num && lon is num
        ? (latitude: lat.toDouble(), longitude: lon.toDouble())
        : null;
  }

  /// Opens OmniFlow's page in the system settings, for a permission the
  /// user refused for good.
  Future<void> openAppSettings() => _invoke<void>('appSettings');
}
