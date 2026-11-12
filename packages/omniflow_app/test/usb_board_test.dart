import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/boards/usb_board.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('open'),
        onPressed: () => showUsbBoardSheet(context),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = FakeEngine();
    engine.devices = [];
    engine.answers['device.get'] = {
      'ok': true,
      'device': {
        'id': 'phone',
        'state': {'wifi_ssid': 'HomeWiFi'},
      },
    };
    engine.answers['device.discover'] = {
      'ok': true,
      'found': [
        {
          'host': 'usb:/dev/bus/usb/001/002',
          'stableId': 'omni_a1b2',
          'reply': {'event': 'describe', 'board': 'esp32', 'node': 'omni_a1b2'},
        },
      ],
    };
    engine.answers['board.setup'] = {
      'ok': true,
      'node': 'desk_board',
      'board': 'esp32',
      'wifi': {'configured': true, 'connected': true, 'ip': '192.168.1.40'},
    };
    engine.answers['thing.add'] = {'ok': true, 'id': 'desk_board'};
  });

  Future<void> open(WidgetTester tester) async {
    await pumpScreen(tester, engine, const _Opener());
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a board on the phone USB gets its name and Wi-Fi, then is added',
    (tester) async {
      await open(tester);
      expect(find.text('omni_a1b2'), findsWidgets);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('usb-ssid')))
            .controller!
            .text,
        'HomeWiFi',
      );
      await tester.enterText(
        find.byKey(const ValueKey('usb-name')),
        'desk_board',
      );
      await tester.enterText(
        find.byKey(const ValueKey('usb-password')),
        'hunter22',
      );
      await tester.tap(find.byKey(const ValueKey('usb-save')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('board.setup').single.$2, {
        'port': 'usb:/dev/bus/usb/001/002',
        'name': 'desk_board',
        'ssid': 'HomeWiFi',
        'password': 'hunter22',
      });
      expect(engine.callsOf('thing.add').single.$2, {
        'driver': 'omniflow_board',
        'host': '192.168.1.40',
        'stableId': 'desk_board',
        'name': 'desk_board',
      });
      expect(
        find.textContaining('On HomeWiFi at 192.168.1.40'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a board set up again is not added twice', (tester) async {
    engine.answers['thing.add'] = {
      'ok': false,
      'error': {'type': 'exists', 'message': 'this is the device desk already'},
    };
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('usb-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('already'), findsNothing);
    expect(find.textContaining('On HomeWiFi'), findsOneWidget);
  });

  testWidgets('with nothing plugged in it says how to connect one', (
    tester,
  ) async {
    engine.answers['device.discover'] = {'ok': true, 'found': []};
    await open(tester);
    expect(find.byKey(const ValueKey('usb-none')), findsOneWidget);
    expect(find.textContaining('data cable'), findsOneWidget);
  });
}
