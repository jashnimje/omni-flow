@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/v1_drivers.dart';

/// The tty opened for writing, as the channel's own sink does it.
class TtySink implements SerialSink {
  TtySink(this._file);

  static Future<TtySink> open(String path) async =>
      TtySink(await File(path).open(mode: FileMode.writeOnly));

  final RandomAccessFile _file;

  @override
  Future<void> write(List<int> bytes) async {
    await _file.writeFrom(bytes);
    await _file.flush();
  }

  @override
  Future<void> close() => _file.close();
}

/// A port whose writes never complete, like a tty held by flow control.
class StuckSink implements SerialSink {
  var writes = 0;
  var closed = false;

  @override
  Future<void> write(List<int> bytes) {
    writes++;
    return Completer<void>().future;
  }

  @override
  Future<void> close() async => closed = true;
}

/// Runs commands for real and notes, for each, how many sinks were open.
class RecordingExecutor implements HostExecutor {
  RecordingExecutor(this.openSinks);

  final int Function() openSinks;
  final calls = <(List<String>, int)>[];

  @override
  Future<CommandResult> run(
    List<String> argv, {
    String? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) {
    calls.add((argv, openSinks()));
    return const LocalExecutor().run(argv, stdin: stdin, timeout: timeout);
  }
}

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
      registry: v1Registry(),
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
    final registry = v1Registry()
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
      final manifest = v1Registry()['omniflow_mcu_serial']!;
      final found = await channel.discover(
        manifest,
        ports: () async => ['/dev/cu.not-there', tty],
      );
      expect(found.single['host'], tty);
      expect(found.single['stableId'], 'pty_board');
    },
  );

  test(
    'discover asks a port a device holds through that device\'s port',
    () async {
      await service.invoke('pico_usb', 'led', {'value': true});
      final stray = <SerialEvent>[];
      channel.events
          .where((e) => e.json['event'] == 'describe')
          .listen(stray.add);
      final manifest = v1Registry()['omniflow_mcu_serial']!;
      for (var round = 0; round < 4; round++) {
        final found = await channel.discover(
          manifest,
          ports: () async => [tty],
        );
        expect(found.single['stableId'], 'pty_board', reason: 'round $round');
        final ack = await service.invoke('pico_usb', 'led', {'value': false});
        expect(ack.reply.json, containsPair('event', 'ack'));
      }
      expect(stray, isEmpty);
    },
  );

  DeviceService serviceWith(SerialChannel other) => DeviceService(
    registry: v1Registry(),
    store: store,
    channels: {TransportType.serial: other},
  );

  test(
    'stty sets raw, no echo and no hang-up while the port is held open',
    () async {
      var open = 0;
      final executor = RecordingExecutor(() => open);
      final held = SerialChannel(
        executor: executor,
        openSink: (path) async {
          open++;
          return TtySink.open(path);
        },
      );
      addTearDown(held.close);
      final result = await serviceWith(held)
          .invoke('pico_usb', 'led', {'value': true});
      expect(result.reply.json, containsPair('event', 'ack'));
      final (argv, sinksOpen) = executor.calls.single;
      expect(argv.first, '/bin/stty');
      expect(argv, containsAllInOrder([tty, '115200', 'raw', '-echo']));
      expect(argv, contains('-hupcl'));
      expect(sinksOpen, 1, reason: 'stty must run on a held descriptor');
    },
  );

  test('a write that never completes fails within the timeout', () async {
    final sinks = <StuckSink>[];
    final stuck = SerialChannel(
      openSink: (_) async {
        final sink = StuckSink();
        sinks.add(sink);
        return sink;
      },
    );
    addTearDown(stuck.close);
    final clock = Stopwatch()..start();
    await expectLater(
      serviceWith(stuck).invoke('pico_usb', 'led', {'value': true}),
      throwsA(isA<TransportTimeoutException>()),
    );
    // 800 ms per attempt, one retry, in omniflow_mcu_serial.
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
    expect(sinks, hasLength(2), reason: 'the stuck port is opened again');
    expect(sinks.map((s) => s.writes), everyElement(1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sinks.map((s) => s.closed), everyElement(isTrue));
  });

  test('after a stuck write the retry reopens the port and works', () async {
    var opens = 0;
    final recovering = SerialChannel(
      openSink: (path) async =>
          ++opens == 1 ? StuckSink() : await TtySink.open(path),
    );
    addTearDown(recovering.close);
    final result = await serviceWith(recovering)
        .invoke('pico_usb', 'led', {'value': true});
    expect(result.reply.json, containsPair('event', 'ack'));
    expect(opens, 2);
  });

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
