import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/adb/adb_key.dart';
import 'package:test/test.dart';

import '../devices/adb/fake_adbd.dart';
import '../devices/fake_mdns.dart';
import '../devices/tv/fake_tvs.dart';

/// A loopback Hue bridge that refuses pairing until its link button is
/// "pressed".
class FakeHueBridge {
  FakeHueBridge._(this.server) {
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      pairings.add(body);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          buttonPressed
              ? [
                  {
                    'success': {'username': 'fixture-hue-user'},
                  },
                ]
              : [
                  {
                    'error': {
                      'type': 101,
                      'address': '',
                      'description': 'link button not pressed',
                    },
                  },
                ],
        ),
      );
      await request.response.close();
    });
  }

  static Future<FakeHueBridge> start() async =>
      FakeHueBridge._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer server;
  final pairings = <String>[];
  var buttonPressed = false;

  Future<void> close() => server.close(force: true);
}

void main() {
  late Directory home;
  late InMemorySecretStore secrets;
  late OmniEngine engine;
  late AdbHostKey adbKey;
  final loopback = InternetAddress.loopbackIPv4.address;

  setUpAll(() => adbKey = AdbHostKey.generateSync());

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_pairing');
    secrets = InMemorySecretStore();
    // A stored key, so the engine does not spend seconds generating one.
    await secrets.write(adbHostKeySecret, adbKey.toPem());
    engine = await OmniEngine.open(
      home: home,
      secrets: secrets,
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(String c, Map<String, Object?> a) async {
    final r = await engine.handle(c, a);
    expect(r['ok'], isTrue, reason: '$c: $r');
    return r;
  }

  Future<Map<String, Object?>> err(String c, Map<String, Object?> a) async {
    final r = await engine.handle(c, a);
    expect(r['ok'], isFalse, reason: '$c: $r');
    return Map<String, Object?>.from(r['error'] as Map);
  }

  group('ADB', () {
    late FakeAdbd adbd;

    setUp(() async {
      adbd = await FakeAdbd.start();
      await ok('device.add', {
        'id': 'tv',
        'driver': 'android_tv_adb',
        'host': loopback,
        'port': adbd.port,
      });
    });

    tearDown(() => adbd.close());

    test('device JSON says how to pair, before anything is sent', () async {
      final device = (await ok('device.get', {'id': 'tv'}))['device'] as Map;
      expect(device['pairing'], {
        'method': 'adb',
        'prompt': contains('Allow USB debugging?'),
      });
      expect(adbd.connections, 0);
    });

    test(
      'an invoke that may not pair fails with needs_user and offers no key',
      () async {
        final e = await err('device.invoke', {
          'id': 'tv',
          'capability': 'volume_up',
          'allowPairing': false,
        });
        expect(e['type'], 'needs_user');
        expect(e['message'], contains('omni device pair tv'));
        expect(adbd.offeredKeys, isEmpty, reason: 'no prompt on the TV');
        expect(adbd.commands, isEmpty);
      },
    );

    test('device.pair shows the prompt once, then signs silently', () async {
      final prompts = <Map<String, Object?>>[];
      final sub = engine.events
          .where((e) => e['event'] == 'device.pairingPrompt')
          .listen(prompts.add);
      addTearDown(sub.cancel);

      final first = await ok('device.pair', {'id': 'tv'});
      expect(first, containsPair('method', 'adb'));
      expect(first, containsPair('paired', true));
      expect(first, containsPair('prompted', true));
      expect(adbd.offeredKeys, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      expect(prompts.single['deviceId'], 'tv');

      final again = await ok('device.pair', {'id': 'tv'});
      expect(again, containsPair('prompted', false));
      expect(adbd.offeredKeys, hasLength(1));

      await ok('device.invoke', {
        'id': 'tv',
        'capability': 'volume_up',
        'allowPairing': false,
      });
      expect(adbd.commands.single, contains('input keyevent'));
    });

    test('an untrusted flow driving an unpaired TV offers no key', () async {
      final saved = await ok('flow.save', {
        'trusted': false,
        'flow': {
          'schemaVersion': 1,
          'id': 'louder',
          'name': 'Louder',
          'nodes': [
            {'id': 'go', 'type': 'manual'},
            {
              'id': 'up',
              'type': 'device_capability',
              'config': {'deviceId': 'tv', 'capabilityId': 'volume_up'},
            },
          ],
          'edges': [
            {
              'id': 'e',
              'from': {'node': 'go', 'port': 'out'},
              'to': {'node': 'up', 'port': 'in'},
            },
          ],
        },
      });
      expect(saved['approved'], isTrue, reason: 'ADB is not high risk');
      final run = await ok('flow.run', {'id': 'louder'});
      expect(jsonEncode(run), contains('omni device pair tv'));
      expect(adbd.offeredKeys, isEmpty, reason: 'no prompt on the TV');
      expect(adbd.commands, isEmpty);
    });

    test('a key the TV rejects comes back as pairing_failed', () async {
      adbd.prompt = KeyPrompt.reject;
      final e = await err('device.pair', {'id': 'tv'});
      expect(e['type'], 'pairing_failed');
      expect(e['message'], contains('Allow USB debugging?'));
    });
  });

  group('webOS', () {
    late FakeWebOsTv tv;

    setUp(() async {
      tv = await FakeWebOsTv.start();
      await ok('device.add', {
        'id': 'lg',
        'driver': 'lg_webos_tv',
        'host': loopback,
        'port': tv.port,
      });
    });

    tearDown(() => tv.close());

    test('an agent invoke never raises the TV prompt', () async {
      final e = await err('device.invoke', {
        'id': 'lg',
        'capability': 'mute',
        'params': {'value': true},
        'allowPairing': false,
      });
      expect(e['type'], 'needs_user');
      expect(tv.prompts, 0);
      expect(tv.requests, isEmpty, reason: 'nothing connected');
    });

    test('a flow toggling an unpaired TV never raises the prompt', () async {
      await ok('flow.save', {
        'trusted': true,
        'flow': {
          'schemaVersion': 1,
          'id': 'mute_tv',
          'name': 'Mute the TV',
          'nodes': [
            {'id': 'go', 'type': 'manual', 'config': {}},
            {
              'id': 'flip',
              'type': 'device_toggle',
              'config': {'deviceId': 'lg', 'capabilityId': 'mute'},
            },
          ],
          'edges': [
            {
              'id': 'e1',
              'from': {'node': 'go', 'port': 'out'},
              'to': {'node': 'flip', 'port': 'in'},
            },
          ],
        },
      });
      await engine.handle('flow.run', {'id': 'mute_tv'});
      expect(tv.prompts, 0);
      expect(tv.requests, isEmpty, reason: 'nothing connected');
    });

    test('an unattended state poll does not pair either', () async {
      await expectLater(
        engine.devices.refreshState('lg', allowPairing: false),
        throwsA(isA<PairingRequiredException>()),
      );
      expect(tv.prompts, 0);
    });

    test(
      'device.pair stores the client key, then invokes need no prompt',
      () async {
        final paired = await ok('device.pair', {'id': 'lg'});
        expect(paired, containsPair('newKey', true));
        expect(tv.prompts, 1);
        expect(
          await secrets.read(deviceSecretKey('lg', 'clientKey')),
          'fake-client-key-1',
        );
        expect(jsonEncode(paired), isNot(contains('fake-client-key')));

        await ok('device.invoke', {
          'id': 'lg',
          'capability': 'mute',
          'params': {'value': true},
          'allowPairing': false,
        });
        final again = await ok('device.pair', {'id': 'lg'});
        expect(again, containsPair('newKey', false));
        expect(tv.prompts, 1);

        // A key set by hand takes effect at once: the held connection is
        // dropped and the next command connects again with it.
        await ok('secret.set', {
          'deviceId': 'lg',
          'key': 'clientKey',
          'value': 'fake-client-key-1',
        });
        final connects = tv.requests.length;
        await ok('device.invoke', {
          'id': 'lg',
          'capability': 'mute',
          'params': {'value': false},
        });
        expect(tv.requests, hasLength(connects + 1));
      },
    );

    test(
      'a removed TV re-added under its id does not keep its session',
      () async {
        await ok('device.pair', {'id': 'lg'});
        await ok('device.invoke', {
          'id': 'lg',
          'capability': 'mute',
          'params': {'value': true},
          'allowPairing': false,
        });
        await ok('device.remove', {'id': 'lg'});
        await ok('device.add', {
          'id': 'lg',
          'driver': 'lg_webos_tv',
          'host': loopback,
          'port': tv.port,
        });
        final e = await err('device.invoke', {
          'id': 'lg',
          'capability': 'mute',
          'params': {'value': false},
          'allowPairing': false,
        });
        expect(e['type'], 'needs_user', reason: 'the new device has no key');
        expect(tv.prompts, 1);
      },
    );

    test('a refused prompt is pairing_failed, and pair asks again', () async {
      tv.rejectPairing = true;
      expect(
        (await err('device.pair', {'id': 'lg'}))['type'],
        'pairing_failed',
      );
      tv.rejectPairing = false;
      // device.pair is the user asking, so the refusal cooldown is skipped.
      await ok('device.pair', {'id': 'lg'});
      expect(tv.prompts, 2);
    });
  });

  group('Hue bridge', () {
    late FakeHueBridge bridge;

    setUp(() async {
      bridge = await FakeHueBridge.start();
      for (final (id, light) in [('desk', '1'), ('hall', '2')]) {
        await ok('device.add', {
          'id': id,
          'driver': 'philips_hue_light',
          'host': loopback,
          'port': bridge.server.port,
          'settings': {'lightId': light},
        });
      }
    });

    tearDown(() => bridge.close());

    test(
      'asks for the link button, then stores one username for every light',
      () async {
        final prompt =
            ((await ok('device.get', {'id': 'desk'}))['device']
                    as Map)['pairing']
                as Map;
        expect(prompt['method'], 'hue_bridge');
        expect(prompt['prompt'], contains('link button'));

        final refused = await err('device.pair', {'id': 'desk'});
        expect(refused['type'], 'pairing_failed');
        expect(refused['message'], contains('press the link button'));

        bridge.buttonPressed = true;
        final paired = await ok('device.pair', {'id': 'desk'});
        expect(paired['devices'], unorderedEquals(['desk', 'hall']));
        expect(jsonEncode(paired), isNot(contains('fixture-hue-user')));
        for (final id in ['desk', 'hall']) {
          expect(
            await secrets.read(deviceSecretKey(id, 'username')),
            'fixture-hue-user',
          );
        }
        expect(bridge.pairings.last, contains('omniflow#omniflow'));
      },
    );
  });

  test('Home Assistant pairing says which secret to store', () async {
    await ok('device.add', {
      'id': 'ha_lamp',
      'driver': 'home_assistant_entity',
      'host': loopback,
      'settings': {'entityId': 'light.lamp', 'domain': 'light'},
    });
    final before = await ok('device.pair', {'id': 'ha_lamp'});
    expect(before['paired'], isFalse);
    expect(before['message'], contains('long-lived access token'));
    expect(before['message'], contains('omni secret set ha_lamp token'));

    await ok('secret.set', {
      'deviceId': 'ha_lamp',
      'key': 'token',
      'value': 'fixture-ha-token',
    });
    final after = await ok('device.pair', {'id': 'ha_lamp'});
    expect(after['paired'], isTrue);
    expect(jsonEncode(after), isNot(contains('fixture-ha-token')));
  });

  test('a driver with nothing to pair is refused', () async {
    await ok('device.add', {
      'id': 'bulb',
      'driver': 'philips_wiz_udp',
      'host': loopback,
    });
    expect((await err('device.pair', {'id': 'bulb'}))['type'], 'invalid');
    final bulb = (await ok('device.get', {'id': 'bulb'}))['device'] as Map;
    expect(bulb.containsKey('pairing'), isFalse);
  });

  test('driver.list carries settings, pairing and board for UIs', () async {
    final drivers = {
      for (final d
          in ((await ok('driver.list', {}))['drivers'] as List).cast<Map>())
        d['id']: d,
    };
    expect(drivers['android_tv_adb']!['pairing'], 'adb');
    expect(drivers['samsung_tizen_tv']!['pairing'], 'tv');
    expect(drivers['philips_hue_light']!['pairing'], 'hue_bridge');
    expect(drivers['home_assistant_sensor']!['pairing'], 'secret');
    expect(drivers['omniflow_board']!['board'], isTrue);
    expect(drivers['place']!['icon'], 'place');
    expect(drivers['place']!['category'], 'presence');
    expect(drivers['tuya_plug']!['settings'], [
      {'key': 'devId', 'label': 'Device id', 'help': isA<String>()},
      {
        'key': 'localKey',
        'label': 'Local key',
        'secret': true,
        'help': contains('tinytuya'),
      },
      {
        'key': 'version',
        'label': 'Tuya protocol version: 3.3 (the default), 3.4 or 3.5',
        'help': isA<String>(),
      },
    ]);
  });
}
