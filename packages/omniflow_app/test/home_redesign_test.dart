import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/ui/automations/capture_scene.dart';
import 'package:omniflow_app/ui/automations/sun_lighting_page.dart';
import 'package:omniflow_app/ui/design/automation_look.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/weather_page.dart' show AddWeatherRow;
import 'package:omniflow_app/ui/home/home_data.dart';
import 'package:omniflow_app/ui/home/home_hero.dart';
import 'package:omniflow_app/ui/home/home_notices.dart';
import 'package:omniflow_app/ui/home/home_presence.dart';
import 'package:omniflow_app/ui/home/tile_look.dart';
import 'package:omniflow_app/ui/settings/home_location_page.dart';
import 'package:omniflow_app/ui/settings/phone_access.dart';
import 'package:omniflow_app/ui/settings/places_page.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart'
    show
        FakeAccess,
        FakeFirstRun,
        bulb,
        household,
        lamp,
        phone,
        sensor,
        tapKey,
        tv;
import 'screen_harness.dart';

/// Home's redesign (look B with C's card depth), the home location, the
/// presence that nothing detects and the Android switches Home warns about.

class FakeSwitches implements PhoneSwitches {
  FakeSwitches(this.state);

  Map<String, Object?>? state;
  final opened = <String>[];

  @override
  Future<Map<String, Object?>?> status() async => state;

  @override
  Future<void> openLocationSwitch() async => opened.add('location');

  @override
  Future<void> openExactAlarms() async => opened.add('alarms');
}

class FakeLocation implements PhoneLocation {
  FakeLocation({this.allowed = true, this.fix});

  final bool allowed;
  final ({double latitude, double longitude})? fix;

  @override
  Future<bool> ask() async => allowed;

  @override
  Future<({double latitude, double longitude})?> here() async => fix;
}

Map<String, Object?> unseenPerson() => {
  'id': 'jade',
  'name': 'Jade',
  'driver': 'person',
  'state': {'home': false},
  'capabilities': const <Object?>[],
};

Future<void> pumpHome(
  WidgetTester tester,
  FakeEngine engine, {
  FakeSwitches? switches,
}) => pumpApp(
  tester,
  engine,
  overrides: <Override>[
    phoneAccessProvider.overrideWithValue(
      FakeAccess(
        const PhoneAccessState(
          localNetwork: true,
          location: true,
          notifications: true,
          batteryUnrestricted: true,
          running: true,
        ),
      ),
    ),
    firstRunStoreProvider.overrideWithValue(FakeFirstRun(true)),
    phoneSwitchesProvider.overrideWithValue(switches ?? FakeSwitches(null)),
  ],
);

