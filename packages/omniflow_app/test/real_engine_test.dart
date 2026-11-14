import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/startup.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

/// A UDP port nothing is bound to right now.
Future<int> freePort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final port = socket.port;
  socket.close();
  return port;
}

void main() {
  testWidgets('the app starts the hub on the real engine and hears a board', (
    tester,
  ) async {
    late Directory home;
    late Started started;
    late int helloPort;
    await tester.runAsync(() async {
      home = await Directory.systemTemp.createTemp('omni_app');
      helloPort = await freePort();
      started = await startEngine(
        home: home,
        secrets: InMemorySecretStore(),
        wizListenPort: await freePort(),
        boardHelloPort: helloPort,
      );
      await started.client.call('device.add', {
        'id': 'desk_lamp',
        'name': 'Desk lamp',
        'driver': 'philips_wiz_udp',
        'host': '127.0.0.1',
      });
    });
    expect(started.hubError, isNull);
    await tester.pumpWidget(Launcher(start: () async => started));

    Future<void> pumpUntil(Finder finder) async {
      for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    // A lamp that has not answered yet sits in Home's offline row.
    final lamp = find.textContaining('Desk lamp');
    await pumpUntil(lamp);
    expect(lamp, findsOneWidget);
    expect(
      find.byKey(const ValueKey('tile-desk_lamp')).evaluate().isNotEmpty ||
          find.byKey(const ValueKey('home-offline')).evaluate().isNotEmpty,
      isTrue,
    );

    await tester.runAsync(() async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      socket.send(
        utf8.encode(
          jsonEncode({
            'event': 'hello',
            'node': 'hall_board',
            'board': 'esp32',
          }),
        ),
        InternetAddress.loopbackIPv4,
        helloPort,
      );
      socket.close();
    });
    final found = find.text('New board found: hall_board (esp32) at 127.0.0.1');
    await pumpUntil(found);
    expect(found, findsOneWidget);

    await tester.runAsync(() async {
      await (started.client as InProcessEngineClient).engine.close();
      await home.delete(recursive: true);
    });
  });
}
