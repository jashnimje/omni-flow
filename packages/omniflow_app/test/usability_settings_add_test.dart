import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/home_location_calls.dart';
import 'package:omniflow_app/ui/add/add_by_hand_page.dart';
import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/ui/help/screen_help.dart';
import 'package:omniflow_app/ui/settings/alerts_page.dart';
import 'package:omniflow_app/ui/settings/appearance_page.dart';
import 'package:omniflow_app/ui/settings/cities.dart';
import 'package:omniflow_app/ui/settings/home_location_page.dart';
import 'package:omniflow_app/ui/settings/settings_screen.dart';

import 'add_flow_test.dart' show drivers;
import 'fake_engine.dart';
import 'screen_harness.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key).first);
  await tester.pumpAndSettle();
  await tester.tap(_key(key).first);
  await tester.pumpAndSettle();
}

/// Opens the collapsed section [key] by its header.
Future<void> _open(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: _key(key), matching: find.byType(InkWell)).first,
  );
  await tester.pumpAndSettle();
}

/// The text of [finder]'s only Text with [text].
Text _text(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text));

Map<String, Object?> _homeAt(
  double latitude,
  double longitude, {
  String? name,
}) => {
  'ok': true,
  'location': {'latitude': latitude, 'longitude': longitude},
  'name': ?name,
  'today': {
    'sunrise': DateTime(2026, 11, 19, 6, 20).toIso8601String(),
    'sunset': DateTime(2026, 11, 19, 17, 55).toIso8601String(),
  },
};

