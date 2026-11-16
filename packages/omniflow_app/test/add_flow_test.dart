import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/ui/add/add_by_hand_page.dart';
import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/ui/add/guided_steps_page.dart';
import 'package:omniflow_app/ui/add/pair_sheet.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/open_device.dart' show DeviceRoute;
import 'package:omniflow_app/ui/home/home_data.dart' show roomsProvider;
import 'package:omniflow_app/ui/settings/places_page.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

/// A TV as thing.add finds it: the candidate, and the add object the
/// engine adds from.
const tv = {
  'driver': 'android_tv_adb',
  'method': 'mdns',
  'host': '192.168.1.60',
  'name': 'Android TV',
  'id': 'android_tv',
  'add': {
    'driver': 'android_tv_adb',
    'host': '192.168.1.60',
    'id': 'android_tv',
    'name': 'Android TV',
  },
};

const found = {
  'ok': true,
  'groups': [
    {
      'driver': 'android_tv_adb',
      'name': 'Android TV',
      'category': 'media',
      'candidates': [tv],
    },
    {
      'driver': 'philips_wiz_udp',
      'name': 'Philips WiZ',
      'category': 'lighting',
      'candidates': [
        {
          'driver': 'philips_wiz_udp',
          'host': '192.168.1.40',
          'name': 'WiZ bulb',
          'knownAs': 'desk_lamp',
        },
      ],
    },
  ],
  'methods': ['mdns', 'udp_broadcast'],
  'manual': [
    {
      'driver': 'place',
      'name': 'Place',
      'category': 'presence',
      'virtual': true,
    },
    {'driver': 'macos_host', 'name': 'Mac', 'category': 'computer'},
    {
      'driver': 'lg_webos_tv',
      'name': 'LG webOS TV (local SSAP over WebSocket)',
      'category': 'media',
    },
  ],
};

