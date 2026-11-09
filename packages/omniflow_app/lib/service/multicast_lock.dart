import 'package:flutter/services.dart';

/// Android's Wi-Fi multicast lock, held while the service runs so the phone
/// receives broadcast discovery replies and board hellos. The native side
/// (MulticastLockBridge.kt) exists only on the service's engine and also
/// releases the lock when that engine is destroyed.
class MulticastLock {
  MulticastLock([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'omniflow/multicast';

  final MethodChannel _channel;

  /// Whether the lock is now held. False when the platform has no lock,
  /// which leaves broadcast replies to whatever the Wi-Fi driver lets
  /// through.
  Future<bool> acquire() => _invoke('acquire');

  Future<void> release() => _invoke('release');

  Future<bool> _invoke(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
