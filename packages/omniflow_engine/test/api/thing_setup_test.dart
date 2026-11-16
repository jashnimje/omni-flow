import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

Map<String, Object?> manifest({
  List<Object?>? setup,
  Map<String, Object?>? pairing,
  Map<String, Object?> transport = const {'type': 'http', 'port': 80},
}) => {
  'schemaVersion': 1,
  'id': 'test_thing',
  'name': 'Test thing',
  'category': 'switch',
  'transport': transport,
  'settings': [
    {'key': 'topic', 'label': 'Topic'},
    {'key': 'user', 'label': 'User'},
    {'key': 'token', 'label': 'Token', 'secret': true},
    {'key': 'key2', 'label': 'Second key', 'secret': true},
  ],
  'pairing': ?pairing,
  'setup': ?setup,
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'path': '/{{device.topic}}/{{value}}'},
    },
  ],
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
  group('manifest setup', () {
    test('parses pair, secret and configure steps, with optional ones', () {
      final m = DriverManifest.parse(
        manifest(
          setup: ['pair', 'secret:token', 'configure:topic', 'configure:user?'],
          pairing: {'method': 'secret', 'secret': 'token'},
        ),
      );
      expect(m.setup.map((s) => s.wireName), [
        'pair',
        'secret:token',
        'configure:topic',
        'configure:user?',
      ]);
      expect(m.setup.last.optional, isTrue);
      expect(m.setup[1].kind, SetupKind.secret);
      expect(m.setup[1].key, 'token');
    });

    test('a manifest with no setup has none', () {
      expect(DriverManifest.parse(manifest()).setup, isEmpty);
    });

    test('rejects steps that name the wrong setting or cannot run', () {
      final issues = issuesOf(
        manifest(
          setup: [
            'pair',
            'secret:topic',
            'configure:token',
            'configure:missing',
            'configure:topic',
            'configure:topic',
            'reboot',
            'secret',
            7,
          ],
        ),
      );
      expect(issues, [
        r'$.setup[0] pair needs a pairing entry or a TV transport',
        r'$.setup[1] topic needs a secret setting key',
        r'$.setup[2] token needs a plain setting key',
        r'$.setup[3] missing needs a plain setting key',
        r'$.setup[5] duplicates configure:topic',
        r'$.setup[6] must be pair, secret:<key> or configure:<key>',
        r'$.setup[7] secret needs a secret setting key',
        r'$.setup[8] must be pair, secret:<key> or configure:<key>',
      ]);
    });

    test('pair takes no key and is never optional', () {
      expect(
        issuesOf(
          manifest(
            setup: ['pair?'],
            transport: const {
              'type': 'websocket',
              'port': 3001,
              'protocol': 'webos',
            },
          ),
        ),
        [r'$.setup[0] pair takes no key and cannot be optional'],
      );
    });

    test('setup must be a list', () {
      expect(issuesOf({...manifest(), 'setup': 'pair'}), [
        r'$.setup must be an array',
      ]);
    });

    test('every built-in driver that needs a step declares it', () {
      final registry = DriverRegistry.withBuiltIns();
      List<String> setupOf(String id) => [
        for (final s in registry[id]!.setup) s.wireName,
      ];
      expect(setupOf('lg_webos_tv'), ['pair']);
      expect(setupOf('samsung_tizen_tv'), ['pair']);
      expect(setupOf('android_tv_adb'), ['pair', 'configure:mac?']);
      expect(setupOf('philips_hue_light'), ['pair', 'configure:lightId']);
      expect(setupOf('home_assistant_entity'), [
        'secret:token',
        'configure:entityId',
        'configure:domain',
      ]);
      expect(setupOf('tuya_plug'), [
        'configure:devId',
        'secret:localKey',
        'configure:version?',
      ]);
      expect(setupOf('omniflow_board'), ['configure:pins']);
      expect(setupOf('zigbee2mqtt_device').first, 'configure:friendlyName');
      expect(setupOf('philips_wiz_udp'), ['secret:signingKey?']);
      expect(setupOf('shelly_plus_switch'), isEmpty);
      for (final m in registry.all) {
        final secrets = {
          for (final s in m.settings)
            if (s.secret) s.key,
        };
        final declared = {
          for (final s in m.setup)
            if (s.kind == SetupKind.secret) s.key,
        };
        final pairs = m.setup.any((s) => s.kind == SetupKind.pair);
        // A TV's certificate pin is stored on first connect, and a pairing
        // stores its own key, so neither is the user's to enter.
        final userSecrets = secrets.difference({
          'certSha256',
          if (pairs) ?pairingProofSecret(m),
        });
        expect(
          declared,
          userSecrets,
          reason:
              '${m.id} declares a secret step for each secret the user '
              'stores',
        );
      }
    });
  });

  group('nextSetupStep', () {
    late InMemorySecretStore secrets;
    setUp(() => secrets = InMemorySecretStore());

    Device device({
      Map<String, Object?> settings = const {},
      DateTime? lastSeen,
    }) => Device(
      id: 'thing',
      name: 'The thing',
      driverId: 'test_thing',
      host: '10.0.0.2',
      settings: settings,
      lastSeen: lastSeen,
    );

    Future<Map<String, Object?>> next(
      Map<String, Object?> json, {
      Map<String, Object?> settings = const {},
      DateTime? lastSeen,
      bool pairedHere = false,
    }) => nextSetupStep(
      device(settings: settings, lastSeen: lastSeen),
      DriverManifest.parse(json),
      secrets,
      pairedHere: pairedHere,
    );

    test('done when the driver declares no setup', () async {
      expect(await next(manifest()), {
        'step': 'done',
        'instruction': 'The thing is ready',
      });
    });

    test('secret steps next to each other are asked together', () async {
      final json = manifest(
        setup: ['secret:token', 'secret:key2', 'configure:topic'],
        pairing: {
          'method': 'secret',
          'secret': 'token',
          'instructions': 'Make a token in the app',
        },
      );
      final first = await next(json);
      expect(first['step'], 'secret');
      expect(first['command'], 'secret.set');
      expect(first['keys'], [
        {'step': 'secret', 'key': 'token', 'label': 'Token'},
        {'step': 'secret', 'key': 'key2', 'label': 'Second key'},
      ]);
      expect(first['instruction'], startsWith('Make a token in the app. '));
      expect(first['remaining'], [
        'secret:token',
        'secret:key2',
        'configure:topic',
      ]);

      await secrets.write(deviceSecretKey('thing', 'token'), 't');
      final second = await next(json);
      expect((second['keys'] as List).single, containsPair('key', 'key2'));

      await secrets.write(deviceSecretKey('thing', 'key2'), 'k');
      final third = await next(json);
      expect(third['step'], 'configure');
      expect(third['command'], 'thing.configure');
      expect(third['instruction'], 'Set the Topic for thing');

      expect((await next(json, settings: {'topic': 'a/b'}))['step'], 'done');
    });

    test('an optional step goes with its group and never blocks', () async {
      final json = manifest(
        setup: ['configure:topic', 'configure:user?', 'secret:token?'],
      );
      final first = await next(json);
      expect(first['keys'], [
        {'step': 'configure', 'key': 'topic', 'label': 'Topic'},
        {'step': 'configure', 'key': 'user', 'label': 'User', 'optional': true},
      ]);
      final done = await next(json, settings: {'topic': 't'});
      expect(done['step'], 'done');
      expect(done['optional'], [
        {'step': 'configure', 'key': 'user', 'label': 'User', 'optional': true},
        {'step': 'secret', 'key': 'token', 'label': 'Token', 'optional': true},
      ]);
    });

    test('an empty string is not a setting, an empty object is', () async {
      final json = manifest(setup: ['configure:topic']);
      expect((await next(json, settings: {'topic': ''}))['step'], 'configure');
      expect((await next(json, settings: {'topic': {}}))['step'], 'done');
    });

    test('a TV is paired once its pairing key is stored', () async {
      final json = manifest(
        setup: ['pair'],
        transport: const {
          'type': 'websocket',
          'port': 3001,
          'protocol': 'webos',
        },
      );
      final pair = await next(json);
      expect(pair['step'], 'pair');
      expect(pair['method'], 'tv');
      expect(pair['command'], 'device.pair');
      expect(pair['instruction'], contains('Allow'));
      expect(
        (await next(json, lastSeen: DateTime(2026), pairedHere: true))['step'],
        'pair',
        reason: 'a stored key is the only proof for a TV',
      );
      await secrets.write(deviceSecretKey('thing', 'token'), 'not it');
      expect((await next(json))['step'], 'pair');
      await secrets.write(deviceSecretKey('thing', 'clientKey'), 'k');
      expect((await next(json))['step'], 'done');
    });

    test('ADB counts as paired once paired here or seen', () async {
      final json = manifest(
        setup: ['pair'],
        transport: const {'type': 'adb', 'port': 5555},
      );
      expect((await next(json))['method'], 'adb');
      expect((await next(json, pairedHere: true))['step'], 'done');
      expect((await next(json, lastSeen: DateTime(2026)))['step'], 'done');
    });
  });
}
