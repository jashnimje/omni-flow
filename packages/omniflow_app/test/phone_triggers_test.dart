import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/service/phone_inputs.dart';

import 'service_fake_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServiceFakeEngine engine;
  late StreamController<Object?> readings;
  late PhoneInputs inputs;

  setUp(() {
    engine = ServiceFakeEngine();
    readings = StreamController<Object?>();
    inputs = PhoneInputs(engine, readings: readings.stream)..start();
  });

  tearDown(() => inputs.stop());

  Future<void> send(Object? reading) async {
    readings.add(reading);
    await pumpEventQueue();
  }

  List<Map<String, Object?>> sent(String command) => engine.argsOf(command);

  test('an app opening and closing becomes phone.app', () async {
    await send({
      'kind': 'app',
      'package': 'com.netflix.mediaclient',
      'label': 'Netflix',
      'event': 'opened',
    });
    await send({
      'kind': 'app',
      'package': 'com.netflix.mediaclient',
      'event': 'closed',
    });
    await send({'kind': 'app', 'package': 'x', 'event': 'paused'});
    await send({'kind': 'app', 'event': 'opened'});
    expect(sent('phone.app'), [
      {
        'package': 'com.netflix.mediaclient',
        'label': 'Netflix',
        'event': 'opened',
      },
      {'package': 'com.netflix.mediaclient', 'event': 'closed'},
    ]);
  });

  test('a notification is passed on with its title and text', () async {
    await send({
      'kind': 'notification',
      'package': 'com.whatsapp',
      'label': 'WhatsApp',
      'title': 'Mum',
      'text': 'Dinner is ready',
    });
    await send({'kind': 'notification', 'title': 'no package'});
    await send({
      'kind': 'notification',
      'package': 'com.example.clock',
      'title': '',
      'text': null,
    });
    expect(sent('phone.notification'), [
      {
        'package': 'com.whatsapp',
        'label': 'WhatsApp',
        'title': 'Mum',
        'text': 'Dinner is ready',
      },
      {'package': 'com.example.clock'},
    ]);
  });

  test(
    'Bluetooth connects and disconnects, named by address when nameless',
    () async {
      await send({
        'kind': 'bluetooth',
        'name': 'Car',
        'address': 'AA:BB:CC:DD:EE:FF',
        'connected': true,
      });
      await send({
        'kind': 'bluetooth',
        'address': '11:22:33:44:55:66',
        'connected': false,
      });
      await send({'kind': 'bluetooth', 'name': 'x', 'connected': true});
      expect(sent('phone.bluetooth'), [
        {'name': 'Car', 'address': 'AA:BB:CC:DD:EE:FF', 'connected': true},
        {
          'name': '11:22:33:44:55:66',
          'address': '11:22:33:44:55:66',
          'connected': false,
        },
      ]);
    },
  );

  test('screen and Do Not Disturb are sent once per change', () async {
    await send({'kind': 'screen', 'on': true});
    await send({'kind': 'screen', 'on': true});
    await send({'kind': 'screen', 'on': false});
    await send({'kind': 'dnd', 'on': false});
    await send({'kind': 'dnd', 'on': false});
    await send({'kind': 'dnd', 'on': true});
    await send({'kind': 'dnd', 'on': 'yes'});
    expect(sent('phone.screen'), [
      {'on': true},
      {'on': false},
    ]);
    expect(sent('phone.dnd'), [
      {'on': false},
      {'on': true},
    ]);
  });

  test('an engine that refuses a reading does not stop the next', () async {
    engine.throwOn.add('phone.screen');
    await send({'kind': 'screen', 'on': true});
    await send({'kind': 'dnd', 'on': true});
    expect(sent('phone.dnd'), [
      {'on': true},
    ]);
  });
}
