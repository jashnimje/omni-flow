import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'driver_manifest_test.dart' show validManifest;

/// A setting's `help`: what it is and where to find it, carried from the
/// manifest to driver.list and to each step of a guided add.
void main() {
  Map<String, Object?> withSetting(Map<String, Object?> setting) =>
      validManifest()..['settings'] = [setting];

  group('manifest', () {
    test('keeps a setting\'s help, trimmed', () {
      final m = DriverManifest.parse(
        withSetting({'key': 'devId', 'label': 'Id', 'help': ' Its id. '}),
      );
      expect(m.settings.single.help, 'Its id.');
    });

    test('a setting without help has none', () {
      final m = DriverManifest.parse(withSetting({'key': 'devId'}));
      expect(m.settings.single.help, isNull);
    });

    test('refuses help that is not text, or is empty', () {
      for (final help in [42, '   ']) {
        expect(
          () => DriverManifest.parse(
            withSetting({'key': 'devId', 'label': 'Id', 'help': help}),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.toString(),
              'issues',
              contains('settings[0].help'),
            ),
          ),
        );
      }
    });

    test('every built-in setting a person types has help', () {
      final registry = DriverRegistry.withBuiltIns();
      final missing = [
        for (final m in registry.all)
          // The phone's settings are set by the app, never typed.
          if (m.id != 'phone')
            for (final s in m.settings)
              if (s.help == null) '${m.id}.${s.key}',
      ];
      expect(missing, isEmpty);
    });

    test('the Tuya local key help walks through getting the key', () {
      final registry = DriverRegistry.withBuiltIns();
      for (final id in ['tuya_plug', 'tuya_light']) {
        final help = registry[id]!.settings
            .firstWhere((s) => s.key == 'localKey')
            .help!;
        expect(help, contains('iot.tuya.com'));
        expect(help, contains('tinytuya wizard'));
        expect(help, contains('Smart Life'));
        expect(help, contains('Wipro'));
        expect(help, contains('new key'));
        expect(help, isNot(contains('\u2014')));
      }
    });
  });

  group('engine', () {
    late Directory home;
    late OmniEngine engine;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_setting_help');
      engine = await OmniEngine.open(
        home: home,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      );
    });

    tearDown(() async {
      await engine.close();
      await home.delete(recursive: true);
    });

    test('driver.list carries each setting\'s help', () async {
      final r = await engine.handle('driver.list', const {});
      final tuya = (r['drivers'] as List).cast<Map>().firstWhere(
        (d) => d['id'] == 'tuya_plug',
      );
      final key = (tuya['settings'] as List).cast<Map>().firstWhere(
        (s) => s['key'] == 'localKey',
      );
      expect(key['secret'], isTrue);
      expect(key['help'], contains('tinytuya'));
    });

    test('a guided add step carries the help of each key it asks', () async {
      final added = await engine.handle('device.add', {
        'id': 'plug',
        'name': 'Kettle plug',
        'driver': 'tuya_plug',
        'host': '127.0.0.1',
        'settings': {'devId': 'bf0123456789abcdef'},
      });
      expect(added['ok'], isTrue, reason: '$added');
      final next = await engine.handle('thing.next', {'id': 'plug'});
      expect(next['ok'], isTrue, reason: '$next');
      final step = next['next'] as Map;
      expect(step['step'], 'secret');
      final key = (step['keys'] as List).cast<Map>().single;
      expect(key['key'], 'localKey');
      expect(key['help'], contains('iot.tuya.com'));
    });
  });
}
