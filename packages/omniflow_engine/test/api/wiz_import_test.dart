import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/wiz_import.dart';
import 'package:test/test.dart';

import '../support/fake_wiz_bulb.dart';

const _key = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';
const _link =
    'https://wiz-s3-local-integration-eu.s3.eu-west-1.amazonaws.com/'
    'export/123.json?X-Amz-Signature=abc';

/// A real export's shape, with made-up values.
Map<String, Object?> _export({
  String bedroomName = 'Bedroom Light',
  String key = _key,
}) => {
  'name': 'My home',
  'home_id': 123,
  'region': 'eu',
  'udp_signing_key': key,
  'version': '1.0',
  'creation_date': '2026-01-01T00:00:00Z',
  'update_date': '2026-01-01T00:00:00Z',
  'rooms': [
    {
      'room_id': 456,
      'name': 'Bedroom',
      'type': 'BEDROOM',
      'creation_date': '...',
      'update_date': '...',
    },
    {'room_id': 457, 'name': 'Hall', 'type': 'HALL'},
  ],
  'devices': [
    {
      'device_id': 789,
      'type': 'light',
      'room_id': 456,
      'group_id': null,
      'name': bedroomName,
      'mac_address': 'A8BB50000001',
      'fw_version': '1.38.0',
      'traits': {
        'is_dimmable': true,
        'is_tunable_white': true,
        'white_range': [2200, 6500],
        'is_tunable_color': true,
        'supports_light_mode': true,
      },
    },
    {
      'device_id': 790,
      'type': 'light',
      'room_id': 457,
      'name': 'Hall Light',
      'mac_address': 'a8bb50000002',
      'traits': {'is_dimmable': true},
    },
    {
      'device_id': 791,
      'type': 'socket',
      'room_id': 457,
      'name': 'Hall Plug',
      'mac_address': 'a8bb50000003',
    },
  ],
};

