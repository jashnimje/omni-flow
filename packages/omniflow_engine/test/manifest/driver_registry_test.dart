import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../../tool/embed_drivers.dart';

void main() {
  test('the embedded built-ins match drivers/ (run tool/embed_drivers.dart if not)', () {
    expect(
      File(outputPath).readAsStringSync(),
      generateBuiltInDrivers(Directory(driversDir)),
    );
  });

  group('built-in WiZ driver', () {
    final wiz = DriverRegistry.withBuiltIns()['philips_wiz_udp']!;
    const renderer = TemplateRenderer();

    test('loads with its transport, discovery and capabilities', () {
      expect(wiz.transport.port, 38899);
      expect(wiz.transport.listenPort, 38900);
      expect(wiz.discovery.single.method, 'udp_broadcast');
      expect(wiz.capabilities.map((c) => c.id), [
        'power',
        'brightness',
        'color_temp',
        'rgb',
      ]);
      expect(wiz.isHighRisk, isFalse);
    });

    test('color_temp renders params over the current state', () {
      final cap = wiz.capability('color_temp')!;
      final params = cap.validateParams({'value': 3000, 'brightness': 80});
      final out = renderer.render(
        cap.command,
        TemplateContext(
          params: params,
          state: const {'dimming': 30, 'temp': 2700},
        ),
      );
      expect(out, {
        'id': 1,
        'method': 'setPilot',
        'params': {'state': true, 'temp': 3000, 'dimming': 80},
      });
    });

    test(
      'color_temp without brightness keeps the bulb at its current dimming',
      () {
        final cap = wiz.capability('color_temp')!;
        final out = renderer.render(
          cap.command,
          TemplateContext(
            params: cap.validateParams({'value': 4000}),
            state: const {'dimming': 30},
          ),
        ) as Map;
        expect((out['params'] as Map)['dimming'], 30);
      },
    );

    test('power renders a JSON boolean, not a string', () {
      final cap = wiz.capability('power')!;
      final out = renderer.render(
        cap.command,
        TemplateContext(params: cap.validateParams({'value': false})),
      );
      expect(out, {
        'id': 1,
        'method': 'setState',
        'params': {'state': false},
      });
    });

    test(
      'brightness below the bulb minimum is rejected before anything is sent',
      () {
        expect(
          () => wiz.capability('brightness')!.validateParams({'value': 5}),
          throwsA(isA<ValidationException>()),
        );
      },
    );
  });

  group('user manifests', () {
    Map<String, Object?> manifest(String id) => {
      'schemaVersion': 1,
      'id': id,
      'name': 'Custom',
      'category': 'misc',
      'transport': {'type': 'http'},
      'capabilities': [
        {
          'id': 'ping',
          'type': 'action',
          'command': {'path': '/ping'},
        },
      ],
    };

    test('register, look up, list and unregister', () {
      final registry = DriverRegistry.withBuiltIns();
      registry.register(manifest('my_gadget'));
      expect(registry['my_gadget']!.name, 'Custom');
      expect(registry.isBuiltIn('my_gadget'), isFalse);
      expect(
        registry.all.map((m) => m.id),
        containsAll(['philips_wiz_udp', 'my_gadget']),
      );
      expect(registry.unregister('my_gadget'), isTrue);
      expect(registry['my_gadget'], isNull);
    });

    test('cannot take a built-in id', () {
      expect(
        () =>
            DriverRegistry.withBuiltIns().register(manifest('philips_wiz_udp')),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a broken built-in fails loudly', () {
      expect(
        () => DriverRegistry.withBuiltIns(
          sources: {'bad.omni_driver.json': '{}'},
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
