import 'package:flutter/services.dart';

/// MainActivity's `omniflow/permissions` channel. Android hides the Wi-Fi
/// network's name from an app without location access, so a Wi-Fi place
/// cannot work until the user grants it.
class Permissions {
  const Permissions([this._channel = const MethodChannel(channelName)]);

  static const channelName = 'omniflow/permissions';

  final MethodChannel _channel;

  /// Asks for location access, and is true when it is granted.
  Future<bool> askForWifiName() async {
    try {
      return await _channel.invokeMethod<bool>('wifiName') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
