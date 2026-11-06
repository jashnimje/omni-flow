import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  late UdpTransport bulb;
  late InMemoryDeviceStore store;
  late DeviceService devices;
  late WizPushManager push;
  final registrations = <Map>[];

  setUp(() async {
    registrations.clear();
    bulb = await UdpTransport.bind();
    bulb.incoming.listen((d) {
      final m = jsonDecode(d.text) as Map;
      if (m['method'] == 'registration') registrations.add(m);
    });
    store = InMemoryDeviceStore();
    devices = DeviceService(
      registry: DriverRegistry.withBuiltIns(),
      store: store,
      channels: const {},
    );
    await store.put(
      Device(
        id: 'desk_lamp',
        name: 'Desk lamp',
        driverId: 'philips_wiz_udp',
        host: '127.0.0.1',
        port: bulb.localPort,
        stableId: 'A8BB50AABBCC',
        state: const {'state': false, 'dimming': 10},
      ),
    );
    push = await WizPushManager.start(
      devices: devices,
      listenPort: 0,
      renewEvery: const Duration(milliseconds: 150),
    );
  });

  tearDown(() async {
    await push.stop();
    bulb.close();
  });

  Future<void> sendToPush(Object message) async {
    final payload = message is String ? message : jsonEncode(message);
    bulb.send(
      InternetAddress.loopbackIPv4,
      push.listenPort,
      utf8.encode(payload),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  test('registers with each bulb and renews', () async {
    await push.watch(await store.all());
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(registrations.length, greaterThanOrEqualTo(2));
    final params = registrations.first['params'] as Map;
    expect(params['register'], isTrue);
    expect(params['phoneIp'], '127.0.0.1');
    expect(params['phoneMac'], matches(RegExp(r'^[0-9a-f]{12}$')));
  });

  test('a syncPilot updates the device whose MAC matches', () async {
    await push.watch(await store.all());
    final changed = devices.events.first;
    await sendToPush({
      'method': 'syncPilot',
      'params': {
        'mac': 'a8bb50aabbcc',
        'rssi': -55,
        'state': true,
        'dimming': 70,
        'temp': 2700,
      },
    });
    final event = await changed.timeout(const Duration(seconds: 1));
    expect(event.device.state, containsPair('dimming', 70));
    expect((await store.get('desk_lamp'))!.state['state'], true);
  });

  test(
    'pushes from unknown bulbs, test pings and junk change nothing',
    () async {
      await push.watch(await store.all());
      await sendToPush({
        'method': 'syncPilot',
        'params': {'mac': '000000000000', 'dimming': 99},
      });
      await sendToPush('test');
      await sendToPush('{not json');
      expect((await store.get('desk_lamp'))!.state, {
        'state': false,
        'dimming': 10,
      });
    },
  );

  test('firstBeat is reported with the bulb address', () async {
    final beat = push.firstBeats.first;
    await sendToPush({
      'method': 'firstBeat',
      'params': {'mac': 'a8bb50aabbcc'},
    });
    final got = await beat.timeout(const Duration(seconds: 1));
    expect((got.host, got.mac), ('127.0.0.1', 'a8bb50aabbcc'));
  });

  test('the registration message matches pywizlight', () {
    expect(
      jsonDecode(
        utf8.decode(registrationMessage('192.168.1.20', 'aabbccddeeff')),
      ),
      {
        'method': 'registration',
        'params': {
          'phoneIp': '192.168.1.20',
          'register': true,
          'phoneMac': 'aabbccddeeff',
        },
      },
    );
  });
}
