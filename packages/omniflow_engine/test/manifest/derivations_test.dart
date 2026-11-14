import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/manifest/derivations.dart';
import 'package:test/test.dart';

Map<String, Object?> lightManifest(Map<String, Object?> capability) => {
  'schemaVersion': 1,
  'id': 'test_light',
  'name': 'Test light',
  'category': 'lighting',
  'transport': {'type': 'http', 'port': 80},
  'capabilities': [capability],
};

List<String> issuesOf(Map<String, Object?> json) {
  try {
    DriverManifest.parse(json);
    return const [];
  } on ValidationException catch (e) {
    return [for (final i in e.issues) '${i.path} ${i.message}'];
  }
}

void main() {
  group('Hue xy from RGB', () {
    // Expected values from an independent Python port of the same
    // conversion and clamp.
    test('white lands on the D65-ish white of the wide gamut matrix', () {
      expect(rgbToHueXy(255, 255, 255), [0.3227, 0.329]);
    });

    test('saturated primaries clamp to the gamut C corners', () {
      expect(rgbToHueXy(255, 0, 0), [0.6915, 0.3083]);
      expect(rgbToHueXy(0, 255, 0), [0.17, 0.7]);
      expect(rgbToHueXy(0, 0, 255), [0.1532, 0.0475]);
    });

    test('the gamut setting picks the triangle, lower case or not', () {
      expect(rgbToHueXy(0, 255, 0, gamut: 'a'), [0.2151, 0.7106]);
      expect(rgbToHueXy(0, 255, 0, gamut: 'nonsense'), [0.17, 0.7]);
    });

    test('a colour inside the gamut is not moved', () {
      expect(rgbToHueXy(255, 128, 0), [0.6081, 0.3709]);
    });

    test('black has no chromaticity and goes to the white point', () {
      expect(rgbToHueXy(0, 0, 0), [0.3127, 0.329]);
    });
  });

  group('Tuya HSV hex from RGB', () {
    test('primaries and white', () {
      expect(rgbToTuyaHsv(255, 0, 0), '000003e803e8');
      expect(rgbToTuyaHsv(0, 255, 0), '007803e803e8');
      expect(rgbToTuyaHsv(0, 0, 255), '00f003e803e8');
      expect(rgbToTuyaHsv(255, 255, 255), '0000000003e8');
    });

    test('a dim colour keeps its value, and black is the dimmest allowed', () {
      expect(rgbToTuyaHsv(128, 0, 0), '000003e801f6');
      expect(rgbToTuyaHsv(0, 0, 0), '00000000000a');
    });

    test('a brightness param sets the value', () {
      expect(rgbToTuyaHsv(255, 0, 0, brightness: 500), '000003e801f4');
    });
  });

  group('derive in a manifest', () {
    test('adds its outputs for the command, not as params', () {
      final manifest = DriverManifest.parse(
        lightManifest({
          'id': 'rgb',
          'type': 'color_rgb',
          'derive': 'hue_xy',
          'command': {
            'path': '/x',
            'body': {'xy': '{{xy}}'},
          },
        }),
      );
      final rgb = manifest.capability('rgb')!;
      expect(rgb.params.keys, isNot(contains('xy')));
      final params = rgb.validateParams({'r': 255, 'g': 0, 'b': 0});
      expect(rgb.withDerived(params, const {'gamut': 'A'})['xy'], [
        0.7004,
        0.2991,
      ]);
    });

    test('an unknown derivation is refused', () {
      expect(
        issuesOf(
          lightManifest({
            'id': 'rgb',
            'type': 'color_rgb',
            'derive': 'magic',
            'command': {'path': '/x'},
          }),
        ),
        [contains('must be one of hue_xy, tuya_hsv')],
      );
    });

    test('a derivation whose inputs are not params is refused', () {
      expect(
        issuesOf(
          lightManifest({
            'id': 'level',
            'type': 'level',
            'derive': ['tuya_hsv'],
            'command': {
              'path': '/x',
              'query': {'c': '{{hsv}}'},
            },
          }),
        ),
        contains(contains('reads r, g, b, which are not declared params')),
      );
    });

    test('a command reading an output it does not derive is refused', () {
      expect(
        issuesOf(
          lightManifest({
            'id': 'rgb',
            'type': 'color_rgb',
            'command': {
              'path': '/x',
              'query': {'c': '{{hsv}}'},
            },
          }),
        ),
        [contains('"hsv", which is not a declared param')],
      );
    });
  });

  group('alsoOff', () {
    test('reads more device words back as off', () {
      final manifest = DriverManifest.parse(
        lightManifest({
          'id': 'power',
          'type': 'toggle',
          'onOff': ['PowerOn', 'PowerOff'],
          'alsoOff': ['DisplayOff'],
          'command': {'path': '/keypress/{{value}}'},
        }),
      );
      final power = manifest.capability('power')!;
      expect(power.fromDevice('PowerOn'), true);
      expect(power.fromDevice('displayoff'), false);
      expect(power.fromDevice('Headless'), 'Headless');
      expect(power.toDevice(false), 'PowerOff');
    });

    test('needs onOff', () {
      expect(
        issuesOf(
          lightManifest({
            'id': 'power',
            'type': 'toggle',
            'alsoOff': ['DisplayOff'],
            'command': {'path': '/p'},
          }),
        ),
        [contains('alsoOff needs onOff')],
      );
    });
  });
}