void main() {
  group('the export', () {
    test('parses rooms, lights and their MACs', () {
      final e = WizExport.parse(_export());
      expect(e.homeName, 'My home');
      expect(e.rooms, {456: 'Bedroom', 457: 'Hall'});
      expect(
        [for (final d in e.devices) d.mac],
        ['a8bb50000001', 'a8bb50000002', 'a8bb50000003'],
      );
      expect([for (final d in e.devices) d.isLight], [true, true, false]);
      expect(e.signingKey, _key);
      expect('$e', isNot(contains(_key)));
    });

    test('a bad shape is refused in plain words that never carry the key', () {
      void refused(Object? json, String words) {
        try {
          WizExport.parse(json);
          fail('parsed $json');
        } on ApiError catch (e) {
          expect(e.type, 'invalid');
          expect(e.message, contains(words));
          expect(e.message, isNot(contains(_key)));
          expect(e.message, isNot(contains('0f1e2d')));
        }
      }

      refused([1, 2], 'not a JSON object');
      refused({'udp_signing_key': _key}, 'no list of devices');
      refused({..._export(), 'udp_signing_key': '${_key}00'}, 'home key');
      refused({..._export()}..remove('udp_signing_key'), 'home key');
      refused({..._export(), 'rooms': 'x'}, 'rooms are not a list');
      refused({
        ..._export(),
        'devices': ['x'],
      }, 'not an object');
    });

    test('the link must be https on the WiZ export bucket', () {
      expect(wizExportUrl(_link).host, startsWith('wiz-s3-local-integration'));
      for (final bad in [
        'http://wiz-s3-local-integration-eu.s3.amazonaws.com/x.json',
        'https://example.com/x.json',
        'https://wiz-s3-local-integration-eu.s3.amazonaws.com.evil.com/x',
        'https://s3.amazonaws.com/wiz-s3-local-integration-eu/x',
        'https://user@wiz-s3-local-integration-eu.s3.amazonaws.com/x',
        'https://wiz-s3-local-integration-eu.s3.amazonaws.com:8443/x',
        'not a link',
      ]) {
        expect(
          () => wizExportUrl(bad),
          throwsA(
            isA<ApiError>()
                .having((e) => e.type, 'type', 'invalid')
                .having((e) => e.message, 'message', isNot(contains('/x'))),
          ),
          reason: bad,
        );
      }
    });

    test('the download is capped in size and time, and an old link reads '
        'as run out', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        switch (r.uri.path) {
          case '/big':
            r.response.add(List.filled(4096, 32));
          case '/old':
            r.response.statusCode = 403;
          case '/slow':
            await Future<void>.delayed(const Duration(seconds: 2));
          default:
            r.response.write(jsonEncode(_export()));
        }
        await r.response.close();
      });
      Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
      final ok = await fetchWizExport(at('/ok'));
      expect(WizExport.parse(jsonDecode(utf8.decode(ok))).homeName, 'My home');
      await expectLater(
        fetchWizExport(at('/big'), maxBytes: 1024),
        throwsA(
          isA<ApiError>().having((e) => e.message, 'm', contains('1 KB')),
        ),
      );
      await expectLater(
        fetchWizExport(at('/old')),
        throwsA(
          isA<ApiError>().having((e) => e.message, 'm', contains('run out')),
        ),
      );
      await expectLater(
        fetchWizExport(at('/slow'), timeout: const Duration(milliseconds: 300)),
        throwsA(isA<ApiError>().having((e) => e.type, 'type', 'unavailable')),
      );
    });
  });

  group('wiz.import', () {
    late Directory home;
    late InMemorySecretStore secrets;
    late OmniEngine engine;
    late PacketTap tap;
    late FakeWizBulb bulb;
    final events = <Map<String, Object?>>[];

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_wiz_import');
      secrets = InMemorySecretStore();
      tap = PacketTap();
      engine = await OmniEngine.open(
        home: home,
        secrets: secrets,
        tap: tap,
        discoveryTargets: () async => [InternetAddress.loopbackIPv4],
      );
      engine.events.listen(events.add);
      bulb = await FakeWizBulb.start(
        module: 'ESP25_SHRGB_01',
        range: const [2200, 6500],
        key: _key,
        mac: 'a8bb50000001',
      );
    });
    tearDown(() async {
      await engine.close();
      bulb.close();
      events.clear();
      await home.delete(recursive: true);
    });

    Future<Map<String, Object?>> import([Map<String, Object?>? export]) =>
        engine.handle('wiz.import', {
          'export': export ?? _export(),
          'port': bulb.port,
          'windowMs': 600,
        });

    Future<List<Map>> wizThings() async => [
      for (final d
          in (await engine.handle('device.list', const {}))['devices'] as List)
        if ((d as Map)['driver'] == wizDriverId) d,
    ];

    test('adds the bulb found by MAC with its WiZ name, room and key, and '
        'lists the one not on the Wi-Fi', () async {
      final r = await import();
      expect(r['ok'], isTrue, reason: '$r');
      expect(r['added'], [
        {
          'id': 'bedroom_light',
          'name': 'Bedroom Light',
          'room': 'Bedroom',
          'host': '127.0.0.1',
        },
      ]);
      expect(r['updated'], isEmpty);
      final missing = (r['notFound'] as List).single as Map;
      expect(missing['name'], 'Hall Light');
      expect(missing['reason'], contains('did not answer on this Wi-Fi'));
      expect((r['skipped'] as List).single, {
        'name': 'Hall Plug',
        'reason': 'It is a WiZ socket, not a light',
      });
      expect(r['roomsCreated'], ['Bedroom']);
      expect(r['message'], 'Added 1 light. 1 was not found on this Wi-Fi.');

      final things = await wizThings();
      expect(things, hasLength(1));
      final thing = things.single;
      expect(thing['stableId'], 'a8bb50000001');
      expect(thing['port'], bulb.port);
      final bulbSetting = (thing['settings'] as Map)['bulb'] as Map;
      expect(bulbSetting['module'], 'ESP25_SHRGB_01');
      expect(bulbSetting['kind'], 'rgb');
      expect([bulbSetting['minK'], bulbSetting['maxK']], [2200, 6500]);
      expect(
        await secrets.read(deviceSecretKey('bedroom_light', 'signingKey')),
        _key,
      );
      // The stored key signs a write the "pro" bulb takes.
      final on = await engine.handle('device.invoke', {
        'id': 'bedroom_light',
        'capability': 'power',
        'params': {'value': true},
      });
      expect(on['ok'], isTrue, reason: '$on');
      expect(bulb.pilot['state'], true);
    });

    test(
      'the key never appears in the reply, the events or the packet tap',
      () async {
        final r = await import();
        expect(r['ok'], isTrue, reason: '$r');
        await engine.handle('device.invoke', {
          'id': 'bedroom_light',
          'capability': 'power',
          'params': {'value': true},
        });
        expect(jsonEncode(r), isNot(contains(_key)));
        expect(jsonEncode(events), isNot(contains(_key)));
        expect(tap.recent, isNotEmpty);
        for (final p in tap.recent) {
          expect(p.text, isNot(contains(_key)));
        }
        final list = await engine.handle('device.list', const {});
        expect(jsonEncode(list), isNot(contains(_key)));
      },
    );

    test('an import again updates the bulb, never a second one', () async {
      await import();
      await engine.handle('device.organize', {
        'id': 'bedroom_light',
        'room': 'Somewhere else',
      });
      final again = await import(_export(bedroomName: 'Reading lamp'));
      expect(again['ok'], isTrue, reason: '$again');
      expect(again['added'], isEmpty);
      expect(again['updated'], [
        {
          'id': 'bedroom_light',
          'name': 'Reading lamp',
          'room': 'Bedroom',
          'host': '127.0.0.1',
        },
      ]);
      expect(again['roomsCreated'], isEmpty);
      final things = await wizThings();
      expect(things, hasLength(1));
      expect(things.single['name'], 'Reading lamp');
      expect(things.single['room'], 'Bedroom');
    });

    test(
      'a pasted text that is no WiZ link is refused before any download',
      () async {
        for (final text in [
          'https://example.com/export.json',
          'look http://wiz-s3-local-integration-eu.s3.amazonaws.com/x',
          'hello',
        ]) {
          final r = await engine.handle('wiz.import', {'text': text});
          expect((r['error'] as Map)['type'], 'invalid', reason: text);
        }
        final pasted = await engine.handle('wiz.import', {
          'text': jsonEncode(_export()),
          'port': bulb.port,
          'windowMs': 600,
        });
        expect((pasted['added'] as List).single['id'], 'bedroom_light');
      },
    );

    test('an agent is refused, even with setup allowed', () async {
      await engine.handle('agent.access.set', {'access': 'setup'});
      final r = await engine.handle('agent.call', {
        'command': 'wiz.import',
        'args': {'export': _export(), 'port': bulb.port},
      });
      expect((r['error'] as Map)['type'], 'needs_user');
      expect((r['error'] as Map)['message'], contains('WiZ home key'));
      expect(await wizThings(), isEmpty);
      expect(agentUserOnly.keys, contains('wiz.import'));
    });
  });

  group('WiZ discovery', () {
    test('finds a bulb that answers getSystemConfig but not registration, '
        'and says a sweep started', () async {
      final home = await Directory.systemTemp.createTemp('omni_wiz_find');
      final engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        discoveryTargets: () async => [InternetAddress.loopbackIPv4],
      );
      final bulb = await FakeWizBulb.start(
        module: 'ESP25_SHRGB_01',
        key: _key,
        mac: 'a8bb50000009',
      );
      addTearDown(() async {
        await engine.close();
        bulb.close();
        await home.delete(recursive: true);
      });
      final started = engine.events.firstWhere(
        (e) => e['event'] == 'discovery.started',
      );
      final r = await engine.handle('device.discover', {
        'driver': wizDriverId,
        'port': bulb.port,
        'windowMs': 400,
      });
      final found = (r['found'] as List).single as Map;
      expect(found['stableId'], 'a8bb50000009');
      expect(
        (found['reply'] as Map)['result'],
        containsPair('moduleName', 'ESP25_SHRGB_01'),
      );
      expect(
        bulb.requests.map((q) => q['method']).toSet(),
        containsAll(['registration', 'getSystemConfig']),
      );
      expect((await started)['windowMs'], greaterThanOrEqualTo(400));
    });
  });

  test('omni wiz import FILE reads the export and says what it found, '
      'never the key', () async {
    final home = await Directory.systemTemp.createTemp('omni_wiz_cli');
    addTearDown(() => home.delete(recursive: true));
    final file = File('${home.path}/export.json')
      ..writeAsStringSync(jsonEncode(_export()));
    final out = StringBuffer();
    final code =
        await OmniCommandRunner(
          out: out,
          input: const Stream.empty(),
          // No discovery targets: the test never broadcasts on a real network.
          engineFactory: (h, {tap}) => OmniEngine.open(
            home: h,
            secrets: InMemorySecretStore(),
            tap: tap,
            discoveryTargets: () async => const [],
          ),
        ).run([
          '--home',
          home.path,
          'wiz',
          'import',
          '--window-ms',
          '500',
          file.path,
        ]);
    expect(code, 0, reason: '$out');
    final reply = jsonDecode('$out') as Map;
    expect(
      [for (final m in reply['notFound'] as List) (m as Map)['name']],
      ['Bedroom Light', 'Hall Light'],
    );
    expect('$out', isNot(contains(_key)));
  });
}
