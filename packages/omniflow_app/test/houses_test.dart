import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart' show Json;
import 'package:omniflow_app/api/houses_calls.dart';
import 'package:omniflow_app/state/house.dart';
import 'package:omniflow_app/service/hub_settings.dart' show HubSettingsStore;
import 'package:omniflow_app/state/hub_mode.dart' show hubSettingsStoreProvider;
import 'package:omniflow_engine/omniflow_engine.dart' show InMemorySecretStore;
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/fun/fun_prefs.dart';
import 'package:omniflow_app/ui/fun/your_home_page.dart';
import 'package:omniflow_app/ui/home/run_section.dart' show RunTile;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show household, tapKey;

/// Houses in the app (docs/design/houses-design.md): the house in view, passed on
/// every list and save by the calls layer, the switcher, arrival, and Home
/// without the rewards.

const _houses = {
  'ok': true,
  'houses': [
    {'id': 'mumbai', 'name': 'Mumbai', 'order': 0},
    {'id': 'bangalore', 'name': 'Bangalore', 'order': 1},
  ],
};

Json _flatLamp() => {
  ...FakeEngine.lamp(),
  'id': 'flat_lamp',
  'name': 'Flat lamp',
  'room': null,
};

/// The household of the Home tests in Mumbai, and one lamp, one scene and
/// one automation in Bangalore. Each list answers for the house it is
/// given, as the engine does: people and phones show in both.
FakeEngine twoHouses() {
  final engine = household();
  engine.answers['house.list'] = _houses;
  final mumbaiDevices = List<Json>.from(
    engine.answers['device.list']!['devices'] as List,
  );
  final mumbaiScenes = engine.answers['scene.list']!['scenes'] as List;
  final mumbaiAutomations =
      engine.answers['automation.list']!['automations'] as List;
  bool shared(Json d) => d['driver'] == 'person' || d['driver'] == 'phone';
  engine.answerers['device.list'] = (args) => {
    'ok': true,
    'devices': args['house'] == 'bangalore'
        ? [...mumbaiDevices.where(shared), _flatLamp()]
        : mumbaiDevices,
  };
  engine.answerers['scene.list'] = (args) => {
    'ok': true,
    'scenes': args['house'] == 'bangalore'
        ? [
            {
              'id': 'flat_evening',
              'name': 'Flat evening',
              'icon': 'sun',
              'actions': const <Object?>[],
            },
          ]
        : mumbaiScenes,
  };
  engine.answerers['automation.list'] = (args) => {
    'ok': true,
    'automations': args['house'] == 'bangalore'
        ? [
            {
              'id': 'flat_morning',
              'name': 'Flat morning',
              'source': 'rule',
              'enabled': true,
              'approved': true,
              'sentence': const <Object?>[],
              'devices': ['flat_lamp'],
            },
          ]
        : mumbaiAutomations,
  };
  engine.answerers['room.list'] = (args) => args['house'] == 'bangalore'
      ? const {'ok': true, 'rooms': <Object?>[]}
      : engine.answers['room.list']!;
  return engine;
}

/// Every call of [command] named [house].
void expectAllIn(FakeEngine engine, String command, String house) {
  final calls = engine.callsOf(command);
  expect(calls, isNotEmpty, reason: command);
  expect({for (final c in calls) c.$2['house']}, {house}, reason: command);
}

Future<void> pumpHouses(
  WidgetTester tester,
  FakeEngine engine, {
  HouseViewStore? store,
  FunPrefsStore? fun,
}) => pumpApp(
  tester,
  engine,
  overrides: [
    houseViewStoreProvider.overrideWithValue(store ?? MemoryHouseViewStore()),
    hubSettingsStoreProvider.overrideWithValue(
      HubSettingsStore(InMemorySecretStore()),
    ),
    funPrefsStoreProvider.overrideWithValue(fun ?? MemoryFunPrefsStore()),
  ],
);

/// Picks [house] from the switcher at the top of Home.
Future<void> switchTo(WidgetTester tester, String house) async {
  await tapKey(tester, 'house-switcher');
  await tapKey(tester, 'house-$house');
}

