import 'dart:io';

import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:path_provider/path_provider.dart';

import 'api/engine_client.dart';
import 'startup.dart';

export 'ui/home.dart' show OmniFlowApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    Launcher(
      start: () async {
        final support = await getApplicationSupportDirectory();
        return startEngine(
          home: Directory('${support.path}/omniflow'),
          secrets: SecureStorageSecretStore(),
          tap: PacketTap(),
        );
      },
    ),
  );
}
