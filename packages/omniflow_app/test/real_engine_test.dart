import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/home.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

void main() {
  testWidgets('the app runs on the real engine and database', (tester) async {
    late Directory home;
    late OmniEngine engine;
    await tester.runAsync(() async {
      home = await Directory.systemTemp.createTemp('omni_app');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
      );
      await engine.handle('device.add', {
        'id': 'desk_lamp',
        'name': 'Desk lamp',
        'driver': 'philips_wiz_udp',
        'host': '127.0.0.1',
      });
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineClientProvider.overrideWithValue(InProcessEngineClient(engine)),
        ],
        child: const OmniFlowApp(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Desk lamp'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));
    await tester.runAsync(() async {
      await engine.close();
      await home.delete(recursive: true);
    });
  });
}
