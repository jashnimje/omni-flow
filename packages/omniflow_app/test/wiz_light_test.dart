import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/ui/automations/form_parts.dart';
import 'package:omniflow_app/ui/automations/scenes.dart';
import 'package:omniflow_app/ui/devices/device_text.dart';

import 'automations_fixtures.dart';
import 'fake_engine.dart';

Json _choice(String value, String label, String group, String icon) => {
  'value': value,
  'label': label,
  'group': group,
  'groupLabel': '${group[0].toUpperCase()}${group.substring(1)}',
  'icon': icon,
  if (group == 'dynamic') 'takes': ['speed'],
};

/// Scene choices as `device.list` gives them for a colour bulb, a few of
/// each group.
final _choices = [
  _choice('daylight', 'Daylight', 'functional', 'sunny'),
  _choice('focus', 'Focus', 'functional', 'center_focus_strong'),
  _choice('warm_white', 'Warm white', 'static', 'wb_incandescent'),
  _choice('ocean', 'Ocean', 'dynamic', 'waves'),
  _choice('party', 'Party', 'dynamic', 'celebration'),
];

/// A WiZ colour bulb as the engine lists it with capabilities.
Json _bulb({
  Json state = const {'state': true, 'dimming': 60, 'sceneId': 1},
  Json? mode = const {
    'kind': 'scene',
    'label': 'Ocean',
    'scene': 'ocean',
    'sceneId': 1,
    'dynamic': true,
    'speed': 150,
  },
  bool colour = true,
  int minK = 2200,
}) => {
  'id': 'bedroom',
  'name': 'Bedroom Light',
  'driver': 'philips_wiz_udp',
  'host': '192.168.1.41',
  'room': 'Bedroom',
  'settings': const <String, Object?>{},
  'state': state,
  'mode': ?mode,
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'stateKey': 'state',
      'params': {
        'value': {'type': 'boolean'},
      },
    },
    {
      'id': 'brightness',
      'type': 'level',
      'label': 'Brightness',
      'stateKey': 'dimming',
      'params': {
        'value': {'type': 'number', 'min': 10, 'max': 100, 'unit': '%'},
      },
    },
    {
      'id': 'color_temp',
      'type': 'color_temp',
      'label': 'White temperature',
      'stateKey': 'temp',
      'params': {
        'value': {'type': 'number', 'min': minK, 'max': 6500, 'unit': 'K'},
        'brightness': {
          'type': 'number',
          'min': 10,
          'max': 100,
          'optional': true,
        },
      },
    },
    if (colour)
      {
        'id': 'rgb',
        'type': 'color_rgb',
        'label': 'Colour',
        'params': {
          for (final k in ['r', 'g', 'b'])
            k: {'type': 'number', 'min': 0, 'max': 255, 'integer': true},
          for (final k in ['c', 'w'])
            k: {
              'type': 'number',
              'min': 0,
              'max': 255,
              'integer': true,
              'optional': true,
            },
        },
      },
    {
      'id': 'scene',
      'type': 'action',
      'label': 'Scene',
      'params': {
        'scene': {
          'type': 'enum',
          'values': [for (final c in _choices) c['value']],
          'choices': _choices,
        },
        'speed': {
          'type': 'number',
          'min': 10,
          'max': 200,
          'integer': true,
          'optional': true,
        },
        'brightness': {
          'type': 'number',
          'min': 10,
          'max': 100,
          'integer': true,
          'optional': true,
        },
      },
    },
  ],
};

