import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/automation_view.dart';
import 'package:omniflow_engine/src/devices/wiz_pilot.dart';
import 'package:omniflow_engine/src/devices/wiz_scenes.dart';
import 'package:test/test.dart';

/// pywizlight's scenes.py: `SCENES` without Rhythm, the custom modes and
/// the TV sync ones, `TW_SCENES` and `DW_SCENES`.
const _pywizlight = {
  35: 'Alarm', 10: 'Bedtime', 29: 'Candlelight', 27: 'Christmas', //
  6: 'Cozy', 13: 'Cool white', 26: 'Club', 12: 'Daylight', //
  40: 'Dim-to-warm', 33: 'Diwali', 23: 'Deep dive', 22: 'Fall', //
  5: 'Fireplace', 7: 'Forest', 15: 'Focus', 30: 'Golden white', //
  28: 'Halloween', 24: 'Jungle', 25: 'Mojito', 14: 'Night light', //
  1: 'Ocean', 4: 'Party', 31: 'Pulse', 8: 'Pastel colors', //
  19: 'Plantgrowth', 2: 'Romance', 16: 'Relax', 36: 'Snowy sky', //
  3: 'Sunset', 20: 'Spring', 21: 'Summer', 32: 'Steampunk', //
  17: 'True colors', 18: 'TV time', 34: 'White', 9: 'Wake-up', //
  11: 'Warm white',
};
const _tw = [6, 9, 10, 11, 12, 13, 14, 15, 16, 18, 29, 30, 31, 32, 33, 35, 40];
const _dw = [9, 10, 14, 29, 31, 32, 34, 35];

/// The scenes an ESP25_SHRGB_01 on firmware 1.38 reports a speed for.
const _moving = [1, 2, 3, 4, 5, 7, 8, 20, 21, 22, 23, 24, 25, 26, 27, 28];
const _movingToo = [30, 31, 32, 33, 36];

Map<String, Object?> _pilot(Map<String, Object?> p) => {
  'id': 1,
  'method': 'setPilot',
  'params': p,
};

Matcher _fails(Object message) => throwsA(
  isA<CommandFailedException>().having((e) => e.message, 'message', message),
);

