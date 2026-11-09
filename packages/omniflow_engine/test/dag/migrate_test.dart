import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

Map<String, Object?> flowWith(
  List<Map<String, Object?>> nodes, [
  List<Map<String, Object?>> edges = const [],
]) => {
  'schemaVersion': 1,
  'id': 'old',
  'name': 'Old',
  'nodes': nodes,
  'edges': edges,
};

Map<String, Object?> edge(String from, String port, String to) => {
  'id': '$from-$to',
  'from': {'node': from, 'port': port},
  'to': {'node': to, 'port': 'in'},
};

final _note = {
  'id': 'note',
  'type': 'notify',
  'config': {'title': 'hi'},
};

/// Node [id] of [flow] as its type and config, to compare whole.
List<Object?> typed(Map<String, Object?> flow, String id) {
  final (type, config) = nodeOf(flow, id);
  return [type, config];
}

/// The migrated config of node [id] in [flow], with its type.
(Object?, Map<String, Object?>) nodeOf(Map<String, Object?> flow, String id) {
  final n = (flow['nodes'] as List).cast<Map>().firstWhere(
    (n) => n['id'] == id,
  );
  return (n['type'], Map<String, Object?>.from(n['config'] as Map));
}

void main() {
  const context = FlowMigrationContext(
    places: {'desk': 'desk', 'home': 'home_place'},
    boards: {'deskboard': 'desk_board', 'hall-node': 'hall_board'},
  );

  Map<String, Object?> migrated(Map<String, Object?> node) =>
      migrateFlow(flowWith([node, _note], [edge('t', 'out', 'note')]), context);

  test('a flow with no retired type comes back as the same object', () {
    final flow = flowWith([
      {'id': 'go', 'type': 'manual'},
      _note,
    ]);
    expect(identical(migrateFlow(flow, context), flow), isTrue);
  });

  group('triggers', () {
    test('device_state with a key watches that state key', () {
      final flow = migrated({
        'id': 't',
        'type': 'device_state',
        'label': 'lamp changes',
        'config': {'deviceId': 'lamp', 'key': 'dimming'},
      });
      expect(typed(flow, 't'), [
        'on',
        {'thing': 'lamp', 'key': 'dimming'},
      ]);
      final node = (flow['nodes'] as List).first as Map;
      expect(node['label'], 'lamp changes');
    });

    test('device_state with no key watches any change', () {
      expect(
        typed(
          migrated({
            'id': 't',
            'type': 'device_state',
            'config': {'deviceId': 'lamp'},
          }),
          't',
        ),
        [
          'on',
          {'thing': 'lamp'},
        ],
      );
    });

    test('zone_change becomes the place inside turning true or false', () {
      expect(
        typed(
          migrated({
            'id': 't',
            'type': 'zone_change',
            'config': {'zoneId': 'home', 'transition': 'entered'},
          }),
          't',
        ),
        [
          'on',
          {
            'thing': 'home_place',
            'key': 'inside',
            'change': {'to': true},
          },
        ],
      );
      expect(
        nodeOf(
          migrated({
            'id': 't',
            'type': 'zone_change',
            'config': {'zoneId': 'garage', 'transition': 'exited'},
          }),
          't',
        ).$2,
        {
          'thing': 'garage',
          'key': 'inside',
          'change': {'to': false},
        },
      );
    });

    test('wifi_change watches the phone wifi_ssid, to one SSID or any', () {
      expect(
        nodeOf(
          migrated({
            'id': 't',
            'type': 'wifi_change',
            'config': {'ssid': 'HomeNet'},
          }),
          't',
        ).$2,
        {
          'thing': 'phone',
          'key': 'wifi_ssid',
          'change': {'to': 'HomeNet'},
        },
      );
      expect(
        nodeOf(
          migrated({'id': 't', 'type': 'wifi_change', 'config': {}}),
          't',
        ).$2,
        {'thing': 'phone', 'key': 'wifi_ssid', 'change': {}},
      );
    });

    test('board_event with a node becomes an event on that board', () {
      expect(
        typed(
          migrated({
            'id': 't',
            'type': 'board_event',
            'config': {'event': 'button_press', 'node': 'DeskBoard'},
          }),
          't',
        ),
        [
          'on',
          {'thing': 'desk_board', 'key': 'button_press', 'event': true},
        ],
      );
      expect(
        nodeOf(
          migrated({
            'id': 't',
            'type': 'board_event',
            'config': {'event': 'boot', 'node': 'pico-2'},
          }),
          't',
        ).$2['thing'],
        'pico_2',
      );
    });

    test('board_event from any board becomes one trigger per board', () {
      final flow = migrated({
        'id': 't',
        'type': 'board_event',
        'config': {'event': 'boot'},
      });
      expect(nodeOf(flow, 't').$2['thing'], 'desk_board');
      expect(nodeOf(flow, 't_hall_board').$2['thing'], 'hall_board');
      final edges = (flow['edges'] as List).cast<Map>();
      expect(
        edges.map((e) => (e['from'] as Map)['node']),
        unorderedEquals(['t', 't_hall_board']),
      );
      expect(edges.map((e) => e['id']).toSet(), hasLength(2));
      expect(
        validateFlow(
          FlowSpec.parse(flow),
          refs: const FlowReferences(devices: {'desk_board', 'hall_board'}),
        ),
        isEmpty,
      );
    });

    test('board_event from any board with no board cannot be migrated', () {
      expect(
        () => migrateFlow(
          flowWith([
            {
              'id': 't',
              'type': 'board_event',
              'config': {'event': 'boot'},
            },
          ]),
        ),
        throwsA(isA<FlowMigrationException>()),
      );
    });
  });

  group('conditions', () {
    test('var_equals on a global, a run variable and the message', () {
      for (final (name, side) in [
        (r'$Mode', {'var': r'$Mode'}),
        ('%count', {'var': '%count'}),
        ('msg.value', {'msg': 'value'}),
      ]) {
        expect(
          typed(
            migrated({
              'id': 'c',
              'type': 'var_equals',
              'config': {'name': name, 'value': 'home'},
            }),
            'c',
          ),
          [
            'compare',
            {
              'left': side,
              'op': '==',
              'right': {'literal': 'home'},
            },
          ],
        );
      }
    });

    test('var_compare keeps its operator', () {
      expect(
        nodeOf(
          migrated({
            'id': 'c',
            'type': 'var_compare',
            'config': {'name': r'$Lux', 'op': '<', 'value': 30},
          }),
          'c',
        ).$2,
        {
          'left': {'var': r'$Lux'},
          'op': '<',
          'right': {'literal': 30},
        },
      );
    });

    test('var_compare != still holds only for a number', () {
      final (type, config) = nodeOf(
        migrated({
          'id': 'c',
          'type': 'var_compare',
          'config': {'name': r'$Temp', 'op': '!=', 'value': 20},
        }),
        'c',
      );
      expect(
        validateFlow(
          FlowSpec.parse(
            flowWith(
              [
                {'id': 'go', 'type': 'manual'},
                {'id': 'c', 'type': type, 'config': config},
                _note,
              ],
              [edge('go', 'out', 'c'), edge('c', 'true', 'note')],
            ),
          ),
        ),
        isEmpty,
      );
      bool passes(Map<String, Object?> globals) => evaluateRule({
        ...config,
        'type': type,
      }, EvalContext(now: DateTime(2026), globals: globals));
      expect(passes({}), isFalse, reason: 'unset');
      expect(passes({'Temp': 'hot'}), isFalse, reason: 'not a number');
      expect(passes({'Temp': 20}), isFalse);
      expect(passes({'Temp': 25}), isTrue);
      expect(passes({'Temp': -3.5}), isTrue);
    });

    test('device_state_is reads the thing state', () {
      expect(
        nodeOf(
          migrated({
            'id': 'c',
            'type': 'device_state_is',
            'config': {'deviceId': 'lamp', 'key': 'state', 'value': true},
          }),
          'c',
        ).$2,
        {
          'left': {'state': 'lamp.state'},
          'op': '==',
          'right': {'literal': true},
        },
      );
    });

    test('rules nested in all_of, any_of, xor and not are rewritten', () {
      final (type, config) = nodeOf(
        migrated({
          'id': 'c',
          'type': 'all_of',
          'config': {
            'rules': [
              {'type': 'time_window', 'start': '18:00', 'end': '05:00'},
              {
                'type': 'not',
                'rule': {
                  'type': 'any_of',
                  'rules': [
                    {'type': 'var_equals', 'name': r'$Away', 'value': true},
                  ],
                },
              },
            ],
          },
        }),
        'c',
      );
      expect(type, 'all_of');
      final rules = config['rules'] as List;
      expect(rules.first, {
        'type': 'time_window',
        'start': '18:00',
        'end': '05:00',
      });
      expect(((rules.last as Map)['rule'] as Map)['rules'], [
        {
          'type': 'compare',
          'left': {'var': r'$Away'},
          'op': '==',
          'right': {'literal': true},
        },
      ]);
    });
  });

  group('message keys the on trigger renamed', () {
    Map<String, Object?> notify(String title) => {
      'id': 'note',
      'type': 'notify',
      'config': {'title': title, 'body': 'from {{ msg.zone | "nowhere" }}'},
    };

    Map<String, Object?> varEquals(String id, String name, Object value) => {
      'id': id,
      'type': 'var_equals',
      'config': {'name': name, 'value': value},
    };

    Map<String, Object?> compare(String id, String key, Object value) => {
      'id': id,
      'type': 'compare',
      'config': {
        'left': {'literal': value},
        'op': '==',
        'right': {'msg': key},
      },
    };

    Map<String, Object?> withTrigger(
      Map<String, Object?> trigger,
      List<Map<String, Object?>> rest,
    ) => migrateFlow(flowWith([trigger, ...rest]), context);

    test('msg.zone becomes msg.thing, the place, in a zone_change flow', () {
      final flow = withTrigger(
        {
          'id': 't',
          'type': 'zone_change',
          'config': {'zoneId': 'home', 'transition': 'entered'},
        },
        [
          notify('At {{msg.zone}}, was {{msg.zone|msg.previous}}'),
          varEquals('is_home', 'msg.zone', 'home'),
          compare('is_desk', 'zone', 'desk'),
          compare('keeps', 'zoneName', 'x'),
        ],
      );
      expect(nodeOf(flow, 'note').$2, {
        'title': 'At {{msg.thing}}, was {{msg.thing|msg.previous}}',
        'body': 'from {{ msg.thing | "nowhere" }}',
      });
      expect(nodeOf(flow, 'is_home').$2, {
        'left': {'msg': 'thing'},
        'op': '==',
        'right': {'literal': 'home_place'},
      });
      expect(nodeOf(flow, 'is_desk').$2, {
        'left': {'literal': 'desk'},
        'op': '==',
        'right': {'msg': 'thing'},
      });
      expect(
        (nodeOf(flow, 'keeps').$2['right'] as Map)['msg'],
        'zoneName',
        reason: 'only the key itself is renamed',
      );
    });

    test('msg.ssid becomes msg.value in a wifi_change flow', () {
      final flow = withTrigger(
        {
          'id': 't',
          'type': 'wifi_change',
          'config': {'ssid': 'HomeNet'},
        },
        [
          notify('Connected to {{msg.ssid}}'),
          varEquals('on_home', 'msg.ssid', 'HomeNet'),
        ],
      );
      expect(nodeOf(flow, 'note').$2['title'], 'Connected to {{msg.value}}');
      expect(
        nodeOf(flow, 'note').$2['body'],
        'from {{ msg.zone | "nowhere" }}',
        reason: 'a flow with no zone_change keeps msg.zone',
      );
      expect(nodeOf(flow, 'on_home').$2['left'], {'msg': 'value'});
    });

    test('msg.node becomes msg.payload.node in a board_event flow', () {
      final flow = withTrigger(
        {
          'id': 't',
          'type': 'board_event',
          'config': {'event': 'button_press', 'node': 'deskboard'},
        },
        [
          notify('{{msg.node}} pressed'),
          compare('is_desk', 'node', 'deskboard'),
          varEquals('also', 'msg.node', 'deskboard'),
        ],
      );
      expect(nodeOf(flow, 'note').$2['title'], '{{msg.payload.node}} pressed');
      expect(nodeOf(flow, 'is_desk').$2['right'], {'msg': 'payload.node'});
      expect(nodeOf(flow, 'also').$2['left'], {'msg': 'payload.node'});
    });

    test('a flow without the old trigger keeps the key', () {
      final flow = withTrigger(
        {
          'id': 't',
          'type': 'device_state',
          'config': {'deviceId': 'lamp', 'key': 'power'},
        },
        [
          notify('{{msg.zone}} {{msg.ssid}} {{msg.node}}'),
          varEquals('z', 'msg.zone', 'home'),
        ],
      );
      expect(
        nodeOf(flow, 'note').$2['title'],
        '{{msg.zone}} {{msg.ssid}} {{msg.node}}',
      );
      expect(nodeOf(flow, 'z').$2, {
        'left': {'msg': 'zone'},
        'op': '==',
        'right': {'literal': 'home'},
      });
    });

    test('migrating a migrated flow changes nothing', () {
      final once = withTrigger(
        {
          'id': 't',
          'type': 'board_event',
          'config': {'event': 'button_press', 'node': 'deskboard'},
        },
        [notify('{{msg.node}}')],
      );
      expect(identical(migrateFlow(once, context), once), isTrue);
    });
  });

  test('the old threshold link flow migrates to a valid flow', () {
    final old = flowWith(
      [
        {
          'id': 'source',
          'type': 'device_state',
          'config': {'deviceId': 'desk', 'key': 'light'},
        },
        {
          'id': 'crossed',
          'type': 'all_of',
          'config': {
            'rules': [
              {
                'type': 'var_compare',
                'name': 'msg.value',
                'op': '<',
                'value': 30,
              },
              {
                'type': 'not',
                'rule': {
                  'type': 'var_compare',
                  'name': 'msg.previous',
                  'op': '<',
                  'value': 30,
                },
              },
            ],
          },
        },
        _note,
      ],
      [edge('source', 'out', 'crossed'), edge('crossed', 'true', 'note')],
    );
    final flow = migrateFlow(old);
    expect(
      validateFlow(
        FlowSpec.parse(flow),
        refs: const FlowReferences(devices: {'desk'}),
      ),
      isEmpty,
    );
    expect(identical(migrateFlow(flow), flow), isTrue);
  });

  test('an old threshold link reads back as a threshold spec', () {
    Map<String, Object?> old(String op, num limit, Object? set) => flowWith(
      [
        {
          'id': 'source',
          'type': 'device_state',
          'config': {'deviceId': 'desk', 'key': 'light'},
        },
        {
          'id': 'crossed',
          'type': 'all_of',
          'config': {
            'rules': [
              {
                'type': 'var_compare',
                'name': 'msg.value',
                'op': op,
                'value': limit,
              },
              {
                'type': 'not',
                'rule': {
                  'type': 'var_compare',
                  'name': 'msg.previous',
                  'op': op,
                  'value': limit,
                },
              },
            ],
          },
        },
        {
          'id': 'apply',
          'type': 'device_capability',
          'config': {
            'deviceId': 'lamp',
            'capabilityId': 'relay',
            'params': {'value': set},
          },
        },
      ],
      [edge('source', 'out', 'crossed'), edge('crossed', 'true', 'apply')],
    );
    expect(linkSpecFromFlow(migrateFlow(old('<', 30, true))), {
      'from': 'desk.light',
      'to': 'lamp.relay',
      'mode': 'threshold',
      'below': 30,
      'set': true,
    });
    expect(linkSpecFromFlow(migrateFlow(old('>', 60, false))), {
      'from': 'desk.light',
      'to': 'lamp.relay',
      'mode': 'threshold',
      'above': 60,
      'set': false,
    });
  });

  test('links are written with the on trigger and compare', () {
    const relay = CapabilitySpec(
      id: 'relay',
      type: CapabilityType.toggle,
      label: 'relay',
      params: {'value': ParamSpec(type: ParamType.boolean)},
      command: {'cmd': 'relay'},
      stateJsonPath: r'$.relay',
    );
    LinkRequest link(LinkMode mode, {num? below, Object? set}) => LinkRequest(
      from: LinkEnd.parse('desk.button', 'from'),
      to: LinkEnd.parse('lamp.relay', 'to'),
      mode: mode,
      target: relay,
      below: below,
      set: set,
    );
    final toggle = link(LinkMode.toggle).toFlow();
    expect(typed(toggle, 'source'), [
      'on',
      {'thing': 'desk', 'key': 'button'},
    ]);
    expect(typed(toggle, 'pressed'), [
      'compare',
      {
        'left': {'msg': 'value'},
        'op': '==',
        'right': {'literal': true},
      },
    ]);
    final threshold = link(LinkMode.threshold, below: 30, set: true).toFlow();
    expect(nodeOf(threshold, 'source').$2, {
      'thing': 'desk',
      'key': 'button',
      'crosses': {'below': 30},
    });
    expect((threshold['nodes'] as List).cast<Map>().map((n) => n['type']), [
      'on',
      'device_capability',
    ]);
  });
}
