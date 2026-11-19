import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What this device does besides running the engine. The Android app has
/// all of it through its Kotlin bridges. iOS and the desktop run the engine
/// inside the app while it is open, so they have none of it, and the
/// screens hide what would only fail there.
class DeviceFeatures {
  const DeviceFeatures({
    required this.backgroundService,
    required this.phoneThing,
    required this.nfc,
    required this.usbBoards,
    required this.hubMode,
    required this.shake,
  });

  /// The foreground service that keeps automations running with the app
  /// closed, and Phone setup, which looks after its permissions and the
  /// battery saver.
  final bool backgroundService;

  /// This phone as a thing in rules: its triggers (apps, notifications,
  /// Bluetooth, the screen, charging, calls and more) and its actions.
  final bool phoneThing;

  /// Reading and writing NFC tags.
  final bool nfc;

  /// Boards plugged in over USB, and writing firmware to them.
  final bool usbBoards;

  /// Handing the home to a Mac mini hub, which restarts the service as a
  /// client of the hub.
  final bool hubMode;

  /// Shaking the phone to run a scene.
  final bool shake;

  static const android = DeviceFeatures(
    backgroundService: true,
    phoneThing: true,
    nfc: true,
    usbBoards: true,
    hubMode: true,
    shake: true,
  );

  static const inApp = DeviceFeatures(
    backgroundService: false,
    phoneThing: false,
    nfc: false,
    usbBoards: false,
    hubMode: false,
    shake: false,
  );

  /// The features of the device the app runs on.
  static DeviceFeatures get current => Platform.isAndroid ? android : inApp;
}

/// Android's by default, so tests see every screen. `main` sets the
/// device's own.
final deviceFeaturesProvider = Provider<DeviceFeatures>(
  (ref) => DeviceFeatures.android,
);