void main() {
  group('the scene list', () {
    test('has pywizlight ids and names, and no rhythm or sync scene', () {
      expect({for (final s in wizScenes) s.id: s.name}, _pywizlight);
      expect(wizScenes.map((s) => s.slug).toSet(), hasLength(37));
      expect(wizSceneById(wizRhythmId), isNull);
    });

    test('each bulb kind gets the scenes pywizlight gives its class', () {
      List<int> ids(String? kind) =>
          [for (final s in wizScenesFor(kind)) s.id]..sort();
      expect(ids('rgb'), [..._pywizlight.keys]..sort());
      expect(ids(null), ids('rgb'));
      expect(ids('white'), _tw);
      expect(ids('dimmable'), _dw);
      expect(ids('socket'), isEmpty);
    });

    test('a scene is dynamic exactly when a bulb reports its speed', () {
      expect(
        [
          for (final s in wizScenes)
            if (s.dynamic) s.id,
        ]..sort(),
        [..._moving, ..._movingToo],
      );
      expect(wizSceneBySlug('ocean')!.toChoice(), {
        'value': 'ocean',
        'label': 'Ocean',
        'group': 'dynamic',
        'groupLabel': 'Dynamic',
        'icon': 'waves',
        'takes': ['speed'],
      });
      expect(wizSceneBySlug('focus')!.toChoice()['group'], 'functional');
      expect(wizSceneBySlug('cozy')!.toChoice().containsKey('takes'), isFalse);
    });

    test('the driver offers exactly these scenes, by slug', () {
      final wiz = DriverRegistry.withBuiltIns()['philips_wiz_udp']!;
      final scene = wiz.capability('scene')!;
      expect(isWizSceneCapability(scene), isTrue);
      expect(scene.params['scene']!.values, [
        for (final s in wizScenes) s.slug,
      ]);
      expect(
        (scene.params['speed']!.min, scene.params['speed']!.max),
        (10, 200),
      );
    });

    test('a scene is found by slug, name or id', () {
      expect(wizSceneOf('night_light')!.id, 14);
      expect(wizSceneOf('Night light')!.id, 14);
      expect(wizSceneOf('Wake-up')!.id, 9);
      expect(wizSceneOf(1)!.slug, 'ocean');
      expect(wizSceneOf('1')!.slug, 'ocean');
      expect(wizSceneOf('nope'), isNull);
    });
  });

  group('scene, speed, colour and white params', () {
    const tw = WizBulb(kind: 'white', minK: 2700, maxK: 6500);
    const rgb = WizBulb(kind: 'rgb', minK: 2200, maxK: 6500);

    test('a scene goes by its id with its speed, a still one without', () {
      expect(
        fitWizPilot(
          _pilot({'state': true, 'sceneId': 'ocean', 'speed': 150}),
          rgb,
          'L',
        )['params'],
        {'state': true, 'sceneId': 1, 'speed': 150},
      );
      expect(
        fitWizPilot(
          _pilot({'sceneId': 'warm_white', 'speed': 100, 'dimming': 50}),
          tw,
          'L',
        )['params'],
        {'sceneId': 11, 'dimming': 50},
      );
      expect(
        fitWizPilot(_pilot({'sceneId': 'party', 'speed': 500}), rgb, 'L'),
        containsPair('params', {'sceneId': 4, 'speed': 200}),
      );
      expect(fitWizPilot(_pilot({'sceneId': 257}), rgb, 'L')['params'], {
        'sceneId': 257,
      });
    });

    test('refuses in plain words a scene the bulb does not play', () {
      expect(
        () => fitWizPilot(_pilot({'sceneId': 'ocean'}), tw, 'Lamp'),
        _fails('Lamp is a tunable white bulb and does not play Ocean'),
      );
      expect(
        () => fitWizPilot(
          _pilot({'sceneId': 'focus'}),
          const WizBulb(kind: 'dimmable'),
          'Lamp',
        ),
        _fails('Lamp is a white bulb and does not play Focus'),
      );
      expect(
        () => fitWizPilot(_pilot({'sceneId': 1000}), rgb, 'Lamp'),
        _fails(contains('Rhythm follows the sound the WiZ app hears')),
      );
      expect(
        () => fitWizPilot(_pilot({'sceneId': 'disco'}), tw, 'Lamp'),
        _fails(startsWith('Lamp has no scene disco. Pick one of daylight')),
      );
      expect(
        () => fitWizPilot(_pilot({'sceneId': 0}), rgb, 'Lamp'),
        _fails(contains('no scene 0')),
      );
    });

    test('white channels go with a colour, and alone light the bulb', () {
      expect(
        fitWizPilot(
          _pilot({'r': 255, 'g': 0, 'b': 80, 'c': 0, 'w': 0}),
          rgb,
          'L',
        )['params'],
        {'r': 255, 'g': 0, 'b': 80},
      );
      expect(
        fitWizPilot(
          _pilot({'r': 0, 'g': 0, 'b': 0, 'c': 300, 'w': 40.4}),
          rgb,
          'L',
        )['params'],
        {'r': 0, 'g': 0, 'b': 0, 'c': 255, 'w': 40},
      );
      expect(
        fitWizPilot(
          _pilot({'r': 0, 'g': 0, 'b': 0, 'c': 0, 'w': 0}),
          rgb,
          'L',
        )['method'],
        'setState',
      );
    });

    test('a colour with only white channels does not count as zero', () {
      final rgbCap = DriverRegistry.withBuiltIns()['philips_wiz_udp']!
          .capability('rgb')!;
      expect(rgbCap.asksForZero({'r': 0, 'g': 0, 'b': 0, 'w': 200}), isFalse);
      expect(rgbCap.asksForZero({'r': 0, 'g': 0, 'b': 0}), isTrue);
    });

    test('the per-bulb manifest narrows scenes, white channels and '
        'the lowest dimming on every brightness', () {
      final base = DriverRegistry.withBuiltIns()['philips_wiz_udp']!;
      DriverManifest of(Map<String, Object?> bulb) => wizManifestFor(
        base,
        Device(
          id: 'b',
          name: 'B',
          driverId: 'philips_wiz_udp',
          host: '127.0.0.1',
          settings: {wizBulbSetting: bulb},
        ),
      );
      final white = of({'kind': 'white', 'minK': 2700, 'maxK': 6500});
      expect(white.capability('scene')!.params['scene']!.values, [
        for (final s in wizScenesFor('white')) s.slug,
      ]);
      final colourOnly = of({'kind': 'rgb', 'minDim': 20});
      expect(
        colourOnly.capability('rgb')!.params.keys,
        unorderedEquals(['r', 'g', 'b', 'brightness']),
      );
      for (final id in ['brightness', 'rgb', 'scene']) {
        final spec = colourOnly
            .capability(id)!
            .params[id == 'brightness' ? 'value' : 'brightness']!;
        expect(spec.min, 20, reason: id);
      }
      final full = of({'kind': 'rgb', 'minK': 2200, 'maxK': 6500});
      expect(full.capability('rgb')!.params.keys, containsAll(['c', 'w']));
      expect(
        () => full.capability('scene')!.validateParams({'scene': 'disco'}),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.issues.single.path,
            'path',
            'params.scene',
          ),
        ),
      );
      expect(
        () => full.capability('scene')!.validateParams({
          'scene': 'ocean',
          'speed': 'fast',
        }),
        throwsA(isA<ValidationException>()),
      );
      expect(
        full.capability('scene')!.validateParams({
          'scene': 'ocean',
          'speed': 250,
        }),
        {'scene': 'ocean', 'speed': 200},
      );
      expect(of({'kind': 'socket'}).capability('scene'), isNull);
    });
  });

  group('state as a mode', () {
    test('a scene by name, winning over the white it reports with it', () {
      expect(
        wizModeOf({'state': true, 'sceneId': 1, 'speed': 150, 'dimming': 60}),
        {
          'kind': 'scene',
          'label': 'Ocean',
          'scene': 'ocean',
          'sceneId': 1,
          'dynamic': true,
          'speed': 150,
        },
      );
      expect(wizModeOf({'sceneId': 11, 'temp': 2700}), {
        'kind': 'scene',
        'label': 'Warm white',
        'scene': 'warm_white',
        'sceneId': 11,
        'dynamic': false,
      });
      expect(
        wizModeOf({'sceneId': 258, 'speed': 100})!['label'],
        'Custom mode 3',
      );
    });

    test('a colour, the white channels alone, and a white', () {
      expect(
        wizModeOf({'sceneId': 0, 'r': 255, 'g': 0, 'b': 160, 'c': 0, 'w': 0}),
        {
          'kind': 'colour',
          'label': 'Pink',
          'r': 255,
          'g': 0,
          'b': 160,
          'c': 0,
          'w': 0,
        },
      );
      expect(
        wizModeOf({'r': 0, 'g': 0, 'b': 0, 'c': 0, 'w': 200})!['label'],
        'Warm white',
      );
      expect(wizModeOf({'sceneId': 0, 'temp': 6500}), {
        'kind': 'white',
        'label': 'Cool white 6500 K',
        'temp': 6500,
      });
      expect(wizModeOf({'state': false}), isNull);
    });

    test('a sent pilot replaces the keys of the mode it leaves', () {
      final white = {'state': true, 'sceneId': 0, 'temp': 3000};
      final inScene = wizStateAfter(
        white,
        _pilot({'state': true, 'sceneId': 1, 'speed': 100, 'dimming': 60}),
      );
      expect(inScene, {
        'state': true,
        'sceneId': 1,
        'speed': 100,
        'dimming': 60,
      });
      expect(wizStateAfter(inScene, _pilot({'speed': 180})), {
        ...inScene,
        'speed': 180,
      });
      expect(wizStateAfter(inScene, _pilot({'r': 255, 'g': 0, 'b': 0})), {
        'state': true,
        'dimming': 60,
        'r': 255,
        'g': 0,
        'b': 0,
        'c': 0,
        'w': 0,
        'sceneId': 0,
      });
      expect(
        wizStateAfter(inScene, {
          'method': 'setState',
          'params': {'state': false},
        })['state'],
        isFalse,
      );
    });
  });

  group('sentences', () {
    final words = SentenceContext(
      names: const {'bedroom': 'Bedroom Light'},
      drivers: {'bedroom': DriverRegistry.withBuiltIns()['philips_wiz_udp']!},
    );

    test('scene, colour and white steps read as what they do', () {
      expect(
        words.action('bedroom.scene', {'scene': 'ocean'}),
        'Bedroom Light Ocean scene',
      );
      expect(
        words.action('bedroom.scene', {'scene': 'party', 'speed': 150}),
        'Bedroom Light Party scene, speed 150',
      );
      expect(
        words.action('bedroom.scene', {'scene': 'focus', 'speed': 150}),
        'Bedroom Light Focus scene',
      );
      expect(
        words.action('bedroom.rgb', {
          'r': 255,
          'g': 0,
          'b': 160,
          'brightness': 60,
        }),
        'Bedroom Light pink colour, brightness 60%',
      );
      expect(
        words.action('bedroom.rgb', {'r': 0, 'g': 0, 'b': 0, 'w': 200}),
        'Bedroom Light warm white',
      );
      expect(
        words.action('bedroom.color_temp', {'value': 2700}),
        'Bedroom Light warm white 2700 K',
      );
      expect(
        words.action('bedroom.brightness', {'value': 60}),
        'Bedroom Light brightness 60%',
      );
    });
  });
}
