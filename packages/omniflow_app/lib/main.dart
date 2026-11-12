import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'nfc/nfc.dart';
import 'service/foreground_runtime.dart';
import 'service/permissions.dart';
import 'service/phone_files.dart';
import 'startup.dart';
import 'state/providers.dart';

export 'ui/app.dart' show OmniFlowApp;

/// The engine runs in a foreground service, so flows keep firing with the
/// screen off and after the app is swiped away. The UI only connects to it.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
