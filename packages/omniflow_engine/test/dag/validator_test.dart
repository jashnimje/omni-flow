import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

final _registry = DriverRegistry.withBuiltIns();
const _devices = {'desk_lamp': 'philips_wiz_udp', 'mac_mini': 'macos_host'};

final refs = FlowReferences(
  devices: _devices.keys.toSet(),
  zones: const {'desk'},
  flows: const {'other_flow'},
  capabilityOf: (d, c) => _registry[_devices[d]!]?.capability(c),
);

/// The evening-desk flow from docs/DESIGN.md.
Map<String, Object?> eveningFlow() => {
  'schemaVersion': 1,
  'id': 'flow_arrive_desk_evening',
  'name': 'Evening desk arrival',
  'enabled': true,
  'mode': 'single',
  'cooldownSeconds': 1800,
  'nodes': <Object?>[
    {
      'id': 'trig_desk',
      'type': 'zone_change',
      'config': {'zoneId': 'desk', 'transition': 'entered'},
    },
    {
      'id': 'cond_evening',
      'type': 'all_of',
      'config': {
        'rules': [
          {'type': 'time_window', 'start': '18:00', 'end': '05:00'},
          {'type': 'var_equals', 'name': r'$HomeWifiConnected', 'value': true},
        ],
      },
    },
    {
      'id': 'act_lamp',
      'type': 'device_capability',
      'config': {
        'deviceId': 'desk_lamp',
        'capabilityId': 'color_temp',
        'params': {'value': 3000, 'brightness': 80},
      },
    },
    {
      'id': 'act_mac',
      'type': 'device_capability',
      'config': {
        'deviceId': 'mac_mini',
        'capabilityId': 'display_wake',
        'params': {},
      },
    },
  ],
  'edges': <Object?>[
    {
      'id': 'e1',
      'from': {'node': 'trig_desk', 'port': 'out'},
      'to': {'node': 'cond_evening', 'port': 'in'},
    },
    {
      'id': 'e2',
      'from': {'node': 'cond_evening', 'port': 'true'},
      'to': {'node': 'act_lamp', 'port': 'in'},
    },
    {
      'id': 'e3',
      'from': {'node': 'cond_evening', 'port': 'true'},
      'to': {'node': 'act_mac', 'port': 'in'},
    },
  ],
};

List<String> issues(Map<String, Object?> json) => validateFlow(
  FlowSpec.parse(json),
  refs: refs,
).map((i) => i.toString()).toList();

List<Map<String, Object?>> nodesOf(Map<String, Object?> f) =>
    (f['nodes'] as List).cast<Map<String, Object?>>();
List<Map<String, Object?>> edgesOf(Map<String, Object?> f) =>
    (f['edges'] as List).cast<Map<String, Object?>>();

