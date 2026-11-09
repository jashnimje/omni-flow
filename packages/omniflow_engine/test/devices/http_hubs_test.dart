import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/src/devices/channels.dart';
import 'package:omniflow_engine/src/devices/device.dart';
import 'package:omniflow_engine/src/devices/device_service.dart';
import 'package:omniflow_engine/src/devices/http_channel.dart';
import 'package:omniflow_engine/src/manifest/built_in_drivers.g.dart';
import 'package:omniflow_engine/src/manifest/driver_manifest.dart';
import 'package:omniflow_engine/src/manifest/driver_registry.dart';
import 'package:omniflow_engine/src/manifest/validation.dart';
import 'package:omniflow_engine/src/storage/secret_store.dart';
import 'package:omniflow_engine/src/template/template_renderer.dart';
import 'package:omniflow_engine/src/transports/packet_tap.dart';
import 'package:test/test.dart';

const _hubDrivers = [
  'philips_hue_light.omni_driver.json',
  'home_assistant_entity.omni_driver.json',
  'home_assistant_sensor.omni_driver.json',
];

/// The repo's hub drivers, read from drivers/ so these tests do not depend on
/// the embedded copy being regenerated first.
Map<String, String> _hubSources() => {
  for (final name in _hubDrivers)
    name: File('../../drivers/$name').readAsStringSync(),
};

DriverRegistry _registry() =>
    DriverRegistry.withBuiltIns(sources: _hubSources());

class _Seen {
  _Seen(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final Object? body;
}

/// A loopback Hue bridge speaking the v1 REST API.
class FakeHueBridge {
  FakeHueBridge._(this._server) {
    _server.listen((req) async {
      final text = await utf8.decoder.bind(req).join();
      final body = text.isEmpty ? null : jsonDecode(text);
      seen.add(_Seen(req.method, req.uri, req.headers, body));
      final res = req.response..headers.contentType = ContentType.json;
      res.write(jsonEncode(_answer(req.method, req.uri.pathSegments, body)));
      await res.close();
    });
  }

  static Future<FakeHueBridge> start() async =>
      FakeHueBridge._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final seen = <_Seen>[];
  final users = <String>{};
  var linkButtonPressed = false;
  var issued = 'fixture-hue-user-1';
  final lights = <String, Map<String, Object?>>{
    '3': {'on': false, 'bri': 100, 'ct': 300, 'reachable': true},
  };

  int get port => _server.port;

  Object _answer(String method, List<String> path, Object? body) {
    if (method == 'POST' && path.length == 1 && path.first == 'api') {
      if (!linkButtonPressed) {
        return [
          {
            'error': {
              'type': 101,
              'address': '',
              'description': 'link button not pressed',
            },
          },
        ];
      }
      users.add(issued);
      return [
        {
          'success': {'username': issued},
        },
      ];
    }
    if (path.length < 4 || path[0] != 'api' || path[2] != 'lights') {
      return [
        {
          'error': {'type': 3, 'description': 'resource not available'},
        },
      ];
    }
    if (!users.contains(path[1])) {
      return [
        {
          'error': {
            'type': 1,
            'address': '/${path.skip(2).join('/')}',
            'description': 'unauthorized user',
          },
        },
      ];
    }
    final light = lights[path[3]];
    if (light == null) {
      return [
        {
          'error': {
            'type': 3,
            'description': 'resource, /lights/${path[3]}, not available',
          },
        },
      ];
    }
    if (method == 'GET' && path.length == 4) {
      return {'state': light, 'type': 'Extended color light', 'name': 'Desk'};
    }
    if (method == 'PUT' && path.length == 5 && path[4] == 'state') {
      final changes = Map<String, Object?>.from(body as Map);
      light.addAll(changes);
      return [
        for (final e in changes.entries)
          {
            'success': {'/lights/${path[3]}/state/${e.key}': e.value},
          },
      ];
    }
    return [
      {
        'error': {'type': 4, 'description': 'method not available'},
      },
    ];
  }