void main() {
  group('Home location in front (report 2)', () {
    testWidgets('sits under Your home with the city it is in, without '
        'opening More settings', (tester) async {
      final engine = FakeEngine()
        ..answers['home.location'] = _homeAt(
          12.9716,
          77.5946,
          name: 'Bengaluru, India',
        );
      await pumpScreen(tester, engine, const SettingsScreen());
      final row = _key('settings-home-location');
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text('Bengaluru, India · sunrise 06:20, sunset 17:55'),
        ),
        findsOneWidget,
      );
      final top = tester.getTopLeft(row).dy;
      expect(top, greaterThan(tester.getTopLeft(find.text('Your home')).dy));
      expect(top, lessThan(tester.getTopLeft(find.text('This phone')).dy));
      expect(
        tester.getTopLeft(_key('settings-places')).dy,
        lessThan(top),
        reason: 'right under Places and people',
      );
    });

    testWidgets('a place set elsewhere is named by the nearest city', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['home.location'] = _homeAt(12.95, 77.62);
      await pumpScreen(tester, engine, const SettingsScreen());
      expect(
        find.text('Near Bengaluru, India · sunrise 06:20, sunset 17:55'),
        findsOneWidget,
      );
    });

    testWidgets('not set says what needs it', (tester) async {
      await pumpScreen(tester, FakeEngine(), const SettingsScreen());
      expect(
        find.text(
          'Not set. Sunrise and sunset automations and the weather need it',
        ),
        findsOneWidget,
      );
    });
  });

  group('one word for a device that cannot be reached', () {
    testWidgets('Alerts says a device stops answering, not goes offline', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['alerts.get'] = {
          'ok': true,
          'offline': true,
          'battery': true,
        };
      await pumpScreen(tester, engine, const AlertsPage());
      expect(find.text('A device stops answering'), findsOneWidget);
      expect(find.textContaining('ffline'), findsNothing);
    });

    test('no help page says offline', () {
      for (final help in screenHelp.values) {
        for (final section in help.sections) {
          expect(
            '${section.heading} ${section.body}'.toLowerCase(),
            isNot(contains('offline')),
            reason: help.title,
          );
        }
      }
      final devices = screenHelp.values
          .expand((h) => h.sections)
          .where((s) => s.heading == 'Not answering');
      expect(devices, hasLength(1));
    });
  });

  group('Home location without coordinates (report 4)', () {
    testWidgets('searching for a city sends its place with its name, and '
        'reads the name back from the engine', (tester) async {
      final engine = FakeEngine()
        ..answers['home.location'] = {'ok': true, 'location': null};
      engine.answerers['home.location.set'] = (args) {
        engine.answers['home.location'] = _homeAt(
          (args['latitude']! as num).toDouble(),
          (args['longitude']! as num).toDouble(),
          name: args['name'] as String?,
        );
        return engine.answers['home.location']!;
      };
      await pumpScreen(tester, engine, const HomeLocationPage());
      // Using the phone's location comes first, then the city search.
      expect(_key('home-location-use-phone'), findsOneWidget);
      expect(
        tester.getTopLeft(_key('home-location-use-phone')).dy,
        lessThan(tester.getTopLeft(_key('home-location-search')).dy),
      );
      expect(find.text('Search for your city'), findsOneWidget);
      expect(find.textContaining('London'), findsNothing);
      expect(find.textContaining('51.5074'), findsNothing);

      await tester.enterText(_key('home-location-search'), 'banga');
      await tester.pumpAndSettle();
      await _tap(tester, 'home-location-city-Bengaluru');
      expect(engine.callsOf('home.location.set').single.$2, {
        'latitude': 12.9716,
        'longitude': 77.5946,
        'name': 'Bengaluru, India',
      });
      expect(find.text('Today in Bengaluru, India'), findsOneWidget);
    });

    testWidgets('typed coordinates go without a name, and the place reads '
        'by the nearest city', (tester) async {
      final engine = FakeEngine()
        ..answers['home.location'] = _homeAt(
          12.9716,
          77.5946,
          name: 'Bengaluru, India',
        );
      engine.answerers['home.location.set'] = (args) {
        engine.answers['home.location'] = _homeAt(
          (args['latitude']! as num).toDouble(),
          (args['longitude']! as num).toDouble(),
          name: args['name'] as String?,
        );
        return engine.answers['home.location']!;
      };
      await pumpScreen(tester, engine, const HomeLocationPage());
      await _open(tester, 'home-location-advanced');
      await tester.enterText(_key('home-location-latitude'), '12.95');
      await tester.enterText(_key('home-location-longitude'), '77.62');
      await _tap(tester, 'home-location-save');
      expect(engine.callsOf('home.location.set').single.$2, {
        'latitude': 12.95,
        'longitude': 77.62,
      });
      expect(find.text('Today in Near Bengaluru, India'), findsOneWidget);
    });

    testWidgets('a name an older build kept on this phone goes to the '
        'engine once, then the file on the phone is deleted', (tester) async {
      final store = MemoryHomePlaceNamesStore([
        (name: 'Mysuru, India', latitude: 12.2958, longitude: 76.6394),
        (name: 'Bengaluru, India', latitude: 12.9716, longitude: 77.5946),
      ]);
      final engine = FakeEngine()
        ..answers['home.location'] = _homeAt(12.9716, 77.5946);
      engine.answerers['home.location.set'] = (args) {
        engine.answers['home.location'] = _homeAt(
          (args['latitude']! as num).toDouble(),
          (args['longitude']! as num).toDouble(),
          name: args['name'] as String?,
        );
        return engine.answers['home.location']!;
      };
      await pumpScreen(
        tester,
        engine,
        const SettingsScreen(),
        overrides: [homePlaceNamesStoreProvider.overrideWithValue(store)],
      );
      expect(engine.callsOf('home.location.set').single.$2, {
        'latitude': 12.9716,
        'longitude': 77.5946,
        'name': 'Bengaluru, India',
      });
      expect(store.deleted, isTrue);
      expect(
        find.text('Bengaluru, India · sunrise 06:20, sunset 17:55'),
        findsOneWidget,
      );
    });

    test('the move keeps the file while the engine does not answer, and '
        'never overwrites a name the engine has', () async {
      final kept = [
        (name: 'Bengaluru, India', latitude: 12.9716, longitude: 77.5946),
      ];
      final down = FakeEngine()
        ..answers['home.location'] = {
          'ok': false,
          'error': {'type': 'unreachable', 'message': 'no'},
        };
      final store = MemoryHomePlaceNamesStore(kept);
      expect(await moveHomePlaceNames(HomeLocationApi(down), store), isFalse);
      expect(store.deleted, isFalse);

      final named = FakeEngine()
        ..answers['home.location'] = _homeAt(
          12.9716,
          77.5946,
          name: 'Home, Bengaluru',
        );
      expect(await moveHomePlaceNames(HomeLocationApi(named), store), isFalse);
      expect(named.callsOf('home.location.set'), isEmpty);
      expect(store.deleted, isTrue);
    });

    testWidgets('a name that is not listed says what to do instead', (
      tester,
    ) async {
      await pumpScreen(tester, FakeEngine(), const HomeLocationPage());
      await tester.enterText(_key('home-location-search'), 'zzqx');
      await tester.pumpAndSettle();
      expect(_key('home-location-no-city'), findsOneWidget);
    });

    testWidgets('latitude and longitude wait inside a closed Advanced', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['home.location'] = {'ok': true, 'location': null};
      await pumpScreen(tester, engine, const HomeLocationPage());
      expect(_key('home-location-latitude'), findsNothing);
      expect(_key('home-location-save'), findsNothing);
      await _open(tester, 'home-location-advanced');
      expect(_key('home-location-latitude'), findsOneWidget);
      expect(_key('home-location-longitude'), findsOneWidget);
      expect(find.text('In degrees, north is positive'), findsOneWidget);
    });

    test('the city list covers India and the world capitals offline', () {
      for (final (query, city) in [
        ('bangalore', 'Bengaluru'),
        ('bombay', 'Mumbai'),
        ('delhi', 'New Delhi'),
        ('chennai', 'Chennai'),
        ('kolkata', 'Kolkata'),
        ('hyderabad', 'Hyderabad'),
        ('pune', 'Pune'),
        ('tokyo', 'Tokyo'),
        ('nairobi', 'Nairobi'),
        ('canberra', 'Canberra'),
        ('ottawa', 'Ottawa'),
        ('lima', 'Lima'),
      ]) {
        expect(searchCities(query).first.name, city, reason: query);
      }
      expect(cities.where((c) => c.country == 'India').length, greaterThan(50));
      expect(cities.map((c) => c.country).toSet().length, greaterThan(190));
      for (final c in cities) {
        expect(c.latitude.abs(), lessThanOrEqualTo(90), reason: c.name);
        expect(c.longitude.abs(), lessThanOrEqualTo(180), reason: c.name);
      }
      expect(nearestCity(19.07, 72.88)?.name, 'Mumbai');
      expect(nearestCity(0, -140), isNull, reason: 'mid-Pacific');
    });
  });

  group('Add device address (report 5)', () {
    testWidgets('the field asks for the IP address on your Wi-Fi, says '
        'where to find it, and the scan comes first', (tester) async {
      final engine = FakeEngine()..answers['driver.list'] = drivers;
      await pumpScreen(
        tester,
        engine,
        const AddByHandPage(driver: 'philips_hue_light'),
      );
      expect(find.text('IP address on your Wi-Fi'), findsOneWidget);
      expect(find.text('192.168.1.20'), findsOneWidget);
      expect(find.text(ipAddressHelp), findsOneWidget);
      expect(find.text('Address'), findsNothing);
      expect(find.text('Look for it on your Wi-Fi'), findsOneWidget);
      expect(
        tester.getTopLeft(_key('add-scan')).dy,
        lessThan(tester.getTopLeft(_key('add-host')).dy),
      );
      expect(
        find.text('Look for it, or type its IP address, first.'),
        findsOneWidget,
      );
    });
  });

  group('Plain words in Settings (report 21)', () {
    testWidgets('More settings says what each row is, and its subtitles '
        'wrap', (tester) async {
      await pumpScreen(tester, FakeEngine(), const SettingsScreen());
      await _open(tester, 'settings-more');
      expect(find.text('Variables'), findsNothing);
      expect(find.text('Boards on USB'), findsNothing);
      expect(find.textContaining('firmware'), findsNothing);
      expect(find.text('Saved values'), findsOneWidget);
      expect(find.text('Plug in a board'), findsOneWidget);
      for (final subtitle in [
        'Lights warm and dim at night, cool and bright at midday',
        'Lights that look lived-in while nobody is home',
        'What your plugs use, and the price of one kWh',
        'What automations remember, such as whether you are away. To see, '
            'change or clear',
        'Set up a small board such as an ESP32 over a USB cable, or put the '
            'OmniFlow program on it',
      ]) {
        expect(
          _text(tester, subtitle).maxLines,
          greaterThanOrEqualTo(2),
          reason: subtitle,
        );
      }
    });

    testWidgets('Add says what firmware is', (tester) async {
      await pumpScreen(tester, FakeEngine(), const AddPage());
      await _open(tester, 'add-more-ways');
      expect(find.text('Put the OmniFlow program on a board'), findsOneWidget);
      expect(find.textContaining('called firmware'), findsOneWidget);
    });

    testWidgets('Appearance puts light and dark first, in plain words, and '
        'Pure black wraps', (tester) async {
      await pumpScreen(tester, FakeEngine(), const AppearancePage());
      expect(find.textContaining("phone's wallpaper"), findsOneWidget);
      for (final choice in ['system', 'light', 'dark']) {
        expect(_key('appearance-theme-$choice'), findsOneWidget);
      }
      expect(
        tester.getTopLeft(_key('appearance-theme-light')).dy,
        lessThan(tester.getTopLeft(find.text('Colours')).dy),
      );
      final pureBlack = tester.widget<Text>(
        find.descendant(
          of: _key('appearance-pure-black'),
          matching: find.textContaining('Fully black screens'),
        ),
      );
      expect(pureBlack.maxLines, greaterThanOrEqualTo(3));
      expect(pureBlack.data, isNot(contains('OLED')));
    });
  });

  group('Settings search index (report 2, search)', () {
    SettingsPlace place(String title) =>
        settingsPlaces.singleWhere((p) => p.title == title);

    test('Home location and Scenes say where they really are', () {
      expect(place('Home location').section, 'Settings, Your home');
      expect(place('Scenes').section, 'Automations');
      expect(place('Saved values').section, 'Settings, More settings');
    });

    test('the words people use find them', () {
      expect(place('Home location').matches('city'), isTrue);
      expect(place('Home location').matches('home loc'), isTrue);
      expect(place('Saved values').matches('variables'), isTrue);
      expect(place('Appearance').matches('dark'), isTrue);
      expect(place('Scenes').matches('city'), isFalse);
    });
  });
}
