import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/add_thing.dart';
import 'package:omniflow_app/ui/device_sheets.dart';
import 'package:omniflow_app/ui/setup_page.dart';

import 'fake_engine.dart';

/// A TV as thing.add finds it: the candidate, and the add object the
/// engine adds from.
const tv = {
  'driver': 'lg_webos_tv',
  'method': 'mdns',
  'host': '192.168.1.60',
  'name': 'Living room TV',
  'id': 'living_room_tv',
  'add': {
    'driver': 'lg_webos_tv',
    'host': '192.168.1.60',
    'id': 'living_room_tv',
    'name': 'Living room TV',
  },
};

const found = {
  'ok': true,
  'groups': [
    {
      'driver': 'lg_webos_tv',
      'name': 'LG webOS TV',
      'candidates': [tv],
    },
    {
      'driver': 'philips_hue_bridge',
      'name': 'Hue bridge',
      'candidates': [
        {
          'driver': 'philips_hue_bridge',
          'host': '192.168.1.2',
          'name': 'Hue bridge',
          'knownAs': 'hue',
        },
      ],
    },
  ],
  'methods': ['mdns', 'udp'],
  'manual': [],
};

Future<void> openAdd(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('add-device')));
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = FakeEngine();
    engine.answerers['thing.add'] = (args) => args['candidate'] == null
        ? found
        : {
            'ok': true,
            'id': 'living_room_tv',
            'next': {
              'step': 'pair',
              'method': 'tv',
              'instruction': 'Accept the prompt on the TV',
              'command': 'device.pair',
            },
          };
  });

  testWidgets('lists what the engine found, then pairs, stores secrets and '
      'configures with the command each step names, until done', (
    tester,
  ) async {
    final next = [
      {
        'ok': true,
        'next': {
          'step': 'secret',
          'keys': [
            {'step': 'secret', 'key': 'client_key', 'label': 'Client key'},
            {'step': 'secret', 'key': 'pin', 'label': 'PIN', 'optional': true},
          ],
          'instruction': 'Enter the Client key for living_room_tv',
          'command': 'secret.set',
        },
      },
      {
        'ok': true,
        'next': {
          'step': 'configure',
          'keys': [
            {'step': 'configure', 'key': 'mac', 'label': 'MAC address'},
          ],
          'instruction': 'Set the MAC address for living_room_tv',
          'command': 'thing.configure',
        },
      },
    ];
    engine.answerers['thing.next'] = (_) => next.removeAt(0);
    engine.answers['device.pair'] = {'ok': true, 'message': 'Paired'};
    engine.answers['thing.configure'] = {
      'ok': true,
      'next': {
        'step': 'done',
        'instruction': 'Living room TV is ready',
        'optional': [
          {
            'step': 'configure',
            'key': 'input',
            'label': 'Default input',
            'optional': true,
          },
        ],
      },
    };
    await pumpApp(tester, engine);
    await openAdd(tester);

    expect(engine.callsOf('thing.add').single.$2, isEmpty);
    expect(find.text('Living room TV'), findsOneWidget);
    expect(
      find.textContaining('LG webOS TV - 192.168.1.60 - via mdns'),
      findsOneWidget,
    );
    expect(find.textContaining('Already added as hue'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('candidate-1')))
          .enabled,
      isFalse,
    );

    await tapKey(tester, 'candidate-0');
    await tester.enterText(find.byKey(const ValueKey('add-room')), 'Living');
    await tapKey(tester, 'add-confirm');
    expect(engine.callsOf('thing.add').last.$2, {
      'candidate': tv,
      'name': 'Living room TV',
      'room': 'Living',
    });
    expect(find.text('Accept the prompt on the TV'), findsOneWidget);

    await tapKey(tester, 'setup-pair');
    expect(engine.callsOf('device.pair').single.$2, {'id': 'living_room_tv'});
    expect(engine.callsOf('thing.next').first.$2, {
      'id': 'living_room_tv',
      'paired': true,
    });

    final secret = tester.widget<TextField>(
      find.byKey(const ValueKey('setup-field-client_key')),
    );
    expect(secret.obscureText, isTrue);
    expect(secret.enableSuggestions, isFalse);
    expect(find.text('PIN (optional)'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('setup-field-client_key')),
      'k-123-secret',
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'setup-secret-save');
    expect(engine.callsOf('secret.set').single.$2, {
      'deviceId': 'living_room_tv',
      'key': 'client_key',
      'value': 'k-123-secret',
    });
    expect(engine.callsOf('thing.next').last.$2, {'id': 'living_room_tv'});
    expect(find.textContaining('k-123-secret'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('setup-field-mac')),
      'aa:bb:cc:dd:ee:ff',
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'setup-configure');
    expect(engine.callsOf('thing.configure').single.$2, {
      'id': 'living_room_tv',
      'settings': {'mac': 'aa:bb:cc:dd:ee:ff'},
    });

    expect(find.text('Living room TV is ready'), findsOneWidget);
    expect(find.text('Default input (optional)'), findsOneWidget);
    await tapKey(tester, 'setup-close');
    expect(find.byType(SetupPage), findsNothing);
    expect(find.byType(AddThingPage), findsNothing);
  });

  testWidgets('a pairing the engine refuses stays up with why, for another '
      'go', (tester) async {
    engine.answers['device.pair'] = {
      'ok': false,
      'error': {
        'type': 'unavailable',
        'message': 'the TV did not answer',
        'issues': [],
      },
    };
    await pumpApp(tester, engine);
    await openAdd(tester);
    await tapKey(tester, 'candidate-0');
    await tapKey(tester, 'add-confirm');
    await tapKey(tester, 'setup-pair');

    expect(find.text('the TV did not answer'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Accept the prompt on the TV'), findsOneWidget);
    expect(engine.callsOf('thing.next'), isEmpty);
  });

  testWidgets('a thing that needs no step is added and the page closes', (
    tester,
  ) async {
    engine.answerers['thing.add'] = (args) => args['candidate'] == null
        ? found
        : {
            'ok': true,
            'id': 'living_room_tv',
            'next': {'step': 'done', 'instruction': 'ready'},
          };
    await pumpApp(tester, engine);
    await openAdd(tester);
    await tapKey(tester, 'candidate-0');
    await tapKey(tester, 'add-confirm');

    expect(find.byType(AddThingPage), findsNothing);
    expect(find.text('Added Living room TV'), findsOneWidget);
    expect(engine.callsOf('thing.next'), isEmpty);
  });

  testWidgets('a board sets its pins in the pin sheet, then the setup moves '
      'on', (tester) async {
    engine.devices = [
      {
        'id': 'desk_board',
        'name': 'Desk board',
        'driver': 'omniflow_board',
        'host': '192.168.1.70',
        'board': true,
        'settings': const <String, Object?>{},
        'state': const <String, Object?>{},
        'capabilities': const <Object?>[],
      },
    ];
    engine.answers['thing.next'] = {
      'ok': true,
      'next': {
        'step': 'configure',
        'keys': [
          {'step': 'configure', 'key': 'pins', 'label': 'Pins'},
        ],
        'instruction': 'Name the pins you use on desk_board',
      },
    };
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk_board', 'Setup steps');

    expect(engine.callsOf('thing.next').single.$2, {'id': 'desk_board'});
    expect(find.text('Name the pins you use on desk_board'), findsOneWidget);
    await tapKey(tester, 'setup-pins');
    expect(find.byKey(const ValueKey('pin-name')), findsOneWidget);

    Navigator.of(tester.element(find.byKey(const ValueKey('pin-name')))).pop();
    await tester.pumpAndSettle();
    expect(engine.callsOf('thing.next'), hasLength(2));
  });

  testWidgets('Setup steps resumes a thing from where the engine says', (
    tester,
  ) async {
    engine.answers['thing.next'] = {
      'ok': true,
      'next': {
        'step': 'pair',
        'method': 'hue_bridge',
        'instruction': 'Press the link button',
      },
    };
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk_lamp', 'Setup steps');

    expect(engine.callsOf('thing.next').single.$2, {'id': 'desk_lamp'});
    expect(find.text('Press the link button'), findsOneWidget);
  });

  testWidgets('a set-up thing says it is ready', (tester) async {
    engine.answers['thing.next'] = {
      'ok': true,
      'next': {'step': 'done', 'instruction': 'Desk lamp is ready'},
    };
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk_lamp', 'Setup steps');
    expect(find.text('Desk lamp is ready'), findsOneWidget);
  });

  testWidgets('nothing found still lets the user pick a driver by hand', (
    tester,
  ) async {
    engine.answerers.remove('thing.add');
    engine.answers['thing.add'] = {
      'ok': true,
      'groups': [],
      'methods': ['mdns'],
      'manual': [],
    };
    await pumpApp(tester, engine);
    await openAdd(tester);
    expect(find.textContaining('Nothing new found'), findsOneWidget);
    await tapKey(tester, 'add-by-driver');
    expect(find.byType(AddThingPage), findsNothing);
    expect(find.byType(AddDeviceSheet), findsOneWidget);
  });

  testWidgets('optional keys on the done step can be filled: a secret '
      'masked through secret.set, a setting through thing.configure', (
    tester,
  ) async {
    final done = {
      'step': 'done',
      'instruction': 'Desk lamp is ready',
      'optional': [
        {
          'step': 'secret',
          'key': 'password',
          'label': 'Broker password',
          'optional': true,
        },
        {
          'step': 'configure',
          'key': 'username',
          'label': 'Broker user',
          'optional': true,
        },
      ],
    };
    final answers = [
      {'ok': true, 'next': done},
      {
        'ok': true,
        'next': {'step': 'done', 'instruction': 'Desk lamp is ready'},
      },
    ];
    engine.answerers['thing.next'] = (_) => answers.removeAt(0);
    engine.answers['thing.configure'] = {'ok': true, 'next': done};
    await pumpApp(tester, engine);
    await openDeviceMenu(tester, 'desk_lamp', 'Setup steps');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('setup-field-password')))
          .obscureText,
      isTrue,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('setup-field-username')))
          .obscureText,
      isFalse,
    );
    await tester.enterText(
      find.byKey(const ValueKey('setup-field-password')),
      'p-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey('setup-field-username')),
      'omni',
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'setup-optional-save');

    expect(engine.callsOf('secret.set').single.$2, {
      'deviceId': 'desk_lamp',
      'key': 'password',
      'value': 'p-secret',
    });
    expect(engine.callsOf('thing.configure').single.$2, {
      'id': 'desk_lamp',
      'settings': {'username': 'omni'},
    });
    expect(engine.callsOf('thing.next').last.$2, {'id': 'desk_lamp'});
    expect(find.textContaining('p-secret'), findsNothing);
    expect(find.byKey(const ValueKey('setup-field-password')), findsNothing);
  });

  testWidgets('a thing whose only steps left are optional opens the setup '
      'page instead of only saying it was added', (tester) async {
    engine.answerers['thing.add'] = (args) => args['candidate'] == null
        ? found
        : {
            'ok': true,
            'id': 'living_room_tv',
            'next': {
              'step': 'done',
              'optional': [
                {
                  'step': 'configure',
                  'key': 'mac',
                  'label': 'MAC address',
                  'optional': true,
                },
              ],
            },
          };
    await pumpApp(tester, engine);
    await openAdd(tester);
    await tapKey(tester, 'candidate-0');
    await tapKey(tester, 'add-confirm');
    expect(find.byType(SetupPage), findsOneWidget);
    expect(find.text('MAC address (optional)'), findsOneWidget);
  });

  group('drivers with nothing to look for', () {
    setUp(() {
      engine.answers['thing.add'] = {
        ...found,
        'manual': [
          {
            'driver': 'place',
            'name': 'Place',
            'category': 'virtual',
            'virtual': true,
          },
          {'driver': 'lg_webos_tv', 'name': 'LG webOS TV'},
        ],
      };
      engine.answerers.remove('thing.add');
      engine.answers['driver.list'] = {
        'ok': true,
        'drivers': [
          {
            'id': 'place',
            'name': 'Place',
            'transport': 'virtual',
            'settings': [
              {'key': 'wifi', 'label': 'Wi-Fi: {ssids, bssids, required}'},
              {'key': 'zone', 'label': 'Zone id this place answers to'},
            ],
          },
          {
            'id': 'lg_webos_tv',
            'name': 'LG webOS TV',
            'transport': 'websocket',
            'settings': <Object?>[],
          },
        ],
      };
    });

    testWidgets('a place is listed and added with no address, its Wi-Fi '
        'typed as JSON', (tester) async {
      await pumpApp(tester, engine);
      await openAdd(tester);
      expect(find.text('Place'), findsOneWidget);
      expect(find.text('No address needed'), findsOneWidget);
      await tapKey(tester, 'manual-place');
      expect(find.byType(AddDeviceSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('add-host')), findsNothing);
      expect(find.byKey(const ValueKey('add-scan')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('add-name')), 'Home');
      await tester.enterText(
        find.byKey(const ValueKey('add-setting-wifi')),
        '{"ssids": ["HomeNet"]}',
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'add-save');

      expect(engine.callsOf('device.add').single.$2, {
        'id': 'home',
        'name': 'Home',
        'driver': 'place',
        'settings': {
          'wifi': {
            'ssids': ['HomeNet'],
          },
        },
      });
      expect(find.text('Added Home'), findsOneWidget);
    });

    testWidgets('a driver picked by hand follows the setup steps device.add '
        'says come next', (tester) async {
      engine.answers['device.add'] = {
        'ok': true,
        'next': {
          'step': 'pair',
          'method': 'tv',
          'instruction': 'Accept the prompt on the TV',
        },
      };
      await pumpApp(tester, engine);
      await openAdd(tester);
      await tapKey(tester, 'manual-lg_webos_tv');
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('add-save')),
      );
      expect(save.onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('add-host')),
        '192.168.1.61',
      );
      await tester.enterText(find.byKey(const ValueKey('add-name')), 'TV');
      await tester.pumpAndSettle();
      await tapKey(tester, 'add-save');

      expect(engine.callsOf('device.add').single.$2, {
        'id': 'tv',
        'name': 'TV',
        'driver': 'lg_webos_tv',
        'host': '192.168.1.61',
      });
      expect(find.byType(SetupPage), findsOneWidget);
      expect(find.text('Accept the prompt on the TV'), findsOneWidget);
    });
  });

  test('a typed setting keeps JSON structure and leaves other text alone', () {
    expect(settingValue('{"relay": {"pin": 4, "mode": "out"}}'), {
      'relay': {'pin': 4, 'mode': 'out'},
    });
    expect(settingValue('0042'), '0042');
    expect(settingValue('true'), 'true');
  });
}
