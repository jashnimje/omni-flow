import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:path_provider/path_provider.dart';

import '../api/engine_client.dart';
import '../startup.dart';

/// iOS and the desktop have no background service, so the engine runs in
/// the app's own isolate while the app is open and stops with it. Its home
/// is the app's own, apart from the CLI's `~/.omniflow`.
Future<Started> openInAppEngine() async {
  final support = await getApplicationSupportDirectory();
  return startEngine(
    home: Directory('${support.path}/omniflow'),
    secrets: SecureStorageSecretStore(),
    tap: PacketTap(),
  );
}
