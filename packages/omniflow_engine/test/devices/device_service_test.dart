import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Records every request and replays scripted outcomes.
class FakeChannel implements DriverChannel {
  final requests = <ChannelRequest>[];
  final outcomes = <FutureOr<ChannelReply> Function(ChannelRequest)>[];

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    requests.add(request);
    if (outcomes.isEmpty) return const ChannelReply({'result': 'ok'});
    return outcomes.removeAt(0)(request);
  }
}

Device lamp({
  String host = '10.0.0.5',
  int? port,
  String? stableId = 'a8bb50aabbcc',
}) => Device(
  id: 'desk_lamp',
  name: 'Desk lamp',
  driverId: 'philips_wiz_udp',
  host: host,
  port: port,
  stableId: stableId,
  state: const {'state': true, 'dimming': 30, 'temp': 2700},
);

void main() {
  late InMemoryDeviceStore store;
  late FakeChannel channel;
  final now = DateTime.utc(2026, 11, 6, 18, 30);

  DeviceService service({DeviceLocator? locator}) => DeviceService(
    registry: DriverRegistry.withBuiltIns(),
    store: store,
    channels: {TransportType.udp: channel},
    locator: locator,
    clock: () => now,
  );

  setUp(() {
    store = InMemoryDeviceStore();
    channel = FakeChannel();
  });

  test('invoke validates, sends, and writes optimistic state', () async {
    await store.put(lamp());
    final result = await service().invoke('desk_lamp', 'brightness', {
      'value': 80,
    });
    expect(channel.requests.single.context.params, {'value': 80});
    expect(result.device.state['dimming'], 80);
    expect(result.device.lastSeen, now);
    expect((await store.get('desk_lamp'))!.state['dimming'], 80);
  });

  test('invalid params never reach the channel', () async {
    await store.put(lamp());
    await expectLater(
      service().invoke('desk_lamp', 'brightness', {'value': 5}),
      throwsA(isA<ValidationException>()),
    );
    expect(channel.requests, isEmpty);
  });

  test('unknown device, driver and capability are reported', () async {
    await store.put(lamp());
    await store.put(
      const Device(id: 'ghost', name: 'g', driverId: 'nope', host: 'x'),
    );
    final s = service();
    await expectLater(
      s.invoke('missing', 'power', {'value': true}),
      throwsA(isA<DeviceNotFoundException>()),
    );
    await expectLater(
      s.invoke('ghost', 'power', {'value': true}),
      throwsA(isA<DeviceNotFoundException>()),
    );
    await expectLater(
      s.invoke('desk_lamp', 'fly', {}),
      throwsA(isA<DeviceNotFoundException>()),
    );
  });

  test('commands to one device run one at a time, in order', () async {
    await store.put(lamp());
    final gate = Completer<void>();
    final order = <String>[];
    channel.outcomes.add((r) async {
      order.add('start ${r.context.params['value']}');
      await gate.future;
      order.add('end ${r.context.params['value']}');
      return const ChannelReply({});
    });
    channel.outcomes.add((r) {
      order.add('start ${r.context.params['value']}');
      order.add('end ${r.context.params['value']}');
      return const ChannelReply({});
    });
    final s = service();
    final first = s.invoke('desk_lamp', 'brightness', {'value': 40});
    final second = s.invoke('desk_lamp', 'brightness', {'value': 60});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(order, ['start 40']);
    gate.complete();
    await Future.wait([first, second]);
    expect(order, ['start 40', 'end 40', 'start 60', 'end 60']);
    expect((await store.get('desk_lamp'))!.state['dimming'], 60);
  });

  test('a failed command does not block the next one', () async {
    await store.put(lamp());
    channel.outcomes.add((_) => throw CommandFailedException('boom'));
    final s = service();
    await expectLater(
      s.invoke('desk_lamp', 'power', {'value': false}),
      throwsA(isA<CommandFailedException>()),
    );
    final ok = await s.invoke('desk_lamp', 'power', {'value': false});
    expect(ok.device.state['state'], false);
  });

  group('address healing', () {
    test('a timeout looks the device up by stable id and retries at the new address', () async {
      await store.put(lamp());
      channel.outcomes.add((_) => throw TransportTimeoutException('no reply'));
      String? askedFor;
      final s = service(
        locator: (driver, stableId) async {
          askedFor = stableId;
          return '10.0.0.77';
        },
      );
      final result = await s.invoke('desk_lamp', 'power', {'value': true});
      expect(askedFor, 'a8bb50aabbcc');
      expect(channel.requests.map((r) => r.device.host), [
        '10.0.0.5',
        '10.0.0.77',
      ]);
      expect(result.device.host, '10.0.0.77');
      expect((await store.get('desk_lamp'))!.host, '10.0.0.77');
    });

    test('without a stable id, or when the address did not change, the timeout stands', () async {
      await store.put(lamp(stableId: null));
      channel.outcomes.add((_) => throw TransportTimeoutException('no reply'));
      await expectLater(
        service(locator: (_, _) async => '10.0.0.77')
            .invoke('desk_lamp', 'power', {'value': true}),
        throwsA(isA<TransportTimeoutException>()),
      );
      await store.put(lamp());
      channel.outcomes.add((_) => throw TransportTimeoutException('no reply'));
      await expectLater(
        service(locator: (_, _) async => '10.0.0.5')
            .invoke('desk_lamp', 'power', {'value': true}),
        throwsA(isA<TransportTimeoutException>()),
      );
    });
  });

  test('refreshState replaces state with the polled object', () async {
    await store.put(lamp());
    channel.outcomes.add(
      (_) => const ChannelReply({
        'method': 'getPilot',
        'result': {'state': false, 'dimming': 55, 'temp': 4000},
      }),
    );
    final device = await service().refreshState('desk_lamp');
    expect(device.state, {'state': false, 'dimming': 55, 'temp': 4000});
  });

  test('applyPush merges syncPilot and ignores other methods', () async {
    await store.put(lamp());
    final s = service();
    final events = <DeviceStateChanged>[];
    s.events.listen(events.add);
    expect(
      await s.applyPush('desk_lamp', {'method': 'firstBeat', 'params': {}}),
      isNull,
    );
    final pushed = await s.applyPush('desk_lamp', {
      'method': 'syncPilot',
      'params': {'dimming': 90, 'temp': 3000},
    });
    expect(pushed!.state, {'state': true, 'dimming': 90, 'temp': 3000});
    await Future<void>.delayed(Duration.zero);
    expect(events.single.device.state['dimming'], 90);
  });

  test('end to end over loopback UDP with an emulated WiZ bulb', () async {
    final bulb = await UdpTransport.bind();
    final received = <Map>[];
    bulb.incoming.listen((d) {
      final request = jsonDecode(d.text) as Map;
      received.add(request);
      bulb.send(
        d.address,
        d.port,
        utf8.encode(
          jsonEncode({
            'method': request['method'],
            'env': 'pro',
            'result': {'success': true},
          }),
        ),
      );
    });
    final udp = await UdpTransport.bind();
    addTearDown(() {
      bulb.close();
      udp.close();
    });
    await store.put(
      lamp(host: InternetAddress.loopbackIPv4.address, port: bulb.localPort),
    );
    final s = DeviceService(
      registry: DriverRegistry.withBuiltIns(),
      store: store,
      channels: {TransportType.udp: UdpJsonChannel(udp)},
    );
    final result = await s.invoke('desk_lamp', 'color_temp', {
      'value': 3000,
      'brightness': 80,
    });
    expect(received.single, {
      'id': 1,
      'method': 'setPilot',
      'params': {'state': true, 'temp': 3000, 'dimming': 80},
    });
    expect(result.reply.json!['result'], {'success': true});
    expect(result.device.state['temp'], 3000);
  });

  test('stateKeyOf reads top-level keys only', () {
    expect(stateKeyOf(r'$.dimming'), 'dimming');
    expect(stateKeyOf(r"$['1']"), '1');
    expect(stateKeyOf(r'$.a.b'), isNull);
    expect(stateKeyOf(null), isNull);
  });

  test('a manifest with an invalid JSONPath is rejected at load time', () {
    expect(
      () => DriverManifest.parse({
        'schemaVersion': 1,
        'id': 'bad_path',
        'name': 'Bad',
        'category': 'misc',
        'transport': {'type': 'udp', 'port': 1},
        'statePush': {'jsonPath': r'$..[['},
        'capabilities': [
          {'id': 't', 'type': 'sensor', 'stateJsonPath': 'not a path'},
        ],
      }),
      throwsA(
        isA<ValidationException>().having((e) => e.issues.length, 'issues', 2),
      ),
    );
  });
}
