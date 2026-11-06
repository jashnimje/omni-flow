@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  late Process board;
  late String tty;
  late SerialChannel channel;
  late DeviceService service;
  late InMemoryDeviceStore store;

  setUp(() async {
    board = await Process.start('python3', [
      '-I',
      'test/fixtures/pty_board.py',
    ]);
    tty =
        (await board.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first)
            .trim();
    channel = SerialChannel();
    store = InMemoryDeviceStore();
    service = DeviceService(
      registry: DriverRegistry.withBuiltIns(),
      store: store,
      channels: {TransportType.serial: channel},
    );
    await store.put(
      Device(
        id: 'pico_usb',
        name: 'Pico on USB',
        driverId: 'omniflow_mcu_serial',
        host: tty,
      ),
    );
  });

  tearDown(() async {
    await channel.close();
    board.kill();
  });

  test('a command over the tty gets the ack carrying its id', () async {
    final result = await service.invoke('pico_usb', 'led', {'value': true});
    expect(result.reply.json, containsPair('event', 'ack'));
    expect(result.reply.json!['id'], 1);
  });

  test('an unsolicited line becomes a serial event', () async {
    final event = channel.events.first;
    await service.invoke('pico_usb', 'ir_nec', {'address': 4, 'command': 8});
    final got = await event.timeout(const Duration(seconds: 2));
    expect(got.deviceId, 'pico_usb');
    expect(got.json, containsPair('event', 'button_press'));
  });

  test('a board error fails the command', () async {
    await store.put(
      Device(
        id: 'pico_usb',
        name: 'x',
        driverId: 'omniflow_mcu_serial',
        host: tty,
      ),
    );
    final registry = DriverRegistry.withBuiltIns()
      ..register({
        'schemaVersion': 1,
        'id': 'raw_board',
        'name': 'Raw',
        'category': 'microcontroller',
        'transport': {'type': 'serial'},
        'capabilities': [
          {
            'id': 'gpio_write',
            'type': 'action',
            'params': {
              'pin': {'type': 'number'},
            },
            'command': {'cmd': 'gpio_write', 'pin': '{{pin}}', 'value': 1},
          },
        ],
      });
    final raw = DeviceService(
      registry: registry,
      store: store,
      channels: {TransportType.serial: channel},
    );
    await store.put(
      Device(id: 'raw', name: 'Raw', driverId: 'raw_board', host: tty),
    );
    await expectLater(
      raw.invoke('raw', 'gpio_write', {'pin': 25}),
      throwsA(isA<CommandFailedException>()),
    );
  });

  test(
    'discover finds the board that answers describe and skips other ports',
    () async {
      final manifest = DriverRegistry.withBuiltIns()['omniflow_mcu_serial']!;
      final found = await channel.discover(
        manifest,
        ports: () async => ['/dev/cu.not-there', tty],
      );
      expect(found.single['host'], tty);
      expect(found.single['stableId'], 'pty_board');
    },
  );

  test('a missing port is a transport timeout', () async {
    await store.put(
      const Device(
        id: 'gone',
        name: 'Gone',
        driverId: 'omniflow_mcu_serial',
        host: '/dev/cu.not-there',
      ),
    );
    await expectLater(
      service.invoke('gone', 'led', {'value': true}),
      throwsA(isA<TransportTimeoutException>()),
    );
  });
}
