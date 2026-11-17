import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/error_of.dart';
import 'package:omniflow_engine/src/devices/wiz_learner.dart';
import 'package:omniflow_engine/src/devices/wiz_pilot.dart';
import 'package:test/test.dart';

import '../support/fake_wiz_bulb.dart';

const _key = '00112233445566778899aabbccddeeff';

void main() {
  group('signing', () {
    test('the HMAC matches pywizlight for a fixed params object and key', () {
      // Python: base64(hmac.new(bytes.fromhex(key), json.dumps(params,
      // separators=(",", ":")).encode(), sha256).digest())
      final params = {
        'state': true,
        'dimming': 50,
        'temp': 2700,
        'sigTs': 1763380000,
      };
      expect(
        wizJson(params),
        '{"state":true,"dimming":50,"temp":2700,"sigTs":1763380000}',
      );
      expect(
        wizHmac(_key, params),
        'a1ksSkwMh7fL3p8eLjIKY8jZScEPohrCI281ZMVvglM=',
      );
    });

    test('a signed request has sigTs in params and env and hmac on top', () {
      final signed = signWizRequest(
        {
          'id': 1,
          'method': 'setPilot',
          'params': {'state': true, 'dimming': 50, 'temp': 2700},
        },
        _key,
        timestamp: 1763380000,
      );
      expect(signed, {
        'method': 'setPilot',
        'env': 'pro',
        'params': {
          'state': true,
          'dimming': 50,
          'temp': 2700,
          'sigTs': 1763380000,
        },
        'hmac': 'a1ksSkwMh7fL3p8eLjIKY8jZScEPohrCI281ZMVvglM=',
      });
    });

    test('a signed reply is checked over its result', () {
      expect(
        wizReplyVerified({
          'method': 'setPilot',
          'env': 'pro',
          'result': {'success': true},
          'hmac': 'jGzqcl2l72mRLFFtpFzvpOuJaDZePDO6SOhHmkFgNcA=',
        }, _key),
        isTrue,
      );
      expect(
        wizReplyVerified({
          'result': {'success': true},
          'hmac': 'AAAA',
        }, _key),
        isFalse,
      );
      expect(wizReplyVerified({'result': {}}, _key), isNull);
    });

    test('text outside ASCII is escaped as Python writes it', () {
      expect(
        wizJson({"n": "caf\u00e9", "q": "a\"b"}),
        r'{"n":"caf\u00e9","q":"a\"b"}',
      );
    });
  });

  group('what a bulb is', () {
    test('module names and ranges give the kind and white range', () {
      final rgb = WizBulb.from(
        system: {'moduleName': 'ESP25_SHRGB_01'},
        model: {
          'cctRange': [2200, 2700, 6500, 6500],
          'minDimLevel': 10,
        },
      );
      expect(rgb.toJson(), {
        'module': 'ESP25_SHRGB_01',
        'kind': 'rgb',
        'minK': 2200,
        'maxK': 6500,
        'minDim': 10,
      });
      expect(
        WizBulb.from(
          system: {
            'moduleName': 'ESP56_SHTW3_01',
            'whiteRange': [2700, 6500],
          },
        ).kind,
        'white',
      );
      final dw = WizBulb.from(
        system: {
          'moduleName': 'ESP06_SHDW9_01',
          'whiteRange': [2700, 2700],
        },
      );
      expect((dw.kind, dw.hasWhite, dw.hasColour), ('dimmable', false, false));
      final rgbOnly = WizBulb.from(system: {'moduleName': 'ESP25_SHRGB_01'});
      expect((rgbOnly.hasWhite, rgbOnly.hasColour), (false, true));
      expect(WizBulb.from(system: {}).kind, isNull);
    });

    test(
      'the per-bulb manifest hides what the bulb lacks and narrows white',
      () {
        final base = DriverRegistry.withBuiltIns()['philips_wiz_udp']!;
        Device bulb(Map<String, Object?> b) => Device(
          id: 'b',
          name: 'B',
          driverId: 'philips_wiz_udp',
          host: '127.0.0.1',
          settings: {wizBulbSetting: b},
        );
        List<String> ids(DriverManifest m) => [
          for (final c in m.capabilities) c.id,
        ];
        expect(ids(wizManifestFor(base, bulb({'kind': 'dimmable'}))), [
          'power',
          'brightness',
          'scene',
        ]);
        expect(
          ids(
            wizManifestFor(
              base,
              bulb({'kind': 'white', 'minK': 2700, 'maxK': 6500}),
            ),
          ),
          ['power', 'brightness', 'color_temp', 'scene'],
        );
        expect(ids(wizManifestFor(base, bulb({'kind': 'rgb'}))), [
          'power',
          'brightness',
          'rgb',
          'scene',
        ]);
        expect(ids(wizManifestFor(base, bulb({'kind': 'socket'}))), ['power']);
        final white = wizManifestFor(
          base,
          bulb({'kind': 'white', 'minK': 2700, 'maxK': 6500}),
        );
        final temp = white.capability('color_temp')!.params['value']!;
        expect((temp.min, temp.max, temp.clamp), (2700, 6500, true));
        expect(
          wizManifestFor(
            base,
            Device(id: 'x', name: 'x', driverId: 'philips_wiz_udp', host: 'h'),
          ),
          same(base),
        );
      },
    );
  });

  group('fitting a pilot', () {
    Map<String, Object?> pilot(Map<String, Object?> p) => {
      'id': 1,
      'method': 'setPilot',
      'params': p,
    };
    const tw = WizBulb(kind: 'white', minK: 2700, maxK: 6500);

    test('rounds and clamps dimming, white and colour', () {
      expect(
        fitWizPilot(
          pilot({'state': true, 'dimming': 5.6, 'temp': 2200}),
          tw,
          'L',
        )['params'],
        {'state': true, 'dimming': 10, 'temp': 2700},
      );
      expect(
        fitWizPilot(
          pilot({'r': 300.4, 'g': -2, 'b': 12.5, 'dimming': 140}),
          const WizBulb(kind: 'rgb'),
          'L',
        )['params'],
        {'r': 255, 'g': 0, 'b': 13, 'dimming': 100},
      );
    });

    test('zero brightness and an all-zero colour become power off', () {
      final off = {
        'id': 1,
        'method': 'setState',
        'params': {'state': false},
      };
      expect(fitWizPilot(pilot({'dimming': 0}), null, 'L'), off);
      expect(
        fitWizPilot(pilot({'r': 0, 'g': 0, 'b': 0, 'dimming': 50}), null, 'L'),
        off,
      );
    });

    test('says plainly what the bulb cannot do', () {
      expect(
        () => fitWizPilot(pilot({'r': 255, 'g': 0, 'b': 0}), tw, 'Lamp'),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            'Lamp is a white bulb and has no colours',
          ),
        ),
      );
      expect(
        () => fitWizPilot(
          pilot({'temp': 3000}),
          const WizBulb(kind: 'rgb'),
          'Lamp',
        ),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('only colours'),
          ),
        ),
      );
      expect(
        () => fitWizPilot(pilot({'sceneId': 99}), null, 'Lamp'),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('no scene 99'),
          ),
        ),
      );
    });
  });

  group('over loopback', () {
    late InMemoryDeviceStore store;
    late InMemorySecretStore secrets;
    late UdpTransport udp;
    final bulbs = <FakeWizBulb>[];

    setUp(() async {
      store = InMemoryDeviceStore();
      secrets = InMemorySecretStore();
      udp = await UdpTransport.bind();
    });
    tearDown(() {
      udp.close();
      for (final b in bulbs) {
        b.close();
      }
      bulbs.clear();
    });

    Future<FakeWizBulb> bulb(
      String module, {
      List<int>? range,
      String? key,
      bool methodInErrors = true,
      DateTime Function()? bulbNow,
    }) async {
      final b = await FakeWizBulb.start(
        module: module,
        range: range,
        key: key,
        now: bulbNow,
        methodInErrors: methodInErrors,
      );
      bulbs.add(b);
      await store.put(
        Device(
          id: 'lamp',
          name: 'Lamp',
          driverId: 'philips_wiz_udp',
          host: b.host,
          port: b.port,
          state: const {'state': true, 'dimming': 60},
        ),
      );
      return b;
    }

    DeviceService service({DateTime Function()? clock}) => DeviceService(
      registry: DriverRegistry.withBuiltIns(),
      store: store,
      channels: {
        TransportType.udp: UdpJsonChannel(udp, secrets: secrets, clock: clock),
      },
    );

    Future<void> learn(DeviceService s) =>
        WizLearner(s, DriverRegistry.withBuiltIns()).learn('lamp');

    for (final (module, range) in [
      ('ESP56_SHTW3_01', [2700, 6500]),
      ('ESP01_SHRGB1C_31', [2200, 6500]),
    ]) {
      test(
        '$module $range takes every value once fitted to its range',
        () async {
          final b = await bulb(module, range: range);
          final s = service();
          await learn(s);
          await s.invoke('lamp', 'color_temp', {
            'value': 2000,
            'brightness': 5,
          });
          expect(b.pilot['temp'], range[0]);
          expect(b.pilot['dimming'], 10);
          await s.invoke('lamp', 'color_temp', {'value': 9000.4});
          expect(b.pilot['temp'], range[1]);
          await s.invoke('lamp', 'brightness', {'value': 55.5});
          expect(b.pilot['dimming'], 56);
          await s.invoke('lamp', 'brightness', {'value': 0});
          expect(b.pilot['state'], false);
          final device = (await s.device('lamp'))!;
          final m = manifestFor(DriverRegistry.withBuiltIns(), device)!;
          expect(m.capability('color_temp')!.params['value']!.min, range[0]);
          expect(m.capability('rgb') != null, module.contains('RGB'));
        },
      );
    }

    test(
      'a white-only bulb has no colour and a colour-only one no white',
      () async {
        await bulb('ESP06_SHDW9_01', range: [2700, 2700]);
        final s = service();
        await learn(s);
        final m = manifestFor(
          DriverRegistry.withBuiltIns(),
          (await s.device('lamp'))!,
        )!;
        expect(
          [for (final c in m.capabilities) c.id],
          ['power', 'brightness', 'scene'],
        );
        await expectLater(
          s.invoke('lamp', 'rgb', {'r': 255, 'g': 0, 'b': 0}),
          throwsA(isA<DeviceNotFoundException>()),
        );
      },
    );

    test(
      'an all-zero colour turns an RGB bulb off instead of failing',
      () async {
        final b = await bulb('ESP25_SHRGB_01');
        final s = service();
        await learn(s);
        await s.invoke('lamp', 'rgb', {'r': 0, 'g': 0, 'b': 0});
        expect(b.pilot['state'], false);
        expect(b.requests.last['method'], 'setState');
      },
    );

    test(
      'an unknown bulb that refuses a white says so in plain words, at once',
      () async {
        final b = await bulb(
          'ESP56_SHTW3_01',
          range: [2700, 6500],
          methodInErrors: false,
        );
        final s = service();
        final started = DateTime.now();
        await expectLater(
          s.invoke('lamp', 'color_temp', {'value': 2200}),
          throwsA(
            isA<CommandFailedException>().having(
              (e) => e.message,
              'message',
              'Lamp did not take brightness 60 %, white 2200 K. WiZ bulbs take '
                  'brightness 10 to 100 % and white within their own range',
            ),
          ),
        );
        // Refused, not retried until the timeout.
        expect(
          DateTime.now().difference(started).inMilliseconds,
          lessThan(400),
        );
        expect(b.requests, hasLength(1));
      },
    );

    test('a pro bulb refusing unsigned writes asks for the home key', () async {
      final b = await bulb('ESP25_SHRGB_01', range: [2200, 6500], key: _key);
      final s = service();
      Object? error;
      try {
        await s.invoke('lamp', 'power', {'value': true});
      } catch (e) {
        error = e;
      }
      expect(error, isA<SecretNeededException>());
      expect(apiErrorOf(error!).type, 'needs_user');
      expect(apiErrorOf(error).message, contains('udp_signing_key'));
      expect((await s.device('lamp'))!.settings[setupNeedsSetting], [
        'signingKey',
      ]);
      expect(b.requests.single.containsKey('hmac'), isFalse);
    });

    test('with the key every write is signed and taken', () async {
      final b = await bulb('ESP25_SHRGB_01', range: [2200, 6500], key: _key);
      await secrets.write(deviceSecretKey('lamp', 'signingKey'), _key);
      final s = service();
      await s.invoke('lamp', 'color_temp', {'value': 2200, 'brightness': 40});
      expect(b.pilot, containsPair('temp', 2200));
      final sent = b.requests.last;
      expect(sent['env'], 'pro');
      expect(sent.containsKey('id'), isFalse);
      await s.refreshState('lamp');
      expect(b.requests.last.containsKey('hmac'), isFalse);
    });

    test('a wrong key or a stale signature is a refused key', () async {
      await bulb('ESP25_SHRGB_01', key: _key);
      await secrets.write(
        deviceSecretKey('lamp', 'signingKey'),
        'ffeeddccbbaa99887766554433221100',
      );
      await expectLater(
        service().invoke('lamp', 'power', {'value': true}),
        throwsA(
          isA<SecretRejectedException>().having(
            (e) => e.message,
            'message',
            contains('is wrong'),
          ),
        ),
      );
      await secrets.write(deviceSecretKey('lamp', 'signingKey'), _key);
      await expectLater(
        service(
          clock: () => DateTime.now().subtract(const Duration(seconds: 60)),
        ).invoke('lamp', 'power', {'value': true}),
        throwsA(isA<SecretRejectedException>()),
      );
    });
  });
}
