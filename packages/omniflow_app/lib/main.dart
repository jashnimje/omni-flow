import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'nfc/nfc.dart';
import 'service/foreground_runtime.dart';
import 'service/in_app_runtime.dart';
import 'service/permissions.dart';
import 'service/phone_files.dart';
import 'startup.dart';
import 'state/device_features.dart';
import 'state/providers.dart';

export 'ui/app.dart' show OmniFlowApp;

/// On Android the engine runs in a foreground service, so flows keep firing
/// with the screen off and after the app is swiped away. The UI only
/// connects to it. Elsewhere the engine runs in the app while it is open.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid) {
    runApp(
      Launcher(
        start: openInAppEngine,
        startFailed: Launcher.inAppStartFailed,
        platform: [
          deviceFeaturesProvider.overrideWithValue(DeviceFeatures.current),
          phoneFilesProvider.overrideWithValue(const PluginPhoneFiles()),
        ],
      ),
    );
    return;
  }
  FlutterForegroundTask.initCommunicationPort();
  final intents = PlatformNfcIntents();
  runApp(
    Launcher(
      start: () => connectToService(
        control: const ForegroundServiceControl(),
        link: ForegroundTaskLink.new,
      ),
      serviceRunning: () => const ForegroundServiceControl().isRunning,
      platform: [
        nfcAdapterProvider.overrideWithValue(PluginNfcAdapter()),
        nfcIntentsProvider.overrideWithValue(intents),
        phoneFilesProvider.overrideWithValue(const PluginPhoneFiles()),
        wifiNamePermissionProvider.overrideWithValue(
          const Permissions().askForWifiName,
        ),
      ],
    ),
  );
}
