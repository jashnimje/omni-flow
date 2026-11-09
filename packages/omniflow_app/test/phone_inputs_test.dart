import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/service/foreground_runtime.dart';
import 'package:omniflow_app/service/multicast_lock.dart';
import 'package:omniflow_app/service/phone_inputs.dart';

import 'fake_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeEngine engine;
  late StreamController<Object?> readings;
  late PhoneInputs inputs;

  setUp(() {
    engine = FakeEngine();
    readings = StreamController<Object?>();
    inputs = PhoneInputs(engine, readings: readings.stream)..start();
  });

  tearDown(() => inputs.stop());

  Future<void> send(Object? reading) async {
    readings.add(reading);
    await pumpEventQueue();
  }

  test('sends the battery level and charging, once per change', () async {
    await send({'kind': 'battery', 'level': 80, 'charging': false});
    await send({'kind': 'battery', 'level': 80, 'charging': false});
    await send({'kind': 'battery', 'level': 80, 'charging': true});
    await send({'kind': 'battery', 'level': 79.6, 'charging': true});

    expect(engine.callsOf('phone.battery').map((c) => c.$2), [
      {'level': 80, 'charging': false},
      {'level': 80, 'charging': true},
    ]);
  });

  test('sends the Wi-Fi network, and leaving Wi-Fi as no network', () async {
    await send({
      'kind': 'wifi',
      'connected': true,
      'ssid': 'HomeNet',
      'bssid': 'aa:bb:cc:dd:ee:ff',
    });
    await send({
      'kind': 'wifi',
      'connected': true,
      'ssid': 'HomeNet',
      'bssid': 'aa:bb:cc:dd:ee:ff',
    });
    await send({'kind': 'wifi', 'connected': false});

    expect(engine.callsOf('phone.wifi').map((c) => c.$2), [
      {'ssid': 'HomeNet', 'bssid': 'aa:bb:cc:dd:ee:ff'},
      <String, Object?>{},
    ]);
  });

  test(
    'a connection whose name Android hides is not sent as off Wi-Fi',
    () async {
      await send({'kind': 'wifi', 'connected': true, 'ssid': 'HomeNet'});
      await send({'kind': 'wifi', 'connected': true});

      expect(engine.callsOf('phone.wifi').map((c) => c.$2), [
        {'ssid': 'HomeNet'},
      ]);
    },
  );

  test('ignores readings it does not know and a failing engine', () async {
    engine.throwOn.add('phone.battery');
    await send('noise');
    await send({'kind': 'gps', 'lat': 1});
    await send({'kind': 'battery', 'level': 50});
    readings.addError(StateError('no bridge'));
    await pumpEventQueue();
    await send({'kind': 'wifi', 'connected': false});

    expect(engine.callsOf('phone.battery'), hasLength(1));
    expect(engine.callsOf('phone.wifi'), hasLength(1));
  });

  test('the service feeds the phone once its engine is open, and stops on '
      'destroy', () async {
    const lock = MethodChannel(MulticastLock.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lock, (call) async => true);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(lock, null),
    );
    final service = FakeEngine();
    final serviceReadings = StreamController<Object?>.broadcast();
    final handler = OmniTaskHandler(
      open: () async => (client: service, hubError: null),
      send: (_) {},
      stopService: () async => null,
      inputs: (e) => PhoneInputs(e, readings: serviceReadings.stream),
    );

    await handler.onStart(DateTime.now(), TaskStarter.developer);
    serviceReadings.add({'kind': 'battery', 'level': 12, 'charging': true});
    await pumpEventQueue();
    expect(service.callsOf('phone.battery').single.$2, {
      'level': 12,
      'charging': true,
    });

    await handler.onDestroy(DateTime.now(), false);
    expect(serviceReadings.hasListener, isFalse);
  });
}