void main() {
  group('card depth keeps text readable', () {
    test('every rule colour washed on a card keeps text and captions at '
        'AA', () {
      for (final c in AutomationLook.colors.values) {
        final top = OmniDepth.litTop(
          OmniDepth.washTopOf(c.color, OmniColors.card),
        );
        expect(
          contrastRatio(OmniColors.text, top),
          greaterThanOrEqualTo(4.5),
          reason: c.name,
        );
        expect(
          contrastRatio(
            OmniDepth.captionOn(OmniDepth.washTopOf(c.color, OmniColors.card)),
            top,
          ),
          greaterThanOrEqualTo(4.5),
          reason: '${c.name} caption',
        );
      }
      expect(OmniDepth.captionOn(OmniColors.card), OmniColors.muted);
    });

    test('the hero\'s text reads at AA under the glow', () {
      final glowTop = Color.alphaBlend(
        OmniColors.accent.withValues(alpha: HomeHero.glow),
        OmniColors.heroTop,
      );
      expect(
        contrastRatio(OmniColors.text, glowTop),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(OmniColors.onAccentSoft, glowTop),
        greaterThanOrEqualTo(4.5),
      );
      final box = Color.alphaBlend(const Color(0x38000000), OmniColors.heroTop);
      expect(
        contrastRatio(OmniColors.onAccentSoft, box),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('Home', () {
    testWidgets('the hero holds the greeting and the status line, once', (
      tester,
    ) async {
      final engine = household();
      engine.answers['home.mode'] = {
        'ok': true,
        'mode': 'home',
        'modes': [
          {'id': 'home', 'name': 'Home'},
        ],
      };
      await pumpHome(tester, engine);
      expect(find.byKey(const ValueKey('home-hero')), findsOneWidget);
      expect(find.textContaining(', Jade'), findsOneWidget);
      expect(
        find.text('Home · Home mode · 1 automation active'),
        findsOneWidget,
      );
      final hero = tester.getTopLeft(find.byKey(const ValueKey('home-hero')));
      final chip = tester.getTopLeft(find.byKey(const ValueKey('mode-chip')));
      expect(hero.dy, lessThan(chip.dy));
    });

    testWidgets('the mode chip is its own screen reader node', (tester) async {
      final engine = household();
      engine.answers['home.mode'] = {
        'ok': true,
        'mode': 'home',
        'modes': [
          {'id': 'home', 'name': 'Home'},
        ],
      };
      engine.answers['room.state'] = {
        'ok': true,
        'room': {'id': 'lounge', 'name': 'Lounge'},
        'lights': 1,
        'lightsOn': 0,
        'anyOn': false,
      };
      final handle = tester.ensureSemantics();
      await pumpHome(tester, engine);
      expect(find.byKey(const ValueKey('room-tile-lounge')), findsWidgets);
      final node = tester.getSemantics(find.byKey(const ValueKey('mode-chip')));
      final words = '${node.label} ${node.hint}';
      expect(words, contains('Mode: Home'));
      expect(words, isNot(contains('Rooms')));
      expect(words, isNot(contains('Lounge')));
      handle.dispose();
    });

    testWidgets('with nothing detecting presence it says so, never Away', (
      tester,
    ) async {
      final engine = household();
      engine.devices = [
        lamp(),
        tv(),
        bulb(),
        sensor(),
        phone(),
        unseenPerson(),
      ];
      engine.answers['zone.list'] = {'ok': true, 'zones': const <Object?>[]};
      await pumpHome(tester, engine);
      expect(find.byKey(const ValueKey('home-notice-presence')), findsOne);
      expect(find.textContaining('Presence not set up'), findsOneWidget);
      expect(find.byKey(const ValueKey('chip-presence')), findsNothing);
      expect(find.textContaining('Away'), findsNothing);
      await tester.tap(find.text('Set up presence'));
      await tester.pumpAndSettle();
      expect(find.byType(PlacesPage), findsOneWidget);
      expect(find.text('Presence not set up'), findsOneWidget);
    });

    testWidgets('location off and Alarms and reminders off are notices with '
        'a fix', (tester) async {
      final engine = household();
      engine.answers['zone.list'] = {
        'ok': true,
        'zones': [
          {
            'id': 'home',
            'name': 'Home',
            'wifi': {
              'ssids': ['HomeWiFi'],
            },
          },
        ],
      };
      final switches = FakeSwitches({
        'locationOn': false,
        'exactAlarms': false,
      });
      await pumpHome(tester, engine, switches: switches);
      expect(
        find.text('Location is off, so arriving by Wi-Fi cannot be seen.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Alarms and reminders is off, so timed automations may run late.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Turn on location'));
      await tester.tap(find.text('Allow it'));
      expect(switches.opened, ['location', 'alarms']);
    });

    test('the location notice needs a Wi-Fi place, and nothing shows when '
        'all is on', () {
      void none() {}
      List<String> ids(Map<String, Object?>? status, {bool wifi = true}) => [
        for (final n in homeNotices(
          presence: PresenceShown.home,
          status: status,
          wifiPlace: wifi,
          setUpPresence: none,
          turnOnLocation: none,
          allowAlarms: none,
        ))
          n.id,
      ];
      expect(ids({'locationOn': true, 'exactAlarms': true}), isEmpty);
      expect(ids({'locationOn': false}, wifi: false), isEmpty);
      expect(ids(null), isEmpty);
    });

    test('presence is not set up only with no place and no source', () {
      const nothing = Presence(home: false);
      const wifi = Presence(home: false, source: PresenceSource.wifi);
      expect(presenceShown(nothing, const []), PresenceShown.notSetUp);
      expect(presenceShown(nothing, null), PresenceShown.away);
      expect(presenceShown(wifi, const []), PresenceShown.away);
      expect(
        presenceShown(nothing, const [
          {
            'id': 'home',
            'wifi': {
              'ssids': ['HomeWiFi'],
            },
          },
        ]),
        PresenceShown.away,
      );
      expect(
        presenceShown(nothing, const [
          {'id': 'home', 'wifi': <String, Object?>{}},
        ]),
        PresenceShown.notSetUp,
      );
      expect(presenceShown(null, const []), isNull);
    });
  });

  group('a phone', () {
    DeviceView phone({bool screen = true}) => DeviceView(const {
      'id': 'p',
      'name': 'Pixel',
      'driver': 'phone',
      'state': {'battery': 74, 'screen_on': true, 'torch': true},
      'capabilities': [
        {'id': 'torch', 'type': 'toggle', 'stateKey': 'torch'},
      ],
    });

    test('its torch is not its power, and it shows screen and battery', () {
      final p = phone();
      expect(p.hasPower, isTrue);
      expect(hasMainPower(p), isFalse);
      expect(tileReading(p), '74%');
      expect(tileState(p), 'Screen on');
      expect(phoneLine(p), 'Screen on · 74% battery');
    });
  });

  group('Home location', () {
    testWidgets('Settings has the row, and this phone\'s location sets it', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['home.location'] = {'ok': true, 'location': null};
      engine.answerers['home.location.set'] = (args) {
        engine.answers['home.location'] = {
          'ok': true,
          'location': {
            'latitude': args['latitude'],
            'longitude': args['longitude'],
          },
          'today': {
            'sunrise': DateTime(2026, 11, 13, 6, 41).toIso8601String(),
            'sunset': DateTime(2026, 11, 13, 17, 23).toIso8601String(),
          },
        };
        return {'ok': true, ...engine.answers['home.location']!};
      };
      await pumpScreen(
        tester,
        engine,
        const Scaffold(body: HomeLocationRow()),
        overrides: [
          phoneLocationProvider.overrideWithValue(
            FakeLocation(fix: (latitude: 51.5074, longitude: -0.1278)),
          ),
        ],
      );
      expect(find.textContaining('Not set.'), findsOneWidget);
      await tapKey(tester, 'settings-home-location');
      expect(find.text('Not set yet'), findsOneWidget);
      await tapKey(tester, 'home-location-use-phone');
      expect(engine.callsOf('home.location.set').single.$2, {
        'latitude': 51.5074,
        'longitude': -0.1278,
      });
      expect(find.textContaining('Sunrise 6:41'), findsOneWidget);
      expect(find.textContaining('sunset 5:23'), findsOneWidget);
    });

    testWidgets('typed numbers save, and a phone with no fix says why', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['home.location'] = {'ok': true, 'location': null};
      await pumpScreen(
        tester,
        engine,
        const HomeLocationPage(),
        overrides: [phoneLocationProvider.overrideWithValue(FakeLocation())],
      );
      await tapKey(tester, 'home-location-use-phone');
      expect(find.byKey(const ValueKey('home-location-problem')), findsOne);
      expect(engine.callsOf('home.location.set'), isEmpty);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '12,9716');
      await tester.enterText(fields.at(1), '77.5946');
      await tapKey(tester, 'home-location-save');
      expect(engine.callsOf('home.location.set').single.$2, {
        'latitude': 12.9716,
        'longitude': 77.5946,
      });
    });

    testWidgets('Follow the sun cannot be turned on without it, and says '
        'where to set it', (tester) async {
      final engine = FakeEngine()
        ..answers['sunlight.get'] = {
          'ok': true,
          'targets': const <Object?>[],
          'paused': const <Object?>[],
          'curve': const <String, Object?>{},
          'problem': 'Set where home is first: lights follow the sun at home',
        }
        ..answers['home.location'] = {'ok': true, 'location': null}
        ..devices = [
          {
            'id': 'lamp',
            'name': 'Lamp',
            'driver': 'philips_wiz_udp',
            'roomId': 'lounge',
            'room': 'Lounge',
            'state': {'state': true, 'dimming': 50},
            'capabilities': [
              {'id': 'power', 'type': 'toggle', 'stateKey': 'state'},
              {'id': 'brightness', 'type': 'level', 'stateKey': 'dimming'},
            ],
          },
        ];
      await pumpScreen(
        tester,
        engine,
        const Scaffold(body: RoomFollowSunSwitch(ids: ['lamp'])),
      );
      expect(find.textContaining('Home location'), findsOneWidget);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.onChanged, isNull);
      await tester.tap(find.text('Follow the sun'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeLocationPage), findsOneWidget);
      expect(engine.callsOf('sunlight.set'), isEmpty);
    });

    testWidgets('adding the weather without it opens Home location', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['home.location'] = {'ok': true, 'location': null};
      await pumpScreen(tester, engine, const Scaffold(body: AddWeatherRow()));
      await tapKey(tester, 'manual-weather');
      expect(engine.callsOf('weather.add'), isEmpty);
      expect(find.byType(HomeLocationPage), findsOneWidget);
    });
  });

  group('saving how things are now', () {
    testWidgets('a device past its poll window is marked last known, and '
        'the save names it', (tester) async {
      final engine = household();
      engine.answers['scene.capture'] = {
        'ok': true,
        'stale': [
          {'id': 'hall_bulb', 'name': 'Hall bulb'},
        ],
      };
      await pumpScreen(
        tester,
        engine,
        Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showCaptureScene(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Last known'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('capture-name')),
        'Evening',
      );
      await tester.tap(find.byKey(const ValueKey('capture-hall_bulb')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('capture-stale')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('capture-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Hall bulb had not answered'), findsWidgets);
    });

    test('a device that answers is not stale', () {
      expect(staleWords(DeviceView(const {'id': 'a', 'online': true})), isNull);
      expect(
        staleWords(DeviceView(const {'id': 'a', 'online': false})),
        startsWith('Never read'),
      );
    });
  });

  testWidgets('a semantics dump keeps the hero numbers as one button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final engine = FakeEngine()
      ..answers['home.stats'] = {
        'ok': true,
        'today': {'automationsRun': 2, 'tapsSaved': 5},
        'week': {'days': const <Object?>[]},
        'streak': {'days': 1, 'best': 1},
      };
    await pumpScreen(
      tester,
      engine,
      const Scaffold(body: HomeHero(title: 'Good morning')),
    );
    expect(
      find.bySemanticsLabel(RegExp('2 automations ran. Saved you 5 taps')),
      findsOneWidget,
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('2 automations ran')),
    );
    expect(node, isSemantics(isButton: true));
    handle.dispose();
  });
}
