import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// A loopback board speaking the OmniFlow MCU protocol v1, like firmware/pico_w.
class FakeBoard {
  FakeBoard._(this.udp) {
    udp.incoming.listen((d) {
      final cmd = jsonDecode(d.text) as Map<String, Object?>;
      received.add(cmd);
      if (staleFirst) {
        staleFirst = false;
        _reply(d, {'event': 'ack', 'cmd': cmd['cmd'], 'id': -1});
      }
      final reply = switch (cmd['cmd']) {
        'describe' => {
          'event': 'describe',
          'fw': 'omniflow-pico/1',
          'capabilities': ['nec_ir', 'led'],
          'pins': {
            'out': [16, 17, 18],
          },
        },
        'gpio_write' when !(const [16, 17, 18]).contains(cmd['pin']) => {
          'event': 'error',
          'message': 'pin not allowed',
        },
        final name => {'event': 'ack', 'cmd': name},
      };
      _reply(d, {...reply, 'node': 'pico_desk_01', 'id': cmd['id']});
    });
  }

  static Future<FakeBoard> start() async =>
      FakeBoard._(await UdpTransport.bind());

  final UdpTransport udp;
  final received = <Map<String, Object?>>[];
  bool staleFirst = false;

  void _reply(UdpDatagram d, Map<String, Object?> payload) =>
      udp.send(d.address, d.port, utf8.encode(jsonEncode(payload)));
}

void main() {
  late FakeBoard board;
  late UdpTransport udp;
  late InMemoryDeviceStore store;
  late DeviceService service;

  setUp(() async {
    board = await FakeBoard.start();
    udp = await UdpTransport.bind();
    store = InMemoryDeviceStore();
    service = DeviceService(
      registry: DriverRegistry.withBuiltIns(),
      store: store,
      channels: {TransportType.udp: UdpJsonChannel(udp)},
    );
    await store.put(
      Device(
        id: 'pico',
        name: 'Desk Pico',
        driverId: 'omniflow_mcu_node',
        host: InternetAddress.loopbackIPv4.address,
        port: board.udp.localPort,
      ),
    );
  });

  tearDown(() {
    udp.close();
    board.udp.close();
  });

  test('an IR send carries a request id and gets its ack', () async {
    final result = await service.invoke('pico', 'ir_send', {
      'value': '0x20DF10EF',
    });
    expect(board.received.single, {
      'cmd': 'ir_send',
      'protocol': 'NEC',
      'hex': '0x20DF10EF',
      'id': 1,
    });
    expect(result.reply.json!['event'], 'ack');
  });

  test('an NEC address and command go out as numbers', () async {
    await service.invoke('pico', 'ir_nec', {'address': 4, 'command': 8});
    expect(board.received.single, {
      'cmd': 'ir_send',
      'protocol': 'NEC',
      'address': 4,
      'command': 8,
      'id': 1,
    });
    await expectLater(
      service.invoke('pico', 'ir_nec', {'address': 4, 'command': 300}),
      throwsA(isA<ValidationException>()),
    );
  });

  test('each command gets a new id', () async {
    await service.invoke('pico', 'led', {'value': true});
    await service.invoke('pico', 'led', {'value': false});
    expect(board.received.map((c) => c['id']), [1, 2]);
  });

  test('a stale reply with another id is ignored', () async {
    board.staleFirst = true;
    final result = await service.invoke('pico', 'led', {'value': true});
    expect(result.reply.json!['id'], 1);
  });

  test('a board error fails the command', () async {
    await expectLater(
      service.invoke('pico', 'gpio_write', {'pin': 25, 'value': true}),
      throwsA(
        isA<CommandFailedException>().having(
          (e) => e.message,
          'message',
          contains('pin not allowed'),
        ),
      ),
    );
  });

  test('an IR code in the wrong format never leaves the phone', () async {
    await expectLater(
      service.invoke('pico', 'ir_send', {'value': 'power'}),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      service.invoke('pico', 'ir_send', {'value': '0x20DF10EF00'}),
      throwsA(isA<ValidationException>()),
    );
    expect(board.received, isEmpty);
  });

  test('describe as the poll fills the device state', () async {
    final device = await service.refreshState('pico');
    expect(device.state['fw'], 'omniflow-pico/1');
    expect(device.state['pins'], {
      'out': [16, 17, 18],
    });
  });

  test('a pattern is only allowed on a string param and must compile', () {
    final issues = IssueCollector();
    ParamSpec.parse({'type': 'number', 'pattern': 'x'}, r'$.p', issues);
    ParamSpec.parse({'type': 'string', 'pattern': '('}, r'$.q', issues);
    expect(issues.issues.map((i) => i.path), [r'$.p.pattern', r'$.q.pattern']);
  });
}
