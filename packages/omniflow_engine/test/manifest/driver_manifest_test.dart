import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

Map<String, Object?> validManifest() => {
  'schemaVersion': 1,
  'id': 'test_light',
  'name': 'Test light',
  'category': 'lighting',
  'transport': {
    'type': 'udp',
    'port': 38899,
    'listenPort': 38900,
    'payload': 'json',
  },
  'discovery': [
    {'method': 'udp_broadcast', 'port': 38899},
  ],
  'settings': [
    {'key': 'localKey', 'label': 'Local key', 'secret': true},
  ],
  'reliability': {'timeoutMs': 500, 'retries': 2},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'command': {
        'method': 'setState',
        'params': {'state': '{{value}}'},
      },
    },
    {
      'id': 'color_temp',
      'type': 'color_temp',
      'params': {
        'value': {'type': 'number', 'min': 2200, 'max': 6500},
        'brightness': {
          'type': 'number',
          'min': 10,
          'max': 100,
          'optional': true,
        },
      },
      'command': {
        'method': 'setPilot',
        'params': {
          'temp': '{{value}}',
          'dimming': '{{brightness|state.brightness|100}}',
        },
      },
    },
    {'id': 'temperature', 'type': 'sensor'},
  ],
};

List<String> issuesFor(Map<String, Object?> json) {
  try {
    DriverManifest.parse(json);
    return const [];
  } on ValidationException catch (e) {
    return e.issues.map((i) => i.toString()).toList();
  }
}