const drivers = {
  'ok': true,
  'drivers': [
    {
      'id': 'android_tv_adb',
      'name': 'Android TV',
      'category': 'media',
      'transport': 'adb',
      'pairing': 'adb',
      'settings': <Object?>[],
    },
    {
      'id': 'philips_hue_light',
      'name': 'Philips Hue light',
      'category': 'lighting',
      'transport': 'http',
      'pairing': 'hue_bridge',
      'settings': [
        {'key': 'lightId', 'label': 'Light number on the bridge'},
        {'key': 'username', 'label': 'Bridge username', 'secret': true},
      ],
    },
    {
      'id': 'omniflow_board',
      'name': 'OmniFlow board',
      'category': 'microcontroller',
      'transport': 'udp',
      'board': true,
      'settings': [
        {'key': 'pins', 'label': 'Pins'},
      ],
    },
    {
      'id': 'place',
      'name': 'Place',
      'category': 'presence',
      'icon': 'place',
      'transport': 'virtual',
      'settings': [
        {'key': 'ble', 'label': 'Beacon: {matchName, enterDbm}'},
        {'key': 'wifi', 'label': 'Wi-Fi: {ssids, bssids, required}'},
        {'key': 'zone', 'label': 'Zone id this place answers to'},
      ],
    },
    {
      'id': 'person',
      'name': 'Person',
      'category': 'presence',
      'icon': 'person',
      'transport': 'virtual',
      'settings': [
        {'key': 'homePlace', 'label': 'Place that counts as home'},
      ],
    },
  ],
};

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = FakeEngine();
    engine.answers['driver.list'] = drivers;
    engine.answers['room.list'] = {
      'ok': true,
      'rooms': [
        {'id': 'living_room', 'name': 'Living room', 'order': 0},
      ],
    };
    engine.answerers['thing.add'] = (args) => args['candidate'] == null
        ? found
        : {
            'ok': true,
            'id': 'android_tv',
            'next': {
              'step': 'pair',
              'method': 'adb',
              'instruction': 'Choose Allow on "Allow USB debugging?"',
              'remaining': ['pair'],
            },
          };
  });

  group('6.1 found nearby', () {
    testWidgets('says it is looking, then lists finds, the added ones and '
        'the ways by hand', (tester) async {
      engine.delay = const Duration(milliseconds: 200);
      await pumpScreen(tester, engine, const AddPage(), settle: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('add-looking')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-looking')), findsNothing);
      expect(engine.callsOf('thing.add').single.$2, isEmpty);
      expect(find.text('Android TV'), findsOneWidget);
      expect(find.text('192.168.1.60 · needs pairing'), findsOneWidget);
      expect(find.text('Already added'), findsOneWidget);
      expect(find.text('added'), findsOneWidget);
      expect(find.text('Desk lamp'), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-tag')), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-place')), findsOneWidget);
      expect(find.text('Mac, LG webOS TV…'), findsOneWidget);
    });

    testWidgets('nothing found says what to check', (tester) async {
      engine.answerers['thing.add'] = (_) => {
        'ok': true,
        'groups': const [],
        'methods': const ['mdns'],
        'manual': const [],
      };
      await pumpScreen(tester, engine, const AddPage());
      expect(find.byKey(const ValueKey('add-nothing')), findsOneWidget);
      expect(find.textContaining('same Wi-Fi'), findsOneWidget);
    });

    testWidgets('a discovery that fails says so and looks again', (
      tester,
    ) async {
      engine.answerers['thing.add'] = (_) => {
        'ok': false,
        'error': {'type': 'unavailable', 'message': 'the hub is not running'},
      };
      await pumpScreen(tester, engine, const AddPage());
      expect(find.byKey(const ValueKey('add-error')), findsOneWidget);
      expect(find.textContaining('The hub is not running'), findsOneWidget);
      await tester.tap(find.text('Look again').first);
      await tester.pumpAndSettle();
      expect(engine.callsOf('thing.add'), hasLength(2));
    });

    testWidgets('Add adds the find and opens its guided steps', (tester) async {
      engine.delay = const Duration(milliseconds: 10);
      engine.answers['device.pair'] = {
        'ok': true,
        'paired': true,
        'message': 'android_tv accepted the key',
      };
      engine.answers['thing.next'] = {
        'ok': true,
        'next': {'step': 'done', 'instruction': 'Android TV is ready'},
      };
      await pumpScreen(tester, engine, const AddPage());
      await tapKey(tester, 'candidate-add-0');
      expect(engine.callsOf('thing.add').last.$2, {
        'candidate': tv,
        'name': 'Android TV',
      });
      expect(find.byType(GuidedStepsPage), findsOneWidget);
      expect(engine.callsOf('device.pair').single.$2, {'id': 'android_tv'});
      expect(engine.callsOf('thing.next').single.$2, {
        'id': 'android_tv',
        'paired': true,
      });
      expect(find.text('Step 3 of 3 · Done'), findsOneWidget);
      expect(find.text('Android TV is ready'), findsOneWidget);
    });

    testWidgets('meets the tap target, label and contrast guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, engine, const AddPage());
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  group('6.2 guided steps', () {
    Widget steps(NextStep first) =>
        GuidedStepsPage(id: 'android_tv', name: 'Android TV', first: first);

    const pair = NextStep(
      NextKind.pair,
      method: 'adb',
      instruction: 'Choose Allow on "Allow USB debugging?"',
      remaining: ['pair'],
    );

    testWidgets('a TV pair step starts at once and counts down while the TV '
        'waits', (tester) async {
      engine.delay = const Duration(seconds: 5);
      engine.answers['thing.next'] = {
        'ok': true,
        'next': {'step': 'done'},
      };
      await pumpScreen(tester, engine, steps(pair), settle: false);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Step 2 of 3 · Pair'), findsOneWidget);
      expect(find.text('Look at the TV'), findsOneWidget);
      expect(
        find.text('Choose Allow on "Allow USB debugging?"'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('setup-waiting')), findsOneWidget);
      expect(find.textContaining('Waiting for the TV · 5'), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 10));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setup-waiting')), findsNothing);
      expect(find.text('Step 3 of 3 · Done'), findsOneWidget);
    });

    testWidgets('a TV that refuses the key gets plain words, not the CLI '
        'hint the engine words it with', (tester) async {
      engine.answers['device.pair'] = {
        'ok': false,
        'error': {
          'type': 'needs_user',
          'message':
              'android_tv is not paired with OmniFlow yet. Pair it first: '
              'omni device pair android_tv, or Pair in the device menu of '
              'the app',
        },
      };
      await pumpScreen(tester, engine, steps(pair));
      expect(find.byKey(const ValueKey('setup-error')), findsOneWidget);
      expect(find.textContaining('omni device pair'), findsNothing);
      expect(
        find.textContaining('The TV did not let OmniFlow in'),
        findsOneWidget,
      );
    });

    testWidgets('a place is named on its done step, with no room', (
      tester,
    ) async {
      engine.answers['device.list'] = {
        'ok': true,
        'devices': [
          {
            'id': 'home',
            'name': 'Home',
            'driver': 'place',
            'category': 'presence',
            'capabilities': const <Object?>[],
            'state': const <String, Object?>{},
          },
        ],
      };
      await pumpScreen(
        tester,
        engine,
        const GuidedStepsPage(
          id: 'home',
          name: 'Home',
          first: NextStep(NextKind.done),
        ),
      );
      expect(find.text('Give it a name, then finish.'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('room-field')), findsNothing);
    });

    testWidgets('a refused pairing stays up with why, for another try, and '
        'help says what to check', (tester) async {
      engine.answers['device.pair'] = {
        'ok': false,
        'error': {
          'type': 'pairing_failed',
          'message': 'The TV did not allow the key',
        },
      };
      await pumpScreen(tester, engine, steps(pair));
      expect(find.byKey(const ValueKey('setup-error')), findsOneWidget);
      expect(
        find.textContaining('The TV did not allow the key'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      await tapKey(tester, 'setup-help');
      expect(find.textContaining('same Wi-Fi as this phone'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Try again').last);
      await tester.pumpAndSettle();
      expect(engine.callsOf('device.pair'), hasLength(2));
    });

    testWidgets(
      'a secret is typed masked, stored with secret.set and cleared',
      (tester) async {
        engine.answers['thing.next'] = {
          'ok': true,
          'next': {'step': 'done'},
        };
        await pumpScreen(
          tester,
          engine,
          steps(
            const NextStep(
              NextKind.secret,
              instruction: 'Find the key in the Tuya app, under Device info',
              keys: [
                (
                  key: 'local_key',
                  label: 'Local key',
                  optional: false,
                  step: 'secret',
                ),
              ],
              remaining: ['secret'],
            ),
          ),
        );
        expect(
          find.text('Find the key in the Tuya app, under Device info'),
          findsOneWidget,
        );
        final field = find.byKey(const ValueKey('setup-field-local_key'));
        expect(tester.widget<TextField>(field).obscureText, isTrue);
        await tester.tap(find.byTooltip('Show Local key'));
        await tester.pump();
        expect(tester.widget<TextField>(field).obscureText, isFalse);
        await tester.enterText(field, 's3cret');
        await tester.pump();
        await tapKey(tester, 'setup-secret-save');
        expect(engine.callsOf('secret.set').single.$2, {
          'deviceId': 'android_tv',
          'key': 'local_key',
          'value': 's3cret',
        });
        expect(find.text('s3cret'), findsNothing);
        expect(find.byKey(const ValueKey('setup-done')), findsOneWidget);
      },
    );

    testWidgets('a configure step sends what was typed with thing.configure', (
      tester,
    ) async {
      engine.answers['thing.configure'] = {
        'ok': true,
        'next': {'step': 'done'},
      };
      await pumpScreen(
        tester,
        engine,
        steps(
          const NextStep(
            NextKind.configure,
            keys: [
              (
                key: 'lightId',
                label: 'Light number',
                optional: false,
                step: 'configure',
              ),
            ],
            remaining: ['configure'],
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-field-lightId')),
        '3',
      );
      await tester.pump();
      await tapKey(tester, 'setup-configure');
      expect(engine.callsOf('thing.configure').single.$2, {
        'id': 'android_tv',
        'settings': {'lightId': '3'},
      });
    });

    testWidgets('a board with no pins yet can go on, which saves no pins', (
      tester,
    ) async {
      engine.devices = [
        {
          'id': 'android_tv',
          'name': 'Hall board',
          'driver': 'omniflow_board',
          'board': true,
          'settings': const <String, Object?>{},
          'state': const <String, Object?>{},
          'capabilities': const <Object?>[],
        },
      ];
      engine.answers['thing.next'] = {
        'ok': true,
        'next': {'step': 'done'},
      };
      await pumpScreen(
        tester,
        engine,
        steps(
          const NextStep(
            NextKind.configure,
            keys: [
              (key: 'pins', label: 'Pins', optional: false, step: 'configure'),
            ],
            remaining: ['configure'],
          ),
        ),
      );
      expect(find.text('No pins yet, continue'), findsOneWidget);
      await tapKey(tester, 'setup-pins-continue');
      expect(engine.callsOf('board.pins').single.$2, {
        'id': 'android_tv',
        'pins': <String, Object?>{},
      });
      expect(find.byKey(const ValueKey('setup-done')), findsOneWidget);
    });

    testWidgets('Finish saves a new name and room with device.organize', (
      tester,
    ) async {
      await pumpScreen(tester, engine, steps(const NextStep(NextKind.done)));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('setup-name'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('setup-close'))).dy,
        ),
        reason: 'name and room come before Finish',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-name')),
        'Living room TV',
      );
      await tester.tap(find.byKey(const ValueKey('room-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living room').last);
      await tester.pumpAndSettle();
      await tapKey(tester, 'setup-close');
      expect(engine.callsOf('device.organize').single.$2, {
        'id': 'android_tv',
        'name': 'Living room TV',
        'room': 'living_room',
      });
      expect(find.text('Added Living room TV'), findsOneWidget);
      expect(find.byType(GuidedStepsPage), findsNothing);
      expect(
        find.byType(DeviceRoute),
        findsOneWidget,
        reason: 'a new thing opens on its page',
      );
    });

    testWidgets('optional keys on the done step are stored by their kind', (
      tester,
    ) async {
      engine.answers['thing.next'] = {
        'ok': true,
        'next': {'step': 'done'},
      };
      await pumpScreen(
        tester,
        engine,
        steps(
          const NextStep(
            NextKind.done,
            optional: [
              (
                key: 'user',
                label: 'Broker user',
                optional: true,
                step: 'configure',
              ),
              (
                key: 'password',
                label: 'Broker password',
                optional: true,
                step: 'secret',
              ),
            ],
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-field-user')),
        'omni',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-field-password')),
        'pw',
      );
      await tester.pump();
      await tapKey(tester, 'setup-close');
      expect(engine.callsOf('secret.set').single.$2['key'], 'password');
      expect(engine.callsOf('thing.configure').single.$2, {
        'id': 'android_tv',
        'settings': {'user': 'omni'},
      });
    });

    testWidgets('without a first step it resumes from thing.next', (
      tester,
    ) async {
      engine.answers['thing.next'] = {
        'ok': true,
        'next': {
          'step': 'pair',
          'method': 'hue_bridge',
          'instruction': 'Press the link button on the bridge',
          'remaining': ['pair'],
        },
      };
      await pumpScreen(
        tester,
        engine,
        const GuidedStepsPage(id: 'hall', name: 'Hall', stepsBefore: 0),
      );
      expect(engine.callsOf('thing.next').single.$2, {'id': 'hall'});
      expect(find.text('Press the button on the bridge'), findsOneWidget);
      expect(engine.callsOf('device.pair'), isEmpty);
      expect(find.byKey(const ValueKey('setup-pair')), findsOneWidget);
    });
  });

  group('add by hand', () {
    testWidgets('a driver is picked from the list, then its plain settings '
        'are asked, not its secrets', (tester) async {
      engine.answers['device.add'] = {
        'ok': true,
        'next': {
          'step': 'pair',
          'method': 'hue_bridge',
          'instruction': 'Press the link button on the bridge',
          'remaining': ['pair'],
        },
      };
      await pumpScreen(tester, engine, const AddByHandPage());
      await tapKey(tester, 'driver-omniflow_board');
      expect(find.byKey(const ValueKey('add-setting-pins')), findsNothing);
      await tapKey(tester, 'add-driver');
      await tapKey(tester, 'driver-philips_hue_light');
      expect(find.byKey(const ValueKey('add-setting-username')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('add-setting-lightId')),
        '3',
      );
      await tester.enterText(
        find.byKey(const ValueKey('add-host')),
        '192.168.1.20',
      );
      await tester.enterText(find.byKey(const ValueKey('add-name')), 'Hall');
      await tester.pump();
      await tapKey(tester, 'add-save');
      expect(engine.callsOf('device.add').single.$2, {
        'id': 'hall',
        'name': 'Hall',
        'driver': 'philips_hue_light',
        'host': '192.168.1.20',
        'settings': {'lightId': '3'},
      });
      expect(find.byType(GuidedStepsPage), findsOneWidget);
      expect(find.text('Press the link button on the bridge'), findsOneWidget);
    });

    testWidgets('the common kinds come first in plain words, the drivers '
        'under More kinds', (tester) async {
      await pumpScreen(tester, engine, const AddByHandPage());
      final lights = tester.getTopLeft(
        find.byKey(const ValueKey('kind-lights')),
      );
      final more = tester.getTopLeft(find.text('More kinds'));
      expect(lights.dy, lessThan(more.dy));
      expect(find.byKey(const ValueKey('kind-tvs')), findsOneWidget);
      expect(find.byKey(const ValueKey('kind-boards')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('kind-speakers')),
        findsNothing,
        reason: 'only kinds a driver makes',
      );
      await tapKey(tester, 'kind-tvs');
      expect(
        find.text('Add Android TV'),
        findsOneWidget,
        reason: 'the one TV driver opens straight away',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('kind-lights')), findsOneWidget);
    });

    testWidgets('a setting with help shows its first line and a ? sheet', (
      tester,
    ) async {
      engine.answers['driver.list'] = {
        'ok': true,
        'drivers': [
          {
            'id': 'philips_hue_light',
            'name': 'Philips Hue light',
            'category': 'lighting',
            'transport': 'http',
            'settings': [
              {
                'key': 'lightId',
                'label': 'Light number on the bridge',
                'help':
                    'The number the bridge gives the light. Open the Hue '
                    'app to see it.',
              },
            ],
          },
        ],
      };
      await pumpScreen(
        tester,
        engine,
        const AddByHandPage(driver: 'philips_hue_light'),
      );
      expect(
        find.textContaining('The number the bridge gives the light'),
        findsOneWidget,
      );
      await tapKey(tester, 'setting-help-open-lightId');
      expect(find.byKey(const ValueKey('setting-help-sheet')), findsOneWidget);
    });

    testWidgets('a kind with a protocol in its name reads plainly', (
      tester,
    ) async {
      engine.answers['driver.list'] = {
        'ok': true,
        'drivers': [
          {
            'id': 'lg_webos_tv',
            'name': 'LG webOS TV (local SSAP over WebSocket)',
            'category': 'media',
            'icon': 'tv',
            'transport': 'websocket',
            'settings': <Object?>[],
          },
          {
            'id': 'roku_ecp',
            'name': 'Roku TV or streaming stick (local ECP over HTTP)',
            'category': 'media',
            'icon': 'tv',
            'transport': 'http',
            'settings': <Object?>[],
          },
        ],
      };
      await pumpScreen(tester, engine, const AddByHandPage(kind: 'tvs'));
      expect(find.text('TVs'), findsOneWidget);
      expect(find.text('LG webOS TV'), findsOneWidget);
      expect(find.textContaining('SSAP'), findsNothing);
      await tapKey(tester, 'driver-lg_webos_tv');
      expect(find.text('Add LG webOS TV'), findsOneWidget);
    });

    testWidgets('a scan lists finds, a known one says which device has it, '
        'and a pick fills the address', (tester) async {
      engine.answers['device.discover'] = {
        'ok': true,
        'found': [
          {
            'host': '192.168.1.40',
            'stableId': 'a8bb50000001',
            'knownAs': 'desk_lamp',
          },
          {'host': '192.168.1.41', 'stableId': 'a8bb50aa'},
        ],
      };
      engine.answers['device.add'] = {
        'ok': true,
        'next': {'step': 'done'},
      };
      await pumpScreen(
        tester,
        engine,
        const AddByHandPage(driver: 'philips_hue_light'),
      );
      await tapKey(tester, 'add-scan');
      expect(engine.callsOf('device.discover').single.$2, {
        'driver': 'philips_hue_light',
      });
      expect(find.text('Already used by Desk lamp'), findsOneWidget);
      await tapKey(tester, 'found-192.168.1.41');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('add-host')))
            .controller!
            .text,
        '192.168.1.41',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('add-name')))
            .controller!
            .text,
        'a8bb50aa',
      );
      await tester.enterText(
        find.byKey(const ValueKey('add-name')),
        'Hall lamp',
      );
      await tester.tap(find.byKey(const ValueKey('room-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living room').last);
      await tester.pumpAndSettle();
      await tapKey(tester, 'add-save');
      expect(engine.callsOf('device.add').single.$2, {
        'id': 'hall_lamp',
        'name': 'Hall lamp',
        'driver': 'philips_hue_light',
        'host': '192.168.1.41',
        'room': 'living_room',
        'stableId': 'a8bb50aa',
      });
    });

    testWidgets('a place takes no address, no room and none of the Wi-Fi or '
        'beacon settings that Places and people sets', (tester) async {
      await pumpScreen(tester, engine, const AddByHandPage(driver: 'place'));
      expect(find.byKey(const ValueKey('add-host')), findsNothing);
      expect(find.byKey(const ValueKey('add-scan')), findsNothing);
      expect(find.byKey(const ValueKey('room-field')), findsNothing);
      expect(find.byKey(const ValueKey('add-setting-wifi')), findsNothing);
      expect(find.byKey(const ValueKey('add-setting-ble')), findsNothing);
      expect(find.textContaining('JSON'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('add-driver')),
          matching: find.byIcon(OmniIcons.place),
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const ValueKey('add-name')), 'Home');
      await tester.pump();
      await tapKey(tester, 'add-save');
      expect(engine.callsOf('device.add').single.$2, {
        'id': 'home',
        'name': 'Home',
        'driver': 'place',
      });
    });

    testWidgets('a person takes no room but keeps its plain settings', (
      tester,
    ) async {
      await pumpScreen(tester, engine, const AddByHandPage(driver: 'person'));
      expect(find.byKey(const ValueKey('room-field')), findsNothing);
      expect(
        find.byKey(const ValueKey('add-setting-homePlace')),
        findsOneWidget,
      );
    });

    testWidgets('a room made in the room picker reaches every rooms list', (
      tester,
    ) async {
      final rooms = <Map<String, Object?>>[
        {'id': 'living_room', 'name': 'Living room', 'order': 0},
      ];
      engine.answerers['room.list'] = (_) => {'ok': true, 'rooms': rooms};
      engine.answerers['room.save'] = (args) {
        rooms.add({'id': 'study', 'name': args['name'], 'order': 1});
        return {
          'ok': true,
          'room': {'id': 'study', 'name': args['name'], 'order': 1},
        };
      };
      await pumpScreen(
        tester,
        engine,
        const AddByHandPage(driver: 'android_tv_adb'),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AddByHandPage)),
      );
      expect(await container.read(roomsProvider.future), hasLength(1));
      await tapKey(tester, 'room-field');
      await tester.tap(find.text('New room').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ask-text')), 'Study');
      await tester.pump();
      await tapKey(tester, 'ask-text-ok');
      expect(engine.callsOf('room.save').single.$2, {'name': 'Study'});
      expect((await container.read(roomsProvider.future)).map((r) => r.name), [
        'Living room',
        'Study',
      ]);
    });

    testWidgets('a refused add shows the engine reason on the form', (
      tester,
    ) async {
      engine.answers['device.add'] = {
        'ok': false,
        'error': {'type': 'exists', 'message': 'a device hall exists'},
      };
      await pumpScreen(tester, engine, const AddByHandPage(driver: 'place'));
      await tester.enterText(find.byKey(const ValueKey('add-name')), 'Hall');
      await tester.pump();
      await tapKey(tester, 'add-save');
      expect(find.byKey(const ValueKey('add-refused')), findsOneWidget);
      expect(find.byType(GuidedStepsPage), findsNothing);
    });
  });

  testWidgets('a typed setting keeps JSON structure and leaves other text '
      'alone', (tester) async {
    expect(typedSetting('{"a":1}'), {'a': 1});
    expect(typedSetting('[1,2]'), [1, 2]);
    expect(typedSetting('0042'), '0042');
    expect(typedSetting('hall'), 'hall');
    expect(deviceIdFor('Hall lamp'), 'hall_lamp');
    expect(deviceIdFor('2nd lamp'), 'thing_2nd_lamp');
  });

  group('the pair sheet', () {
    final lounge = {
      'id': 'lounge_tv',
      'name': 'Lounge TV',
      'pairing': {'method': 'adb', 'prompt': 'Choose Allow on the TV'},
    };

    Widget host() => Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey('open-pair'),
            onPressed: () => showPairDevice(context, lounge),
            child: const Text('Pair'),
          ),
        ),
      ),
    );

    testWidgets('shows the engine prompt, then the outcome', (tester) async {
      engine.answers['device.pair'] = {
        'ok': true,
        'paired': true,
        'message': 'lounge_tv accepted the key',
      };
      await pumpScreen(tester, engine, host());
      await tapKey(tester, 'open-pair');
      expect(find.text('Choose Allow on the TV'), findsOneWidget);
      expect(engine.callsOf('device.pair'), isEmpty);
      await tapKey(tester, 'pair-start');
      expect(find.text('lounge_tv accepted the key'), findsOneWidget);
      await tapKey(tester, 'pair-done');
      expect(find.text('lounge_tv accepted the key'), findsNothing);
    });

    testWidgets('a refused pairing shows why and offers a retry', (
      tester,
    ) async {
      engine.answers['device.pair'] = {
        'ok': false,
        'error': {'type': 'pairing_failed', 'message': 'not allowed'},
      };
      await pumpScreen(tester, engine, host());
      await tapKey(tester, 'open-pair');
      await tapKey(tester, 'pair-start');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('pair-outcome')),
          matching: find.text('Not allowed.'),
        ),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a TV that refuses the key gets plain words', (tester) async {
      engine.answers['device.pair'] = {
        'ok': false,
        'error': {
          'type': 'needs_user',
          'message':
              'lounge_tv is not paired with OmniFlow yet. Pair it '
              'first: omni device pair lounge_tv',
        },
      };
      await pumpScreen(tester, engine, host());
      await tapKey(tester, 'open-pair');
      await tapKey(tester, 'pair-start');
      expect(find.textContaining('omni device pair'), findsNothing);
      expect(
        find.textContaining('The TV did not let OmniFlow in'),
        findsOneWidget,
      );
    });
  });

  testWidgets('Places with nobody added offers to add a person, with no room', (
    tester,
  ) async {
    engine.answers['zone.list'] = {'ok': true, 'zones': const <Object?>[]};
    await pumpScreen(tester, engine, const PlacesPage());
    await tapKey(tester, 'add-person');
    expect(find.byType(AddByHandPage), findsOneWidget);
    expect(find.text('Add Person'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-field')), findsNothing);
  });
}
