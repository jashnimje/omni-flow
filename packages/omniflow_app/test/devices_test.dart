import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/boards/board_page.dart';
import 'package:omniflow_app/ui/design/design.dart' show OmniButton;

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

    testWidgets('a device the engine marks as a board opens the board page', (
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
      await openDevicePage(tester, 'copied');
      expect(find.byType(BoardPage), findsOneWidget);
    });
  });

  group('reachability', () {
    testWidgets('an offline event shows the help until the device is heard', (
      tester,
    ) async {
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
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
      expect(find.text('Desk lamp offline'), findsOneWidget);
      await openDevicePage(tester, 'desk_lamp');
      expect(find.byKey(const ValueKey('offline-desk_lamp')), findsOneWidget);
    });

    testWidgets('a never-read state shows a dash, not off or the minimum', (
      tester,
    ) async {
      engine.devices = [FakeEngine.lamp(state: const {})];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      expect(find.text('Not read yet'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('slider-desk_lamp.brightness')),
            )
            .value,
        '-',
      );
      await tester.tap(find.byKey(const ValueKey('device-power-desk_lamp')));
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
      await openDevicePage(tester, 'desk_lamp');
      await tester.tap(find.byKey(const ValueKey('swatch-Red')));
      await tester.pump();
      expect(engine.callsOf('device.invoke').last.$2, {
        'id': 'desk_lamp',
        'capability': 'rgb',
        'params': {'r': 255, 'g': 107, 'b': 107},
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
      await openDevicePage(tester, 'desk_lamp');
      // The action is one row; its fields open in a sheet.
      await tester.ensureVisible(
        find.byKey(const ValueKey('desk_lamp.ir_nec')),
      );
      await tester.tap(find.byKey(const ValueKey('desk_lamp.ir_nec')));
      await tester.pumpAndSettle();
      final send = find.byKey(const ValueKey('params-run-IR'));
      expect(tester.widget<OmniButton>(send).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('param-address')), '4');
      await tester.enterText(
        find.byKey(const ValueKey('param-command')),
        '300',
      );
      await tester.pump();
      expect(find.text('Must be 0 to 255'), findsOneWidget);
      expect(tester.widget<OmniButton>(send).onPressed, isNull);
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
      await openDevicePage(tester, 'desk_lamp');
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
      await openDevicePage(tester, 'mac');
      expect(find.byKey(const ValueKey('high-risk-mac')), findsOneWidget);
      await tester.tap(find.text('Sleep display'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This runs a command on 192.168.1.20'),
        findsOneWidget,
      );
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
      final semantics = tester.ensureSemantics();
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      final slider = tester.getSemantics(
        find.byKey(const ValueKey('slider-desk_lamp.brightness')),
      );
      expect(slider.value, '30%');
      expect(slider.label, 'Brightness');
      semantics.dispose();
    });

    testWidgets(
      'the device page meets the tap target and contrast guidelines',
      (tester) async {
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
        await openDevicePage(tester, 'desk_lamp');
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        semantics.dispose();
      },
    );
  });
}