  Future<void> close() => _server.close(force: true);
}

/// A loopback Home Assistant REST API with one long-lived token.
class FakeHomeAssistant {
  FakeHomeAssistant._(this._server) {
    _server.listen((req) async {
      final text = await utf8.decoder.bind(req).join();
      final body = text.isEmpty ? null : jsonDecode(text);
      seen.add(_Seen(req.method, req.uri, req.headers, body));
      final res = req.response;
      if (req.headers.value('authorization') != 'Bearer $token') {
        res
          ..statusCode = 401
          ..write('401: Unauthorized');
        await res.close();
        return;
      }
      res.headers.contentType = ContentType.json;
      final path = req.uri.pathSegments;
      if (req.method == 'GET' && path.length == 3 && path[1] == 'states') {
        final entity = entities[path[2]];
        if (entity == null) {
          res
            ..statusCode = 404
            ..write('{"message":"Entity not found."}');
        } else {
          res.write(jsonEncode(entity));
        }
      } else if (req.method == 'POST' &&
          path.length == 4 &&
          path[1] == 'services') {
        final entityId = (body as Map)['entity_id'] as String;
        final entity = entities[entityId]!;
        final attributes = entity['attributes'] as Map<String, Object?>;
        switch (path[3]) {
          case 'turn_on':
            entity['state'] = 'on';
            if (body['brightness'] != null) {
              attributes['brightness'] = body['brightness'];
            }
          case 'turn_off':
            entity['state'] = 'off';
        }
        res.write(jsonEncode([entity]));
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }

  static Future<FakeHomeAssistant> start() async => FakeHomeAssistant._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer _server;
  final seen = <_Seen>[];
  var token = 'fixture-ha-token-1';
  final entities = <String, Map<String, Object?>>{
    'light.kitchen': {
      'entity_id': 'light.kitchen',
      'state': 'off',
      'attributes': <String, Object?>{
        'brightness': null,
        'friendly_name': 'Kitchen',
      },
    },
    'switch.heater': {
      'entity_id': 'switch.heater',
      'state': 'on',
      'attributes': <String, Object?>{'friendly_name': 'Heater'},
    },
    'sensor.living_room_temperature': {
      'entity_id': 'sensor.living_room_temperature',
      'state': '21.5',
      'attributes': <String, Object?>{
        'unit_of_measurement': '°C',
        'device_class': 'temperature',
      },
    },
  };

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

String _tapText(PacketTap tap) => tap.recent.map((p) => p.text).join('\n');

/// Runs [body] and returns everything it printed.
Future<String> _printed(Future<void> Function() body) async {
  final out = StringBuffer();
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => out.writeln(line),
    ),
  );
  return out.toString();
}

void main() {
  group('Philips Hue bridge', () {
    late FakeHueBridge bridge;
    late InMemorySecretStore secrets;
    late PacketTap tap;
    late HttpChannel channel;
    late InMemoryDeviceStore store;
    late DeviceService service;

    setUp(() async {
      bridge = await FakeHueBridge.start();
      secrets = InMemorySecretStore();
      tap = PacketTap();
      channel = HttpChannel(tap: tap, secrets: secrets);
      store = InMemoryDeviceStore();
      service = DeviceService(
        registry: _registry(),
        store: store,
        channels: {TransportType.http: channel},
      );
      for (final (id, light) in [('desk', '3'), ('hall', '4')]) {
        await store.put(
          Device(
            id: id,
            name: id,
            driverId: 'philips_hue_light',
            host: '127.0.0.1',
            port: bridge.port,
            settings: {'lightId': light},
          ),
        );
      }
    });
    tearDown(() async {
      await bridge.close();
      await tap.close();
    });

    Future<void> pair() => channel.pairHueBridge(
      host: '127.0.0.1',
      port: bridge.port,
      deviceIds: ['desk', 'hall'],
    );

    test('pairing before the link button is pressed says so', () async {
      await expectLater(
        pair(),
        throwsA(
          isA<LinkButtonNotPressedException>().having(
            (e) => e.message,
            'message',
            contains('press the link button'),
          ),
        ),
      );
      expect(await secrets.read(deviceSecretKey('desk', 'username')), isNull);
    });

    test(
      'pairing stores the username for every light and never shows it',
      () async {
        bridge.linkButtonPressed = true;
        final printed = await _printed(pair);
        expect(bridge.seen.single.method, 'POST');
        expect(bridge.seen.single.uri.path, '/api');
        expect(bridge.seen.single.body, {'devicetype': 'omniflow#omniflow'});
        for (final id in ['desk', 'hall']) {
          expect(
            await secrets.read(deviceSecretKey(id, hueUsernameSecret)),
            bridge.issued,
          );
        }
        expect(_tapText(tap), isNot(contains(bridge.issued)));
        expect(_tapText(tap), contains('"username":"***"'));
        expect(printed, isNot(contains(bridge.issued)));
      },
    );

    test('a bad app name is refused before anything is sent', () async {
      await expectLater(
        channel.pairHueBridge(
          host: '127.0.0.1',
          port: bridge.port,
          deviceIds: ['desk'],
          appName: 'x#y',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(bridge.seen, isEmpty);
    });

    test('a light without a paired username is a missing secret', () async {
      await expectLater(
        service.invoke('desk', 'power', {'value': true}),
        throwsA(
          isA<MissingSecretException>().having(
            (e) => e.key,
            'key',
            'device/desk/username',
          ),
        ),
      );
      expect(bridge.seen, isEmpty);
    });

    group('once paired', () {
      setUp(() async {
        bridge.linkButtonPressed = true;
        await pair();
        bridge.seen.clear();
      });

      test('power puts state on the light and redacts the path', () async {
        final printed = await _printed(() async {
          final result = await service.invoke('desk', 'power', {'value': true});
          expect(result.device.state, {'on': true});
        });
        final put = bridge.seen.single;
        expect(put.method, 'PUT');
        expect(put.uri.path, '/api/${bridge.issued}/lights/3/state');
        expect(put.body, {'on': true});
        expect(bridge.lights['3']!['on'], isTrue);
        final shown = _tapText(tap);
        expect(shown, contains('PUT /api/***/lights/3/state'));
        expect(shown, contains('{"on":true}'));
        expect(shown, isNot(contains(bridge.issued)));
        expect(printed, isNot(contains(bridge.issued)));
      });

      test('brightness and white temperature turn the light on too', () async {
        await service.invoke('desk', 'brightness', {'value': 128});
        await service.invoke('desk', 'color_temp', {'value': 370});
        expect(bridge.seen.map((s) => s.body), [
          {'on': true, 'bri': 128},
          {'on': true, 'ct': 370},
        ]);
        for (final (capability, value) in [
          ('brightness', 0),
          ('brightness', 255),
          ('color_temp', 152),
          ('color_temp', 501),
        ]) {
          await expectLater(
            service.invoke('desk', capability, {'value': value}),
            throwsA(isA<ValidationException>()),
            reason: '$capability $value',
          );
        }
      });

      test('a state poll reads on, bri and ct', () async {
        bridge.lights['3']!.addAll({'on': true, 'bri': 42, 'ct': 250});
        final device = await service.refreshState('desk');
        expect(device.state, containsPair('on', true));
        expect(device.state, containsPair('bri', 42));
        expect(device.state, containsPair('ct', 250));
        expect(bridge.seen.single.method, 'GET');
        expect(bridge.seen.single.uri.path, '/api/${bridge.issued}/lights/3');
        expect(_tapText(tap), contains('GET /api/***/lights/3'));
      });

      test(
        'a username the bridge forgot is a clear secret rejection',
        () async {
          bridge.users.clear();
          await expectLater(
            service.invoke('desk', 'power', {'value': true}),
            throwsA(
              isA<SecretRejectedException>()
                  .having((e) => e.secretKey, 'secretKey', 'username')
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(
                      contains('unauthorized user'),
                      contains('Pair again'),
                      isNot(contains(bridge.issued)),
                    ),
                  ),
            ),
          );
        },
      );

      test('another bridge error fails the command', () async {
        await store.put(
          (await store.get('desk'))!.copyWith(settings: {'lightId': '9'}),
        );
        await expectLater(
          service.invoke('desk', 'power', {'value': true}),
          throwsA(
            isA<CommandFailedException>()
                .having((e) => e, 'type', isNot(isA<SecretRejectedException>()))
                .having((e) => e.message, 'message', contains('/lights/9')),
          ),
        );
      });

      test('a setting naming a secret segment stays literal', () async {
        await store.put(
          (await store.get('desk'))!
              .copyWith(settings: {'lightId': ':secret:username'}),
        );
        await expectLater(
          service.invoke('desk', 'power', {'value': true}),
          throwsA(isA<CommandFailedException>()),
        );
        expect(bridge.seen.single.uri.pathSegments, [
          'api',
          bridge.issued,
          'lights',
          ':secret:username',
          'state',
        ]);
      });

      test('a setting cannot climb out of the light path', () async {
        for (final bad in ['..', '%2e%2E']) {
          await store.put(
            (await store.get('desk'))!.copyWith(settings: {'lightId': bad}),
          );
          await expectLater(
            service.invoke('desk', 'power', {'value': true}),
            throwsA(isA<ArgumentError>()),
            reason: bad,
          );
        }
        expect(bridge.seen, isEmpty);
      });
    });

    test('a username with URL characters is encoded and redacted', () async {
      const odd = 'fixture/with%odd chars';
      bridge
        ..issued = odd
        ..linkButtonPressed = true;
      await pair();
      await service.invoke('desk', 'power', {'value': true});
      expect(bridge.seen.last.uri.pathSegments[1], odd);
      final shown = _tapText(tap);
      expect(shown, isNot(contains(odd)));
      expect(shown, isNot(contains(Uri.encodeComponent(odd))));
      expect(shown, contains('PUT /api/***/lights/3/state'));
    });
  });

  group('Home Assistant', () {
    late FakeHomeAssistant ha;
    late InMemorySecretStore secrets;
    late PacketTap tap;
    late InMemoryDeviceStore store;
    late DeviceService service;

    setUp(() async {
      ha = await FakeHomeAssistant.start();
      secrets = InMemorySecretStore();
      tap = PacketTap();
      store = InMemoryDeviceStore();
      service = DeviceService(
        registry: _registry(),
        store: store,
        channels: {TransportType.http: HttpChannel(tap: tap, secrets: secrets)},
      );
      for (final (id, driver, settings) in [
        (
          'kitchen',
          'home_assistant_entity',
          {'entityId': 'light.kitchen', 'domain': 'light'},
        ),
        (
          'heater',
          'home_assistant_entity',
          {'entityId': 'switch.heater', 'domain': 'switch'},
        ),
        (
          'lounge_temp',
          'home_assistant_sensor',
          {'entityId': 'sensor.living_room_temperature'},
        ),
      ]) {
        await store.put(
          Device(
            id: id,
            name: id,
            driverId: driver,
            host: '127.0.0.1',
            port: ha.port,
            settings: settings,
          ),
        );
        await secrets.write(deviceSecretKey(id, 'token'), ha.token);
      }
    });
    tearDown(() async {
      await ha.close();
      await tap.close();
    });

    test('power on calls light.turn_on with the bearer token', () async {
      final printed = await _printed(() async {
        final result = await service.invoke('kitchen', 'power', {
          'value': true,
        });
        expect(result.device.state, {'state': true});
      });
      final call = ha.seen.single;
      expect(call.method, 'POST');
      expect(call.uri.path, '/api/services/light/turn_on');
      expect(call.body, {'entity_id': 'light.kitchen'});
      expect(call.headers.value('authorization'), 'Bearer ${ha.token}');
      expect(ha.entities['light.kitchen']!['state'], 'on');
      final shown = _tapText(tap);
      expect(shown, contains('POST /api/services/light/turn_on'));
      expect(shown, contains('Authorization: Bearer ***'));
      expect(shown, isNot(contains(ha.token)));
      expect(printed, isNot(contains(ha.token)));
    });

    test('a switch toggles with switch.turn_off and turn_on', () async {
      await service.refreshState('heater');
      await service.toggle('heater', 'power');
      await service.toggle('heater', 'power');
      expect(ha.seen.map((s) => '${s.method} ${s.uri.path}'), [
        'GET /api/states/switch.heater',
        'POST /api/services/switch/turn_off',
        'POST /api/services/switch/turn_on',
      ]);
      expect(ha.entities['switch.heater']!['state'], 'on');
    });

    test('brightness sends 0 to 255 to light.turn_on', () async {
      final result = await service.invoke('kitchen', 'brightness', {
        'value': 200,
      });
      expect(ha.seen.single.body, {
        'entity_id': 'light.kitchen',
        'brightness': 200,
      });
      expect(result.device.state, {'brightness': 200});
      await expectLater(
        service.invoke('kitchen', 'brightness', {'value': 256}),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a state poll reads state and attributes.brightness', () async {
      ha.entities['light.kitchen']!['state'] = 'on';
      (ha.entities['light.kitchen']!['attributes'] as Map)['brightness'] = 77;
      final device = await service.refreshState('kitchen');
      expect(device.state['state'], isTrue);
      expect(device.state['brightness'], 77);
      expect(device.state['friendly_name'], 'Kitchen');
      expect(ha.seen.single.uri.path, '/api/states/light.kitchen');
    });

    test('a sensor reads its state and unit', () async {
      final device = await service.refreshState('lounge_temp');
      expect(device.state['state'], '21.5');
      expect(device.state['unit_of_measurement'], '°C');
    });

    test('an expired token is reported as one, without the token', () async {
      final stale = ha.token;
      ha.token = 'fixture-ha-token-2';
      await expectLater(
        service.refreshState('kitchen'),
        throwsA(
          isA<SecretRejectedException>()
              .having((e) => e.secretKey, 'secretKey', 'token')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('HTTP 401'),
                  contains('expired'),
                  contains('omni secret set'),
                  isNot(contains(stale)),
                ),
              ),
        ),
      );
      expect(_tapText(tap), isNot(contains(stale)));
      await secrets.write(deviceSecretKey('kitchen', 'token'), ha.token);
      expect((await service.refreshState('kitchen')).state['state'], isFalse);
    });

    test('a missing token is a missing secret, and nothing is sent', () async {
      await secrets.delete(deviceSecretKey('kitchen', 'token'));
      await expectLater(
        service.invoke('kitchen', 'power', {'value': true}),
        throwsA(isA<MissingSecretException>()),
      );
      expect(ha.seen, isEmpty);
    });

    test('an unknown entity is a device error', () async {
      await store.put(
        (await store.get('kitchen'))!.copyWith(
          settings: {'entityId': 'light.nowhere', 'domain': 'light'},
        ),
      );
      await expectLater(
        service.refreshState('kitchen'),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('Entity not found'),
          ),
        ),
      );
    });

    test('an entity id cannot reach another API path', () async {
      await store.put(
        (await store.get('kitchen'))!
            .copyWith(settings: {'entityId': '../config', 'domain': 'light'}),
      );
      await expectLater(
        service.refreshState('kitchen'),
        throwsA(isA<ArgumentError>()),
      );
      expect(ha.seen, isEmpty);
    });

    test('a reply echoing the token comes back redacted', () async {
      ha.entities['light.kitchen']!['attributes'] = <String, Object?>{
        'note': 'token is ${ha.token}',
      };
      final device = await service.refreshState('kitchen');
      expect(device.state['note'], 'token is ***');
    });

    test('a redirect is not followed with the token', () async {
      final redirector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => redirector.close(force: true));
      redirector.listen((req) async {
        req.response
          ..statusCode = 302
          ..headers.set('location', 'http://127.0.0.1:${ha.port}/api/states/x');
        await req.response.close();
      });
      await store.put(
        (await store.get('kitchen'))!.copyWith(port: redirector.port),
      );
      await expectLater(
        service.refreshState('kitchen'),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('redirect'),
          ),
        ),
      );
      expect(ha.seen, isEmpty);
    });
  });

  group('HTTP secret options in a manifest', () {
    Map<String, Object?> manifest({
      Map<String, Object?> transport = const {},
      Object? command,
      List<Map<String, Object?>> settings = const [
        {'key': 'token', 'label': 'Token', 'secret': true},
        {'key': 'plain', 'label': 'Plain'},
      ],
    }) => {
      'schemaVersion': 1,
      'id': 'probe',
      'name': 'Probe',
      'category': 'power',
      'transport': {'type': 'http', ...transport},
      'settings': settings,
      'capabilities': [
        {
          'id': 'power',
          'type': 'toggle',
          'command':
              command ??
              {
                'path': '/x',
                'query': {'on': '{{value}}'},
              },
        },
      ],
    };

    List<String> issuesOf(Map<String, Object?> json) => [
      for (final i in httpTransportIssues(DriverManifest.parse(json)))
        '${i.path} ${i.message}',
    ];

    test('every built-in HTTP driver, Shelly included, is clean', () {
      final all = {...builtInDriverSources, ..._hubSources()};
      final http = [
        for (final source in all.values) DriverManifest.parseJson(source),
      ].where((m) => m.transport.type == TransportType.http).toList();
      expect(http.map((m) => m.id), containsAll(['shelly_plus_switch']));
      expect(http.length, greaterThanOrEqualTo(4));
      for (final m in http) {
        expect(httpTransportIssues(m), isEmpty, reason: m.id);
      }
    });

    test('auth must name a secret setting and a usable header', () {
      expect(
        issuesOf(
          manifest(
            transport: {
              'auth': {
                'header': 'Host',
                'scheme': 'Two words',
                'secret': 'plain',
              },
            },
          ),
        ),
        [
          r'$.transport.auth.header Host is set by the channel',
          r'$.transport.auth.scheme must be one word, such as Bearer',
          r'$.transport.auth.secret must name a secret setting',
        ],
      );
    });

    test('a path secret is a whole segment naming a secret setting', () {
      expect(issuesOf(manifest(command: {'path': '/api/x:secret:token/y'})), [
        r'$.capabilities[0].command.path a secret is a whole segment, :secret:name',
      ]);
      expect(issuesOf(manifest(command: {'path': '/api/:secret:plain'})), [
        r'$.capabilities[0].command.path plain is not a secret setting',
      ]);
      expect(
        issuesOf(
          manifest(
            command: {
              'path': '/api',
              'body': {'key': ':secret:token'},
            },
          ),
        ),
        [
          r'$.capabilities[0].command.body secrets go only in the path or the auth header',
        ],
      );
    });

    test('the channel refuses a manifest with bad secret options', () async {
      final bad = DriverManifest.parse(
        manifest(command: {'path': '/api/:secret:plain'}),
      );
      await expectLater(
        HttpChannel(secrets: InMemorySecretStore()).send(
          ChannelRequest(
            device: const Device(
              id: 'probe',
              name: 'Probe',
              driverId: 'probe',
              host: '127.0.0.1',
            ),
            manifest: bad,
            command: bad.capabilities.single.command,
            context: const TemplateContext(params: {'value': true}),
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a channel with no secret store says so', () async {
      final needsToken = DriverManifest.parse(
        manifest(
          transport: {
            'auth': {'header': 'Authorization', 'secret': 'token'},
          },
        ),
      );
      await expectLater(
        HttpChannel().send(
          ChannelRequest(
            device: const Device(
              id: 'probe',
              name: 'Probe',
              driverId: 'probe',
              host: '127.0.0.1',
            ),
            manifest: needsToken,
            command: needsToken.capabilities.single.command,
            context: const TemplateContext(params: {'value': true}),
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
