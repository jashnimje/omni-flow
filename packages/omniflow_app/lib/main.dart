import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:path_provider/path_provider.dart';

import 'api/engine_client.dart';
import 'state/providers.dart';
import 'ui/home.dart';

export 'ui/home.dart' show OmniFlowApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final engine = await OmniEngine.open(
    home: Directory('${support.path}/omniflow'),
    secrets: SecureStorageSecretStore(),
    tap: PacketTap(),
  );
  runApp(
    ProviderScope(
      overrides: [
        engineClientProvider.overrideWithValue(InProcessEngineClient(engine)),
      ],
      child: const OmniFlowApp(),
    ),
  );
}