void main() {
  test('a valid manifest parses with defaults and options filled in', () {
    final m = DriverManifest.parse(validManifest());
    expect(m.id, 'test_light');
    expect(m.transport.type, TransportType.udp);
    expect(m.transport.payload, PayloadEncoding.json);
    expect(m.transport.listenPort, 38900);
    expect(m.reliability.retries, 2);
    expect(m.settings.single.secret, isTrue);
    expect(m.capabilities.map((c) => c.id), [
      'power',
      'color_temp',
      'temperature',
    ]);
    expect(m.capability('power')!.params['value']!.type, ParamType.boolean);
    expect(m.isHighRisk, isFalse);
  });

  test('parseJson reports invalid JSON as a validation issue', () {
    expect(
      () => DriverManifest.parseJson('{nope'),
      throwsA(isA<ValidationException>()),
    );
  });

  group('rejects', () {
    test('a missing or unknown schema version', () {
      expect(
        issuesFor(validManifest()..remove('schemaVersion')),
        contains(r'$.schemaVersion: is required'),
      );
      expect(
        issuesFor(validManifest()..['schemaVersion'] = 2).single,
        contains('version 2 is not supported'),
      );
    });

    test('an id that is not lower snake case', () {
      expect(
        issuesFor(validManifest()..['id'] = 'Test-Light').single,
        contains(r'$.id'),
      );
    });

    test('an unknown transport and payload', () {
      final json = validManifest()
        ..['transport'] = {'type': 'carrier_pigeon', 'payload': 'xml'};
      final issues = issuesFor(json);
      expect(issues, hasLength(2));
      expect(issues.first, startsWith(r'$.transport.type'));
    });

    test('a transport the engine has no channel for yet', () {
      for (final (type, why) in [
        ('adb', 'adb arrives with M4'),
        ('tcp', 'tcp is not supported yet'),
      ]) {
        final json = validManifest()..['transport'] = {'type': type};
        expect(issuesFor(json), [r'$.transport.type: ' + why]);
      }
    });

    test('integer on a param that is not a number', () {
      final json = validManifest();
      (json['capabilities'] as List).add({
        'id': 'say',
        'type': 'text_command',
        'params': {
          'value': {'type': 'string', 'integer': true},
        },
        'command': {'text': '{{value}}'},
      });
      expect(
        issuesFor(json).single,
        startsWith(r'$.capabilities[3].params.value.integer'),
      );
    });

    test('a duplicate capability id', () {
      final json = validManifest();
      (json['capabilities'] as List).add({
        'id': 'temperature',
        'type': 'sensor',
      });
      expect(issuesFor(json).single, contains('duplicates "temperature"'));
    });

    test('a bare template name that is not a declared param', () {
      final json = validManifest();
      ((json['capabilities'] as List)[0] as Map)['command'] = {
        'state': '{{brightnes}}',
      };
      expect(
        issuesFor(json).single,
        contains('"brightnes", which is not a declared param'),
      );
    });

    test('a command on a sensor, and a missing command elsewhere', () {
      final json = validManifest();
      final caps = json['capabilities'] as List;
      caps[2] = <String, Object>{
        'id': 'temperature',
        'type': 'sensor',
        'command': {'x': 1},
      };
      (caps[0] as Map).remove('command');
      final issues = issuesFor(json);
      expect(issues, hasLength(2));
      expect(
        issues.join(),
        allOf(
          contains('a sensor has no command'),
          contains('is required for a toggle'),
        ),
      );
    });

    test('an enum param without values', () {
      final json = validManifest();
      final colorTemp = (json['capabilities'] as List)[1] as Map;
      (colorTemp['params'] as Map)['mode'] = {'type': 'enum'};
      expect(issuesFor(json).single, contains('non-empty list of strings'));
    });

    test('no capabilities at all', () {
      expect(
        issuesFor(validManifest()..['capabilities'] = []).single,
        contains('needs at least one capability'),
      );
    });

    test('and reports every issue in one pass', () {
      final json = validManifest()
        ..remove('name')
        ..['id'] = 'BAD'
        ..['transport'] = {'type': 'nope'};
      expect(issuesFor(json).length, 3);
    });
  });

  test('a manifest with an exec capability or exec transport is high risk', () {
    final json = validManifest();
    (json['capabilities'] as List).add({
      'id': 'run',
      'type': 'exec',
      'command': ['echo', 'hi'],
    });
    expect(DriverManifest.parse(json).isHighRisk, isTrue);
    final execTransport = validManifest()..['transport'] = {'type': 'exec'};
    expect(DriverManifest.parse(execTransport).isHighRisk, isTrue);
  });

  group('validateParams', () {
    final colorTemp = DriverManifest.parse(validManifest())
        .capability('color_temp')!;

    test('accepts in-range values and an omitted optional param', () {
      expect(colorTemp.validateParams({'value': 3000, 'brightness': 80}), {
        'value': 3000,
        'brightness': 80,
      });
      expect(colorTemp.validateParams({'value': 3000}), {'value': 3000});
    });

    test(
      'rejects out of range, wrong type, unknown and missing params together',
      () {
        try {
          colorTemp.validateParams({'brightness': 'loud', 'colour': 1});
          fail('expected a ValidationException');
        } on ValidationException catch (e) {
          final text = e.issues.join('\n');
          expect(text, contains('params.colour: is not a param'));
          expect(text, contains('params.value: is required'));
          expect(text, contains('params.brightness: must be a number'));
        }
        expect(
          () => colorTemp.validateParams({'value': 9000}),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test('an integer param takes whole numbers only, sent as an int', () {
      final brightness = DriverRegistry.withBuiltIns()['philips_wiz_udp']!
          .capability('brightness')!;
      final sent = brightness.validateParams({'value': 80.0});
      expect(sent['value'], isA<int>().having((v) => v, 'value', 80));
      expect(
        () => brightness.validateParams({'value': 50.5}),
        throwsA(
          isA<ValidationException>().having(
            (e) => '${e.issues}',
            'issues',
            contains('whole number'),
          ),
        ),
      );
    });

    test('a string param cannot smuggle a number check', () {
      final dpad = CapabilitySpec.parse(
        {
          'id': 'nav',
          'type': 'dpad_remote',
          'command': {'key': '{{value}}'},
        },
        r'$',
        IssueCollector(),
      )!;
      expect(dpad.validateParams({'value': 'up'}), {'value': 'up'});
      expect(
        () => dpad.validateParams({'value': 'up; reboot'}),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
