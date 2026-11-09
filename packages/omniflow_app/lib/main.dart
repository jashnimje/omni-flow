import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'service/foreground_runtime.dart';
import 'startup.dart';

export 'ui/home.dart' show OmniFlowApp;

/// The engine runs in a foreground service, so flows keep firing with the
/// screen off and after the app is swiped away. The UI only connects to it.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(
    Launcher(
      start: () => connectToService(
        control: const ForegroundServiceControl(),
        link: ForegroundTaskLink.new,
      ),
    ),
  );
}
