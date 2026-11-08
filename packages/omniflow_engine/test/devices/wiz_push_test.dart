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
    await store.put(
      Device(
        id: 'hall_lamp',
        name: 'Hall lamp',
        driverId: 'philips_wiz_udp',
        host: '127.0.0.1',
        port: bulb.localPort,
        stableId: 'a8bb50000001',
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

  void sendToPush(Object message, {WizPushManager? to}) {
    final payload = message is String ? message : jsonEncode(message);
    bulb.send(
      InternetAddress.loopbackIPv4,
      (to ?? push).listenPort,
      utf8.encode(payload),
    );
  }

  /// Sends a push for the hall lamp and waits for it to land. Datagrams on
  /// loopback arrive and are handled in order, so every push sent before it
  /// has been handled too.
  Future<void> marker({WizPushManager? to}) async {
    final changed = devices.events.firstWhere(
      (e) => e.device.id == 'hall_lamp' && e.device.state['rssi'] == -1,
    );
    sendToPush({
      'method': 'syncPilot',
      'params': {'mac': 'a8bb50000001', 'rssi': -1},
    }, to: to);
    await changed.timeout(const Duration(seconds: 2));
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
    sendToPush({
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
      sendToPush({
        'method': 'syncPilot',
        'params': {'mac': '000000000000', 'dimming': 99},
      });
      sendToPush('test');
      sendToPush('{not json');
      await marker();
      expect((await store.get('desk_lamp'))!.state, {
        'state': false,
        'dimming': 10,
      });
    },
  );

  test('a syncPilot from another address than the bulb is ignored', () async {
    await devices.updateDevice(
      'desk_lamp',
      (d) => d.copyWith(host: '127.0.0.2'),
    );
    await push.watch(await store.all());
    sendToPush({
      'method': 'syncPilot',
      'params': {'mac': 'a8bb50aabbcc', 'dimming': 99},
    });
    await marker();
    expect((await store.get('desk_lamp'))!.state['dimming'], 10);
  });

  test('a push for a device removed since is dropped, not thrown', () async {
    final errors = <Object>[];
    final guarded = (await runZonedGuarded(
      () => WizPushManager.start(devices: devices, listenPort: 0),
      (e, _) => errors.add(e),
    ))!;
    addTearDown(guarded.stop);
    await guarded.watch(await store.all());
    await store.remove('desk_lamp');
    sendToPush({
      'method': 'syncPilot',
      'params': {'mac': 'a8bb50aabbcc', 'dimming': 99},
    }, to: guarded);
    await marker(to: guarded);
    expect(errors, isEmpty);
    expect(await store.get('desk_lamp'), isNull);
  });

  test('a bulb that moved is registered at its new address', () async {
    final moved = await UdpTransport.bind();
    addTearDown(moved.close);
    final registered = moved.incoming.firstWhere(
      (d) => (jsonDecode(d.text) as Map)['method'] == 'registration',
    );
    await push.watch(await store.all());
    await devices.updateDevice(
      'desk_lamp',
      (d) => d.copyWith(port: moved.localPort),
    );
    await registered.timeout(const Duration(seconds: 2));
  });

  test('add registers a bulb now, and remove drops its pushes', () async {
    await push.watch(const []);
    final registered = bulb.incoming.firstWhere(
      (d) => (jsonDecode(d.text) as Map)['method'] == 'registration',
    );
    await push.add((await store.get('desk_lamp'))!);
    await push.add((await store.get('hall_lamp'))!);
    await registered.timeout(const Duration(seconds: 1));
    push.remove('desk_lamp');
    sendToPush({
      'method': 'syncPilot',
      'params': {'mac': 'a8bb50aabbcc', 'dimming': 99},
    });
    await marker();
    expect((await store.get('desk_lamp'))!.state['dimming'], 10);
  });

  test('firstBeat is reported with the bulb address', () async {
    final beat = push.firstBeats.first;
    sendToPush({
      'method': 'firstBeat',
      'params': {'mac': 'a8bb50aabbcc'},
    });
    final got = await beat.timeout(const Duration(seconds: 1));
    expect((got.host, got.mac), ('127.0.0.1', 'a8bb50aabbcc'));
  });

  test('a firstBeat from outside the local network is ignored', () async {
    var first = true;
    final filtered = await WizPushManager.start(
      devices: devices,
      listenPort: 0,
      acceptFrom: (_) {
        final accept = !first;
        first = false;
        return accept;
      },
    );
    addTearDown(filtered.stop);
    final beat = filtered.firstBeats.first;
    for (final mac in ['000000000001', '000000000002']) {
      sendToPush({
        'method': 'firstBeat',
        'params': {'mac': mac},
      }, to: filtered);
    }
    final got = await beat.timeout(const Duration(seconds: 1));
    expect(got.mac, '000000000002');
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