void main() {
  late FakeEngine engine;

  setUp(() => engine = FakeEngine());

  Json lastInvoke() => engine.callsOf('device.invoke').last.$2;

  group('the device page', () {
    testWidgets('a bulb in a moving scene opens on its scenes, lit, with '
        'the speed, and a tap sets another', (tester) async {
      engine.devices = [_bulb()];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'bedroom');
      expect(find.byKey(const ValueKey('light-mode-bedroom')), findsOneWidget);
      expect(find.text('Ocean · Bedroom'), findsOneWidget);
      expect(find.byKey(const ValueKey('scene-ocean')), findsOneWidget);
      expect(find.byKey(const ValueKey('scene-party')), findsOneWidget);
      // Only the dynamic group shows, the one the active scene is in.
      expect(find.byKey(const ValueKey('scene-focus')), findsNothing);
      final speed = find.byKey(const ValueKey('slider-bedroom.scene.speed'));
      expect(speed, findsOneWidget);
      expect(tester.getSemantics(speed).value, '150%');
      await tester.tap(find.byKey(const ValueKey('scene-party')));
      await tester.pump();
      expect(lastInvoke(), {
        'id': 'bedroom',
        'capability': 'scene',
        'params': {'scene': 'party'},
      });
      await tester.tap(find.text('Functional'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scene-focus')));
      await tester.pump();
      expect(lastInvoke()['params'], {'scene': 'focus'});
      // The scene capability is not listed again under Actions.
      expect(find.text('Actions'), findsNothing);
    });

    testWidgets('the speed shows only while the scene moves', (tester) async {
      engine.devices = [
        _bulb(
          mode: const {
            'kind': 'scene',
            'label': 'Focus',
            'scene': 'focus',
            'sceneId': 15,
            'dynamic': false,
          },
        ),
      ];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'bedroom');
      expect(find.byKey(const ValueKey('scene-focus')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('slider-bedroom.scene.speed')),
        findsNothing,
      );
    });

    testWidgets('white has the warmth and the presets inside the bulb\'s '
        'range', (tester) async {
      engine.devices = [
        _bulb(
          state: const {'state': true, 'dimming': 60, 'temp': 2700},
          mode: const {
            'kind': 'white',
            'label': 'Warm white 2700 K',
            'temp': 2700,
          },
          minK: 2700,
        ),
      ];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'bedroom');
      expect(
        find.byKey(const ValueKey('slider-bedroom.color_temp')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('white-2200')), findsNothing);
      expect(find.byKey(const ValueKey('scene-ocean')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('white-6500')));
      await tester.pump();
      expect(lastInvoke(), {
        'id': 'bedroom',
        'capability': 'color_temp',
        'params': {'value': 6500},
      });
    });

    testWidgets('colour has swatches, the wheel and the white channels', (
      tester,
    ) async {
      engine.devices = [_bulb()];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'bedroom');
      await tester.tap(find.text('Colour'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('swatch-Deep blue')));
      await tester.pump();
      expect(lastInvoke()['params'], {'r': 0, 'g': 0, 'b': 255});
      final wheel = find.byKey(const ValueKey('colour-wheel'));
      // The wheel's right edge is red at full saturation.
      await tester.tapAt(tester.getCenter(wheel) + const Offset(100, 0));
      await tester.pump();
      final picked = lastInvoke()['params'] as Map;
      expect(picked['r'], 255);
      expect(picked['b'], lessThan(40));
      final warm = find.byKey(const ValueKey('slider-bedroom.rgb.w'));
      expect(warm, findsOneWidget);
      expect(
        find.byKey(const ValueKey('slider-bedroom.rgb.c')),
        findsOneWidget,
      );
      await tester.tapAt(tester.getTopRight(warm) + const Offset(-2, 24));
      await tester.pump();
      final white = lastInvoke()['params'] as Map;
      expect(white, containsPair('c', 0));
      expect([white['r'], white['g'], white['b']], [0, 0, 0]);
      expect(white['w'], greaterThan(250));
    });

    testWidgets('a white-only bulb offers white and scenes, no colour', (
      tester,
    ) async {
      engine.devices = [_bulb(colour: false, mode: null)];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'bedroom');
      expect(find.text('Scenes'), findsOneWidget);
      expect(find.byKey(const ValueKey('swatch-Red')), findsNothing);
      expect(find.byKey(const ValueKey('colour-wheel')), findsNothing);
    });
  });

  group('state words', () {
    test('a light in a scene reads On, the scene, then its brightness', () {
      expect(stateLine(DeviceView(_bulb())), 'On · Ocean · 60%');
      expect(
        rowSubtitle(DeviceView(_bulb()), 'Philips WiZ Light'),
        'Philips WiZ Light · On · Ocean · 60%',
      );
      expect(
        stateLine(DeviceView(_bulb(state: const {'state': false}))),
        'Off',
      );
    });
  });

  group('the step editor', () {
    Future<void> pumpForm(
      WidgetTester tester,
      Map<String, Json> params,
      Json values,
    ) => pumpPage(
      tester,
      engine,
      Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (context, setState) => ParamControls(
              params: params,
              values: values,
              onChanged: () => setState(() {}),
            ),
          ),
        ),
      ),
    );

    Map<String, Json> paramsOf(String capability) => {
      for (final e
          in ((_bulb()['capabilities'] as List).cast<Map>().singleWhere(
                    (c) => c['id'] == capability,
                  )['params']
                  as Map)
              .entries)
        '${e.key}': Map<String, Object?>.from(e.value as Map),
    };

    testWidgets('a scene step picks from the grid, and asks for a speed '
        'only for a moving scene', (tester) async {
      final values = <String, Object?>{};
      await pumpForm(tester, paramsOf('scene'), values);
      expect(find.byKey(const ValueKey('scene-daylight')), findsOneWidget);
      expect(find.byKey(const ValueKey('param-speed')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('scene-daylight')));
      await tester.pumpAndSettle();
      expect(values['scene'], 'daylight');
      expect(find.byKey(const ValueKey('param-speed')), findsNothing);
      await tester.tap(find.text('Dynamic'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scene-ocean')));
      await tester.pumpAndSettle();
      expect(values['scene'], 'ocean');
      expect(find.byKey(const ValueKey('param-speed')), findsOneWidget);
      expect(
        ParamControls.complete(paramsOf('scene'), values),
        containsPair('scene', 'ocean'),
      );
    });

    testWidgets('a colour step is picked on swatches and the wheel, with '
        'the white channels by name', (tester) async {
      final values = <String, Object?>{};
      await pumpForm(tester, paramsOf('rgb'), values);
      expect(find.byKey(const ValueKey('param-colour')), findsOneWidget);
      expect(find.byKey(const ValueKey('param-r')), findsNothing);
      expect(find.text('Warm white (optional)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('swatch-Deep red')));
      await tester.pumpAndSettle();
      expect(values, {'r': 255, 'g': 0, 'b': 0});
    });

    testWidgets('a white step has the presets', (tester) async {
      final values = <String, Object?>{};
      await pumpForm(tester, paramsOf('color_temp'), values);
      await tester.tap(find.byKey(const ValueKey('white-2700')));
      await tester.pumpAndSettle();
      expect(values['value'], 2700);
    });

    testWidgets('a scene step is saved and reads as the scene it sets', (
      tester,
    ) async {
      engine.devices = [_bulb()];
      engine.answers['scene.save'] = {'ok': true, 'id': 'calm'};
      await pumpPushed(tester, engine, const SceneEditorPage());
      await tester.enterText(find.byKey(const ValueKey('scene-name')), 'Calm');
      await tester.pump();
      await tapText(tester, 'Add an action');
      await tapKey(tester, 'pick-device-bedroom');
      await tapKey(tester, 'act-scene');
      await tester.tap(find.text('Dynamic'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'scene-ocean');
      await tapKey(tester, 'form-done');
      expect(find.text('Bedroom Light · Ocean scene'), findsOneWidget);
      await tapKey(tester, 'scene-save');
      expect(
        (engine.callsOf('scene.save').single.$2['actions'] as List).single,
        {
          'do': 'bedroom.scene',
          'params': {'scene': 'ocean'},
        },
      );
    });
  });
}
