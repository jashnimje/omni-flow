import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  final registry = DriverRegistry.withBuiltIns();
  final devices = [
    CommandDevice('desk_lamp', 'Desk lamp', registry['philips_wiz_udp']!),
    CommandDevice('desk', 'Desk', registry['tuya_plug']!),
    CommandDevice('pico', 'Desk Pico', registry['omniflow_mcu_node']!),
  ];
  const flows = [CommandFlow('evening_desk', 'Evening desk')];
  Map<String, Object?> read(String text) =>
      interpretCommand(text, devices, flows).toJson();

  test('percent, kelvin, colour and on or off pick the right capability', () {
    expect(read('> Desk lamp 50%'), {
      'kind': 'call',
      'command': 'device.invoke',
      'args': {
        'id': 'desk_lamp',
        'capability': 'brightness',
        'params': {'value': 50},
      },
      'summary': 'Desk lamp: 50%',
    });
    expect(
      (read('desk lamp 3000K')['args'] as Map)['capability'],
      'color_temp',
    );
    expect((read('desk lamp #ff8800')['args'] as Map)['params'], {
      'r': 255,
      'g': 136,
      'b': 0,
    });
    expect((read('desk lamp off')['args'] as Map)['params'], {'value': false});
  });

  test('the longest matching name wins', () {
    expect((read('desk on')['args'] as Map)['id'], 'desk');
    expect((read('desk lamp on')['args'] as Map)['id'], 'desk_lamp');
    expect((read('desk pico led on')['args'] as Map)['id'], 'pico');
  });

  test('a capability by id with a value', () {
    expect(read('desk pico ir_send 0x20DF10EF')['args'], {
      'id': 'pico',
      'capability': 'ir_send',
      'params': {'value': '0x20DF10EF'},
    });
    expect((read('desk pico led on')['args'] as Map)['params'], {
      'value': true,
    });
  });

  test('run a flow by id or name', () {
    expect(read('run Evening desk')['args'], {'id': 'evening_desk'});
    expect(read('run evening_desk')['command'], 'flow.run');
  });

  test('anything else goes to the architect', () {
    expect(read('turn everything off when I leave')['kind'], 'ask');
    expect(read('desk lamp sparkle')['kind'], 'ask');
    expect(read('run nothing')['kind'], 'ask');
  });

  group('card projection', () {
    FlowSpec flow(List<Map<String, Object?>> nodes, List<List<String>> edges) =>
        FlowSpec.parse({
          'schemaVersion': 1,
          'id': 'f',
          'name': 'F',
          'nodes': nodes,
          'edges': [
            for (final (i, e) in edges.indexed)
              {
                'id': 'e$i',
                'from': {'node': e[0], 'port': e[1]},
                'to': {'node': e[2], 'port': 'in'},
              },
          ],
        });
    Map<String, Object?> n(String id, String type) => {'id': id, 'type': type};

    test('the evening flow becomes WHEN, IF, THEN with two actions', () {
      final cards = projectCards(
        flow(
          [
            n('trig', 'manual'),
            n('cond', 'all_of'),
            n('lamp', 'device_capability'),
            n('mac', 'device_capability'),
            n('note', 'notify'),
          ],
          [
            ['trig', 'out', 'cond'],
            ['cond', 'true', 'lamp'],
            ['cond', 'true', 'mac'],
            ['cond', 'false', 'note'],
          ],
        ),
      )!;
      expect(cards.toJson(), {
        'when': [
          {'node': 'trig', 'type': 'manual', 'label': 'trig'},
        ],
        'then': [
          {
            'kind': 'if',
            'node': 'cond',
            'type': 'all_of',
            'label': 'cond',
            'then': [
              {
                'kind': 'step',
                'node': 'lamp',
                'type': 'device_capability',
                'label': 'lamp',
              },
              {
                'kind': 'step',
                'node': 'mac',
                'type': 'device_capability',
                'label': 'mac',
              },
            ],
            'else': [
              {
                'kind': 'step',
                'node': 'note',
                'type': 'notify',
                'label': 'note',
              },
            ],
          },
        ],
      });
    });

    test('two triggers into one first step still fit on cards', () {
      final cards = projectCards(
        flow(
          [n('a', 'manual'), n('b', 'manual'), n('lamp', 'device_capability')],
          [
            ['a', 'out', 'lamp'],
            ['b', 'out', 'lamp'],
          ],
        ),
      );
      expect(cards!.when.map((t) => t.id), ['a', 'b']);
    });

    test('a join after the first step needs the canvas', () {
      final cards = projectCards(
        flow(
          [
            n('t', 'manual'),
            n('x', 'delay'),
            n('y', 'delay'),
            n('lamp', 'device_capability'),
          ],
          [
            ['t', 'out', 'x'],
            ['t', 'out', 'y'],
            ['x', 'out', 'lamp'],
            ['y', 'out', 'lamp'],
          ],
        ),
      );
      expect(cards, isNull);
    });
  });
}