void main() {
  test('the evening-desk flow from the design is valid and round-trips', () {
    final flow = parseAndValidateFlow(eveningFlow(), refs: refs);
    expect(flow.mode, RunMode.single);
    expect(flow.cooldownSeconds, 1800);
    expect(flow.edgesFrom('cond_evening', 'true').map((e) => e.to.node), [
      'act_lamp',
      'act_mac',
    ]);
    expect(FlowSpec.parse(flow.toJson()).toJson(), flow.toJson());
  });

  group('shape errors from FlowSpec.parse', () {
    test('a missing schema version, bad id and unknown mode', () {
      final json = eveningFlow()
        ..remove('schemaVersion')
        ..['id'] = 'Bad Id'
        ..['mode'] = 'chaotic';
      expect(
        () => FlowSpec.parse(json),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.issues.length,
            'issues',
            3,
          ),
        ),
      );
    });

    test('a flow with no nodes', () {
      expect(
        () => FlowSpec.parse(eveningFlow()..['nodes'] = []),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('graph errors from validateFlow', () {
    test('duplicate node and edge ids', () {
      final json = eveningFlow();
      nodesOf(json)[3]['id'] = 'act_lamp';
      edgesOf(json)[2]['id'] = 'e1';
      final got = issues(json);
      expect(got.where((i) => i.contains('duplicates')), hasLength(2));
    });

    test('an unknown node type', () {
      final json = eveningFlow();
      nodesOf(json)[3]['type'] = 'teleport';
      expect(
        issues(json),
        contains(r'$.nodes[3].type: unknown node type teleport'),
      );
    });

    test('an edge from a port the node does not have, and into a trigger', () {
      final json = eveningFlow();
      (edgesOf(json)[1]['from'] as Map)['port'] = 'maybe';
      edgesOf(json).add({
        'id': 'e4',
        'from': {'node': 'act_lamp', 'port': 'out'},
        'to': {'node': 'trig_desk', 'port': 'in'},
      });
      final got = issues(json).join('\n');
      expect(got, contains('all_of has no output port maybe'));
      expect(got, contains('trig_desk is a trigger and takes no input'));
    });

    test('a cycle names the nodes in it', () {
      final json = eveningFlow();
      edgesOf(json).add({
        'id': 'e4',
        'from': {'node': 'act_lamp', 'port': 'out'},
        'to': {'node': 'cond_evening', 'port': 'in'},
      });
      expect(
        issues(json).join(),
        contains('cycle through act_lamp, cond_evening'),
      );
    });

    test('a node no trigger reaches, and a flow with no trigger', () {
      final json = eveningFlow();
      edgesOf(json).removeAt(2);
      expect(
        issues(json),
        contains(r'$.nodes[3]: act_mac is not reachable from any trigger'),
      );
      final noTrigger = eveningFlow();
      nodesOf(noTrigger).removeAt(0);
      edgesOf(noTrigger).removeAt(0);
      expect(
        issues(noTrigger),
        contains(r'$.nodes: needs at least one trigger'),
      );
    });
  });

  group('config errors', () {
    test('a bad time, an unknown zone and transition', () {
      final json = eveningFlow();
      nodesOf(json)[0]['config'] = {
        'zoneId': 'garage',
        'transition': 'hovering',
      };
      ((nodesOf(json)[1]['config'] as Map)['rules'] as List)[0] = {
        'type': 'time_window',
        'start': '25:00',
        'end': '05:00',
      };
      final got = issues(json).join('\n');
      expect(got, contains('no zone garage'));
      expect(got, contains('must be one of entered, exited'));
      expect(got, contains('must be a 24-hour time'));
    });

    test(
      'device actions are checked against the capability, literal params only',
      () {
        final json = eveningFlow();
        nodesOf(json)[2]['config'] = {
          'deviceId': 'desk_lamp',
          'capabilityId': 'color_temp',
          'params': {'value': 9000, 'colour': 'red'},
        };
        nodesOf(json)[3]['config'] = {
          'deviceId': 'mac_mini',
          'capabilityId': 'fly',
          'params': {},
        };
        final got = issues(json).join('\n');
        expect(got, contains('params.value: must be at most 6500'));
        expect(got, contains('params.colour: is not a param of color_temp'));
        expect(got, contains('mac_mini has no capability fly'));
      },
    );

    test('a templated param is left for run time', () {
      final json = eveningFlow();
      nodesOf(json)[2]['config'] = {
        'deviceId': 'desk_lamp',
        'capabilityId': 'brightness',
        'params': {'value': '{{msg.value}}'},
      };
      expect(issues(json), isEmpty);
    });

    test('nested rules are checked all the way down', () {
      final json = eveningFlow();
      nodesOf(json)[1]['config'] = {
        'rules': [
          {
            'type': 'not',
            'rule': {
              'type': 'any_of',
              'rules': [
                {
                  'type': 'var_compare',
                  'name': 'HomeMode',
                  'op': '~',
                  'value': 'x',
                },
              ],
            },
          },
        ],
      };
      final got = issues(json).join('\n');
      expect(got, contains(r'must be $Name or %name'));
      expect(got, contains('must be one of <, <=, >, >=, ==, !='));
      expect(got, contains('value: must be a number'));
    });

    test('transformer and flow control configs', () {
      final json = eveningFlow();
      nodesOf(json).addAll([
        {
          'id': 'x1',
          'type': 'jsonpath',
          'config': {'path': r'$..[['},
        },
        {
          'id': 'x2',
          'type': 'regex',
          'config': {'pattern': '('},
        },
        {
          'id': 'x3',
          'type': 'range_map',
          'config': {'inMin': 0, 'inMax': 0, 'outMin': 0, 'outMax': 'a'},
        },
        {
          'id': 'x4',
          'type': 'repeat',
          'config': {'maxIterations': 5000},
        },
      ]);
      for (final id in ['x1', 'x2', 'x3', 'x4']) {
        edgesOf(json).add({
          'id': 'to_$id',
          'from': {'node': 'trig_desk', 'port': 'out'},
          'to': {'node': id, 'port': 'in'},
        });
      }
      final got = issues(json).join('\n');
      expect(got, contains('is not valid JSONPath'));
      expect(got, contains('is not a valid regular expression'));
      expect(got, contains('inMin and inMax must differ'));
      expect(got, contains('outMax: must be a number'));
      expect(got, contains('maxIterations: must be between 1 and 1000'));
    });
  });
}
