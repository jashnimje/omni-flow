import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = FakeEngine());

  group('adding and managing devices', () {
    testWidgets('an empty dashboard offers Add device, not a CLI command', (
      tester,
    ) async {
      engine.devices = [];
      await pumpApp(tester, engine);
      expect(find.textContaining('omni '), findsNothing);
      expect(find.byKey(const ValueKey('add-device-empty')), findsOneWidget);
    });

    testWidgets('a scanned device is added with its name and room', (
      tester,
    ) async {
      engine.answers['driver.list'] = {
        'ok': true,
        'drivers': [
          {'id': 'philips_wiz_udp', 'name': 'Philips WiZ'},
          {'id': 'tuya_plug', 'name': 'Tuya plug'},
        ],
      };
      engine.answers['device.discover'] = {
        'ok': true,
        'found': [
          {'host': '192.168.1.40', 'stableId': 'a8bb50000001', 'knownAs': 'x'},
          {'host': '192.168.1.41', 'stableId': 'a8bb50aa'},
        ],
      };
      await pumpApp(tester, engine);
      await tester.tap(find.byKey(const ValueKey('add-device')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-driver')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Philips WiZ').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-scan')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.discover').single.$2, {
        'driver': 'philips_wiz_udp',
      });
      expect(find.byKey(const ValueKey('found-192.168.1.40')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('found-192.168.1.41')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('add-name')),
        'Hall lamp',
      );
      await tester.enterText(find.byKey(const ValueKey('add-room')), 'Hall');
      await tester.pump();
      expect(find.text('Id: hall_lamp'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-save')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.add').single.$2, {
        'id': 'hall_lamp',
        'name': 'Hall lamp',
        'driver': 'philips_wiz_udp',
        'host': '192.168.1.41',
        'room': 'Hall',
        'stableId': 'a8bb50aa',
      });
      expect(find.text('Added Hall lamp.'), findsOneWidget);
    });

    testWidgets('rename keeps the device and replaces its name and room', (
      tester,
    ) async {
      await pumpApp(tester, engine);
      await openDeviceMenu(tester, 'desk_lamp', 'Rename or move');
      await tester.enterText(find.byKey(const ValueKey('edit-name')), 'Lamp');
      await tester.enterText(find.byKey(const ValueKey('edit-room')), 'Bed');
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.add').single.$2, {
        'id': 'desk_lamp',
        'name': 'Lamp',
        'driver': 'philips_wiz_udp',
        'host': '192.168.1.40',
        'room': 'Bed',
        'settings': const <String, Object?>{},
        'replace': true,
        'provision': false,
      });
    });

    testWidgets('remove asks first, then removes and reloads', (tester) async {
      await pumpApp(tester, engine);
      final before = engine.callsOf('device.list').length;
      await openDeviceMenu(tester, 'desk_lamp', 'Remove');
      expect(find.text('Remove Desk lamp?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.remove').single.$2, {'id': 'desk_lamp'});
      expect(engine.callsOf('device.list').length, before + 1);
    });

    testWidgets('Pins shows for a device the engine marks as a board', (
      tester,
    ) async {
      engine.devices = [
        {
          ...FakeEngine.lamp(),
          'id': 'copied',
          'driver': 'my_board_copy',
          'board': true,
        },
      ];
      await pumpApp(tester, engine);
      await tester.tap(find.byKey(const ValueKey('device-menu-copied')));
      await tester.pumpAndSettle();
      expect(find.text('Pins'), findsOneWidget);
    });
  });

  group('reachability', () {
    testWidgets('an offline event badges the card until the device is heard', (
      tester,
    ) async {
      await pumpApp(tester, engine);
      expect(find.byKey(const ValueKey('offline-desk_lamp')), findsNothing);
      engine.eventsOut.add({
        'event': 'device.pollFailed',
        'device': 'desk_lamp',
        'error': 'no reply in 2s',
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('offline-desk_lamp')), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('offline-desk_lamp')), findsOneWidget);
      engine.eventsOut.add({
        'event': 'device.stateChanged',
        'device': {
          'id': 'desk_lamp',
          'state': {'state': true, 'dimming': 30},
        },
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('offline-desk_lamp')), findsNothing);
    });

    testWidgets('a device the engine lists as offline is badged', (
      tester,
    ) async {
      engine.devices = [
        {...FakeEngine.lamp(), 'online': false},
      ];
      await pumpApp(tester, engine);
      expect(find.byKey(const ValueKey('offline-desk_lamp')), findsOneWidget);
    });

    testWidgets('a never-read state shows a dash, not off or the minimum', (
      tester,
    ) async {
      engine.devices = [FakeEngine.lamp(state: const {})];
      await pumpApp(tester, engine);
      expect(find.byType(Switch), findsNothing);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('level-desk_lamp.brightness')),
            )
            .data,
        '-',
      );
      await tester.tap(find.text('On'));
      await tester.pump();
      expect(engine.callsOf('device.invoke').single.$2['params'], {
        'value': true,
      });
    });
  });

  group('controls', () {
    testWidgets('a colour is sent as r, g and b', (tester) async {
      engine.devices = [
        FakeEngine.lamp(
          extra: [
            {
              'id': 'rgb',
              'type': 'color_rgb',
              'label': 'Colour',
              'params': {
                'r': {'type': 'number', 'min': 0, 'max': 255},
                'g': {'type': 'number', 'min': 0, 'max': 255},
                'b': {'type': 'number', 'min': 0, 'max': 255},
              },
            },
          ],
        ),
      ];
      await pumpApp(tester, engine);
      await tester.tap(find.byKey(const ValueKey('color-Red')));
      await tester.pump();
      expect(engine.callsOf('device.invoke').last.$2['params'], {
        'r': 255,
        'g': 0,
        'b': 0,
      });
      await tester.enterText(find.byKey(const ValueKey('color-hex')), 'ff8800');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('color-send')));
      await tester.pump();
      expect(engine.callsOf('device.invoke').last.$2['params'], {
        'r': 255,
        'g': 136,
        'b': 0,
      });
    });

    testWidgets('an action with params gets a form that checks ranges', (
      tester,
    ) async {
      engine.devices = [
        FakeEngine.lamp(
          extra: [
            {
              'id': 'ir_nec',
              'type': 'action',
              'label': 'IR',
              'params': {
                'address': {'type': 'number', 'min': 0, 'max': 65535},
                'command': {'type': 'number', 'min': 0, 'max': 255},
              },
            },
          ],
        ),
      ];
      await pumpApp(tester, engine);
      final send = find.byKey(const ValueKey('params-run-IR'));
      expect(tester.widget<OutlinedButton>(send).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('param-address')), '4');
      await tester.enterText(
        find.byKey(const ValueKey('param-command')),
        '300',
      );
      await tester.pump();
      expect(find.text('Must be 0 to 255'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(send).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('param-command')), '8');
      await tester.pump();
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pump();
      expect(engine.callsOf('device.invoke').single.$2, {
        'id': 'desk_lamp',
        'capability': 'ir_nec',
        'params': {'address': 4, 'command': 8},
      });
    });

    testWidgets('an unknown capability type says it is not supported', (
      tester,
    ) async {
      engine.devices = [
        FakeEngine.lamp(
          extra: [
            {'id': 'scene', 'type': 'scene_list', 'label': 'Scenes'},
          ],
        ),
      ];
      await pumpApp(tester, engine);
      expect(find.text('Scenes'), findsOneWidget);
      expect(find.text('Not supported in the app yet'), findsOneWidget);
    });

    testWidgets('a high-risk action asks before running on the host', (
      tester,
    ) async {
      engine.devices = [
        {
          'id': 'mac',
          'name': 'Mac mini',
          'driver': 'macos_host',
          'host': '192.168.1.20',
          'state': const <String, Object?>{},
          'capabilities': [
            {
              'id': 'display_sleep',
              'type': 'action',
              'label': 'Sleep display',
              'highRisk': true,
              'params': {},
            },
          ],
        },
      ];
      await pumpApp(tester, engine);
      expect(find.byKey(const ValueKey('high-risk-mac')), findsOneWidget);
      await tester.tap(find.text('Sleep display'));
      await tester.pumpAndSettle();
      expect(find.textContaining('192.168.1.20'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.invoke'), isEmpty);
      await tester.tap(find.text('Sleep display'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(
        engine.callsOf('device.invoke').single.$2['capability'],
        'display_sleep',
      );
    });

    testWidgets('the slider announces its value with the unit', (tester) async {
      await pumpApp(tester, engine);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.semanticFormatterCallback!(30), '30%');
    });

    testWidgets('the dashboard meets the tap target and contrast guidelines', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      engine.devices = [
        FakeEngine.lamp(
          extra: [
            {
              'id': 'say',
              'type': 'text_command',
              'label': 'Say',
              'params': {
                'value': {'type': 'string'},
              },
            },
          ],
        ),
      ];
      await pumpApp(tester, engine);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semantics.dispose();
    });
  });
}