void main() {
  group('the calls layer', () {
    test('adds the house in view to lists, saves and settings only', () {
      expect(HousesCalls.withHouse('device.list', const {}, 'mumbai'), {
        'house': 'mumbai',
      });
      expect(
        HousesCalls.withHouse('automation.save', const {'id': 'a'}, 'mumbai'),
        {'id': 'a', 'house': 'mumbai'},
      );
      expect(HousesCalls.withHouse('home.location', const {}, 'mumbai'), {
        'house': 'mumbai',
      });
      for (final command in [
        'device.invoke',
        'scene.run',
        'house.list',
        'house.rename',
        'presence.set',
        'phone.wifi',
      ]) {
        expect(HousesCalls.withHouse(command, const {'id': 'x'}, 'mumbai'), {
          'id': 'x',
        }, reason: command);
      }
    });

    test('a house given, or one the item carries, is kept', () {
      expect(
        HousesCalls.withHouse('device.list', const {
          'house': 'bangalore',
        }, 'mumbai'),
        {'house': 'bangalore'},
      );
      final zone = {
        'zone': {'id': 'flat', 'house': 'bangalore'},
      };
      expect(HousesCalls.withHouse('zone.save', zone, 'mumbai'), zone);
    });

    test('a scoped client passes the house, and waits for it', () async {
      final engine = FakeEngine();
      await HouseScopedClient(engine, house: 'mumbai').call('scene.list');
      expect(engine.callsOf('scene.list').single.$2, {'house': 'mumbai'});
      await HouseScopedClient(
        engine,
        pending: Future.value('bangalore'),
      ).call('room.list');
      expect(engine.callsOf('room.list').single.$2, {'house': 'bangalore'});
      await HouseScopedClient(engine).call('tag.list');
      expect(engine.callsOf('tag.list').single.$2, isEmpty);
    });

    test('house calls use the ids the engine reads', () async {
      final engine = FakeEngine();
      final api = HousesApi(engine);
      await api.add('Goa');
      await api.rename('goa', 'Goa flat');
      await api.remove('goa');
      expect(engine.callsOf('house.add').single.$2, {'name': 'Goa'});
      expect(engine.callsOf('house.rename').single.$2, {
        'id': 'goa',
        'name': 'Goa flat',
      });
      expect(engine.callsOf('house.remove').single.$2, {'id': 'goa'});
    });
  });

  group('the house in view', () {
    testWidgets('is the first house, and every list on Home names it', (
      tester,
    ) async {
      final engine = twoHouses();
      await pumpHouses(tester, engine);
      expect(find.byKey(const ValueKey('house-name')), findsOneWidget);
      expect(find.text('Mumbai'), findsWidgets);
      for (final command in [
        'device.list',
        'scene.list',
        'automation.list',
        'room.list',
      ]) {
        expectAllIn(engine, command, 'mumbai');
      }
      expect(find.byKey(const ValueKey('tile-desk_lamp')), findsWidgets);
      expect(find.byKey(const ValueKey('tile-flat_lamp')), findsNothing);
    });

    testWidgets('comes back as it was left on this phone', (tester) async {
      final engine = twoHouses();
      final store = MemoryHouseViewStore('bangalore');
      await pumpHouses(tester, engine, store: store);
      expectAllIn(engine, 'device.list', 'bangalore');
      expect(find.byKey(const ValueKey('tile-flat_lamp')), findsWidgets);
    });

    testWidgets('a house that is gone falls back to the first', (tester) async {
      final engine = twoHouses();
      await pumpHouses(tester, engine, store: MemoryHouseViewStore('goa'));
      expectAllIn(engine, 'device.list', 'mumbai');
    });

    testWidgets('an engine with no houses gets calls as they were', (
      tester,
    ) async {
      final engine = household();
      await pumpHouses(tester, engine);
      expect(find.byKey(const ValueKey('house-switcher')), findsNothing);
      expect(
        engine.callsOf('device.list').every((c) => c.$2['house'] == null),
        isTrue,
      );
    });
  });

  group('the switcher', () {
    testWidgets('switching shows the other house everywhere, and is kept', (
      tester,
    ) async {
      final engine = twoHouses();
      final store = MemoryHouseViewStore();
      await pumpHouses(tester, engine, store: store);
      expect(find.text('Movie'), findsOneWidget);
      engine.calls.clear();
      await switchTo(tester, 'bangalore');
      expect(store.saved, 'bangalore');
      expect(find.byKey(const ValueKey('house-name')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('house-name'))).data,
        'Bangalore',
      );
      // Home: tiles, the Run grid, room tiles.
      expect(find.byKey(const ValueKey('tile-flat_lamp')), findsWidgets);
      expect(find.byKey(const ValueKey('tile-desk_lamp')), findsNothing);
      expect(find.text('Flat evening'), findsOneWidget);
      expect(find.text('Movie'), findsNothing);
      expect(find.byType(RunTile), findsWidgets);
      expect(find.text('Lounge'), findsNothing);
      for (final command in ['device.list', 'scene.list', 'room.list']) {
        expectAllIn(engine, command, 'bangalore');
      }
      expect(
        engine.calls.where((c) => c.$2['house'] == 'mumbai'),
        isEmpty,
        reason: 'nothing reads Mumbai once Bangalore is shown',
      );

      // Devices.
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('device-row-flat_lamp')), findsWidgets);
      expect(find.byKey(const ValueKey('device-row-desk_lamp')), findsNothing);

      // Automations.
      await openTab(tester, 'Automations');
      expect(find.text('Flat morning'), findsOneWidget);
      expect(find.text('Desk button'), findsNothing);
      expectAllIn(engine, 'automation.list', 'bangalore');

      // Settings, Your home.
      await openTab(tester, 'Settings');
      expect(find.text('Your home · Bangalore'), findsOneWidget);
      expect(find.text('Your home'), findsNothing);
      expectAllIn(engine, 'zone.list', 'bangalore');
      expectAllIn(engine, 'home.location', 'bangalore');
    });

    testWidgets('another house opens Home at its top', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final engine = twoHouses();
      await pumpHouses(tester, engine);
      final list = find.byKey(const ValueKey('home-list'));
      double offset() => tester.widget<ListView>(list).controller!.offset;
      await tester.drag(list, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(offset(), greaterThan(0));
      // An arrival or another screen can switch it with Home scrolled.
      await ProviderScope.containerOf(tester.element(list))
          .read(houseInViewProvider.notifier)
          .show('bangalore');
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('house-name'))).data,
        'Bangalore',
      );
      expect(offset(), 0);
    });

    testWidgets('search and commands are about the house shown', (
      tester,
    ) async {
      final engine = twoHouses();
      await pumpHouses(tester, engine);
      await switchTo(tester, 'bangalore');
      await openSearch(tester);
      await tester.enterText(find.byType(TextField).first, 'flat lamp 50%');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expectAllIn(engine, 'command.interpret', 'bangalore');
    });

    testWidgets('something added goes into the house shown', (tester) async {
      final engine = twoHouses();
      await pumpHouses(tester, engine);
      await switchTo(tester, 'bangalore');
      await openTab(tester, 'Devices');
      await tester.tap(find.byKey(const ValueKey('devices-add')));
      await tester.pumpAndSettle();
      expectAllIn(engine, 'thing.add', 'bangalore');
    });

    testWidgets('Add a house asks a name, shows it and sets it up', (
      tester,
    ) async {
      final engine = twoHouses();
      engine.answerers['house.add'] = (args) {
        engine.answers['house.list'] = {
          'ok': true,
          'houses': [
            ...(_houses['houses'] as List),
            {'id': 'goa', 'name': '${args['name']}', 'order': 2},
          ],
        };
        return {
          'ok': true,
          'house': {'id': 'goa', 'name': args['name'], 'order': 2},
        };
      };
      final store = MemoryHouseViewStore();
      await pumpHouses(tester, engine, store: store);
      await tapKey(tester, 'house-switcher');
      await tapKey(tester, 'house-add');
      await tester.enterText(find.byKey(const ValueKey('prompt-field')), 'Goa');
      await tester.pump();
      await tapKey(tester, 'prompt-save');
      expect(engine.callsOf('house.add').single.$2, {'name': 'Goa'});
      expect(store.saved, 'goa');
      // The first-run steps for a house: where it is, then its Wi-Fi.
      expect(find.text('Set up Goa'), findsOneWidget);
      expect(find.bySemanticsLabel('Step 1 of 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-home-location')), findsOneWidget);
      await tapKey(tester, 'step-skip');
      expect(find.bySemanticsLabel('Step 2 of 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-permission-location')), findsOne);
    });

    testWidgets('Rename sends the new name', (tester) async {
      final engine = twoHouses();
      await pumpHouses(tester, engine);
      await tapKey(tester, 'house-switcher');
      await tapKey(tester, 'house-menu-bangalore');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('prompt-field')),
        'Work flat',
      );
      await tapKey(tester, 'prompt-save');
      expect(engine.callsOf('house.rename').single.$2, {
        'id': 'bangalore',
        'name': 'Work flat',
      });
    });

    testWidgets('Remove of a house with things shows the engine words', (
      tester,
    ) async {
      final engine = twoHouses();
      engine.answers['house.remove'] = {
        'ok': false,
        'error': {
          'type': 'invalid',
          'message':
              'Bangalore still has 1 thing and 1 automation. Move them to '
              'another house or remove them first',
        },
      };
      await pumpHouses(tester, engine);
      await tapKey(tester, 'house-switcher');
      await tapKey(tester, 'house-menu-bangalore');
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'confirm');
      expect(engine.callsOf('house.remove').single.$2, {'id': 'bangalore'});
      expect(
        find.textContaining('Bangalore still has 1 thing and 1 automation'),
        findsOneWidget,
      );
    });
  });

  group('arrival', () {
    testWidgets('this phone arriving at a house shows it, with Undo', (
      tester,
    ) async {
      final engine = twoHouses();
      final store = MemoryHouseViewStore();
      await pumpHouses(tester, engine, store: store);
      engine.eventsOut.add({
        'event': 'house.arrived',
        'person': 'jade',
        'house': 'bangalore',
        'name': 'Bangalore',
      });
      await tester.pumpAndSettle();
      expect(find.text('Now showing Bangalore'), findsOneWidget);
      expect(store.saved, 'bangalore');
      expect(find.byKey(const ValueKey('tile-flat_lamp')), findsWidgets);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(store.saved, 'mumbai');
      expect(find.byKey(const ValueKey('tile-desk_lamp')), findsWidgets);
    });

    testWidgets('someone else arriving changes nothing', (tester) async {
      final engine = twoHouses();
      final store = MemoryHouseViewStore();
      await pumpHouses(tester, engine, store: store);
      engine.eventsOut.add({
        'event': 'house.arrived',
        'person': 'guest',
        'house': 'bangalore',
      });
      await tester.pumpAndSettle();
      expect(find.text('Now showing Bangalore'), findsNothing);
      expect(store.saved, isNull);
    });

    testWidgets('a switch by hand stays until the next arrival', (
      tester,
    ) async {
      final engine = twoHouses();
      final store = MemoryHouseViewStore();
      await pumpHouses(tester, engine, store: store);
      await switchTo(tester, 'bangalore');
      // Things change in the house and the list is read again: still
      // Bangalore.
      engine.eventsOut.add({'event': 'house.changed', 'houses': const []});
      await tester.pumpAndSettle();
      expect(store.saved, 'bangalore');
      engine.eventsOut.add({
        'event': 'house.arrived',
        'person': 'jade',
        'house': 'mumbai',
      });
      await tester.pumpAndSettle();
      expect(find.text('Now showing Mumbai'), findsOneWidget);
      expect(store.saved, 'mumbai');
    });
  });

  group('Home without rewards', () {
    testWidgets('the hero is the greeting, the house and one status line', (
      tester,
    ) async {
      final engine = twoHouses();
      engine.answers['home.stats'] = {
        'ok': true,
        'today': {'automationsRun': 4, 'tapsSaved': 9},
        'week': {'automationsRun': 12},
        'streak': {'days': 3, 'best': 5},
        'achievements': [
          {'id': 'first_device', 'title': 'First device', 'earned': true},
        ],
        'newlyEarned': ['first_device'],
      };
      engine.answers['home.mode'] = {
        'ok': true,
        'mode': 'home',
        'modes': [
          {'id': 'home', 'name': 'Home'},
        ],
      };
      await pumpHouses(tester, engine);
      expect(find.byKey(const ValueKey('home-greeting')), findsOneWidget);
      expect(find.byKey(const ValueKey('house-switcher')), findsOneWidget);
      // The mode and presence are chips under the hero, not repeated in it.
      expect(find.byKey(const ValueKey('home-status')), findsNothing);
      expect(find.text('Mode: Home'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-today')), findsNothing);
      expect(find.textContaining('taps saved'), findsNothing);
      expect(find.textContaining('streak'), findsNothing);
      expect(find.textContaining('automation active'), findsNothing);
      expect(find.textContaining('You earned'), findsNothing);
      expect(engine.callsOf('home.stats'), isEmpty);
    });

    testWidgets('Your activity is in Settings, celebrations off', (
      tester,
    ) async {
      final engine = twoHouses();
      engine.answers['home.stats'] = {
        'ok': true,
        'today': {'automationsRun': 1},
        'week': {'automationsRun': 3},
        'achievements': const <Object?>[],
      };
      await pumpHouses(tester, engine);
      await openTab(tester, 'Settings');
      await tapKey(tester, 'settings-activity');
      expect(find.byType(YourHomePage), findsOneWidget);
      expect(find.text('Your activity'), findsWidgets);
      final toggle = find.descendant(
        of: find.byKey(const ValueKey('celebrations-switch')),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expectAllIn(engine, 'home.stats', 'mumbai');
    });

    test('celebrations are off until turned on', () async {
      final container = ProviderContainer(
        overrides: [
          funPrefsStoreProvider.overrideWithValue(MemoryFunPrefsStore()),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(celebrationsProvider.notifier).isOn(), false);
      await container.read(celebrationsProvider.notifier).set(true);
      expect(container.read(celebrationsProvider), isTrue);
    });
  });

  testWidgets('the automations list holds only the house shown', (
    tester,
  ) async {
    final engine = twoHouses();
    await pumpHouses(tester, engine, store: MemoryHouseViewStore('bangalore'));
    await openTab(tester, 'Automations');
    expect(find.byType(AutomationCard), findsOneWidget);
  });
}
