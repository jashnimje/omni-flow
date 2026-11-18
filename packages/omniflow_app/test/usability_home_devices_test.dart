import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/automations/scenes.dart' show ScenesPage;
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/device_sections.dart' show historyPage;
import 'package:omniflow_app/ui/devices/device_text.dart';
import 'package:omniflow_app/ui/devices/devices_screen.dart';
import 'package:omniflow_app/ui/home/home_screen.dart';
import 'package:omniflow_app/ui/home/search_page.dart';
import 'package:omniflow_app/ui/settings/home_location_page.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show bulb, household, lamp, phone, tapKey;
import 'home_redesign_test.dart' show pumpHome, unseenPerson;
import 'tv_fixtures.dart';

/// Scrolls [key] into view, lets the scroll settle, then taps it.
Future<void> _tapShown(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// The fixes from the new-user usability review of design v2 that land on
/// Home, Devices, the TV page, the shell and the design layer.
void main() {
  group('1 Scenes from Home and search', () {
    testWidgets('with no scenes Home still has one Scenes row that opens '
        'the Scenes page', (tester) async {
      final engine = household();
      engine.answers['scene.list'] = {'ok': true, 'scenes': []};
      await pumpHome(tester, engine);
      final row = find.byKey(const ValueKey('home-scenes-empty'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('Scenes')),
        findsOneWidget,
      );
      expect(
        find.text('Save how things are and run them with one tap'),
        findsOneWidget,
      );
      await tapKey(tester, 'home-scenes-empty');
      expect(find.byType(ScenesPage), findsOneWidget);
    });

    testWidgets('search lists Scenes and a named scene under Automations, '
        'never under Settings', (tester) async {
      final engine = household();
      engine.answers['scene.list'] = {
        'ok': true,
        'scenes': [
          {'id': 'movie_scene', 'name': 'Movie scene', 'actions': []},
        ],
      };
      await pumpHome(tester, engine);
      await openSearch(tester);
      await tester.enterText(
        find.byKey(const ValueKey('command-bar')),
        'scene',
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      final automations = tester
          .getTopLeft(
            find.descendant(
              of: find.byType(OmniSectionHeader),
              matching: find.text('Automations'),
            ),
          )
          .dy;
      final scenes = find.byKey(const ValueKey('search-place-Scenes'));
      expect(scenes, findsOneWidget);
      expect(tester.getTopLeft(scenes).dy, greaterThan(automations));
      expect(
        find.byKey(const ValueKey('search-scene-movie_scene')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(OmniSectionHeader),
          matching: find.textContaining('Settings'),
        ),
        findsNothing,
      );
      expect(find.textContaining('Settings,'), findsNothing);
    });
  });

  group('3 tabs go back to their root', () {
    testWidgets('tapping Home while on a page opened from Home goes Home', (
      tester,
    ) async {
      await pumpHome(tester, household());
      await openSearch(tester);
      await tester.enterText(
        find.byKey(const ValueKey('command-bar')),
        'location',
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      await tapKey(tester, 'search-place-Home location');
      expect(find.byType(HomeLocationPage), findsOneWidget);
      await openTab(tester, 'Home');
      expect(find.byType(HomeLocationPage), findsNothing);
      expect(find.byType(SearchScreen), findsNothing);
      expect(find.byKey(const ValueKey('home-list')), findsOneWidget);
    });

    testWidgets('coming back to Home from another tab lands on Home, while '
        'the other tabs keep their page', (tester) async {
      await pumpHome(tester, household());
      await openSearch(tester);
      expect(find.byType(SearchScreen), findsOneWidget);
      await openTab(tester, 'Devices');
      await tester.tap(find.byKey(const ValueKey('device-row-desk_lamp')));
      await tester.pumpAndSettle();
      await openTab(tester, 'Home');
      expect(find.byType(SearchScreen), findsNothing);
      expect(find.byKey(const ValueKey('home-list')), findsOneWidget);
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('devices-list')), findsNothing);
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('devices-list')), findsOneWidget);
    });
  });

  group('14 Home and Devices agree', () {
    test('a device the engine cannot reach is "Not answering" everywhere', () {
      final d = DeviceView({...lamp(), 'online': false});
      expect(stateLine(d), 'Not answering');
      expect(rowSubtitle(d, 'Philips WiZ Light'), contains('not answering'));
      expect(rowSubtitle(d, 'Philips WiZ Light'), isNot(contains('offline')));
    });

    test('Home and Devices group rooms the same way, by id first', () {
      final rooms = [
        const Room(id: 'lounge', name: 'Lounge', order: 0, deviceCount: 1),
        const Room(id: 'hall', name: 'Hall', order: 1, deviceCount: 1),
      ];
      final devices = [
        DeviceView({...lamp(), 'roomId': 'lounge', 'room': 'Old name'}),
        DeviceView({...bulb(), 'roomId': 'hall', 'room': 'Hall'}),
        DeviceView(phone()),
      ];
      final groups = roomGroups(devices, rooms);
      expect(
        [for (final g in groups) g.title],
        ['Lounge', 'Hall', 'Not in a room'],
      );
      final byRoom = groupDevices(devices, DevicesView.byRoom, rooms, {});
      expect(
        [for (final g in byRoom) (g.title, g.devices.length)],
        [for (final g in groups) (g.title, g.devices.length)],
      );
    });

    testWidgets('By room keeps a room whose devices are not answering, so '
        'its rooms are Home\'s', (tester) async {
      await pumpHome(tester, household());
      await openTab(tester, 'Devices');
      final hall = find.text('Hall');
      expect(hall, findsOneWidget);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('device-row-hall_bulb')))
            .dy,
        greaterThan(tester.getTopLeft(hall).dy),
      );
      expect(find.byKey(const ValueKey('devices-not-answering')), findsNothing);
    });

    testWidgets('a phone with no room is under Not in a room on Home and on '
        'Devices', (tester) async {
      await pumpHome(tester, household());
      final none = tester.getTopLeft(find.text('Not in a room')).dy;
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('tile-this_phone'))).dy,
        greaterThan(none),
      );
      await openTab(tester, 'Devices');
      final devicesNone = tester.getTopLeft(find.text('Not in a room')).dy;
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('device-row-this_phone')))
            .dy,
        greaterThan(devicesNone),
      );
    });

    testWidgets('a home of only this phone is still the empty home', (
      tester,
    ) async {
      final engine = household()..devices = [phone()];
      await pumpHome(tester, engine);
      expect(find.byKey(const ValueKey('home-list')), findsNothing);
    });

    test('a TV the engine saved as off because it did not answer reads '
        'Not answering, and an answered off still reads Off', () {
      final guessed = DeviceView(
        tvDevice(state: const {'power': 'off', 'reachable': false}),
      );
      expect(tvLine(guessed), 'Not answering');
      expect(stateLine(guessed), 'Not answering');
      final off = DeviceView(
        tvDevice(state: const {'power': 'off', 'reachable': true}),
      );
      expect(stateLine(off), 'Off');
    });

    testWidgets('the Devices list never shows Off for a TV that did not '
        'answer', (tester) async {
      final engine = household()
        ..devices = [
          lamp(),
          tvDevice(state: const {'power': 'off', 'reachable': false}),
        ];
      await pumpHome(tester, engine);
      await openTab(tester, 'Devices');
      final row = find.byKey(const ValueKey('device-row-$tvId'));
      await tester.ensureVisible(row);
      expect(
        find.descendant(of: row, matching: find.textContaining('Off')),
        findsNothing,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('ot answering')),
        findsOneWidget,
      );
    });

    testWidgets('a TV whose last read failed says Not answering, not Off', (
      tester,
    ) async {
      final engine = tvEngine();
      engine.answers['tv.state'] = {
        'ok': true,
        'reachable': false,
        'power': 'off',
        'message': 'The TV did not answer.',
      };
      await pumpTv(tester, engine);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-power-state'))).data,
        'Not answering',
      );
      expect(find.text('Off'), findsNothing);
    });
  });

  group('15 at 200% text', () {
    testWidgets('the bell keeps its count inside its own button, clear of '
        'Help', (tester) async {
      await pumpHome(tester, household());
      final bell = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('open-alerts')),
          matching: find.byType(IconButton),
        ),
      );
      final badge = tester.getRect(
        find.byKey(const ValueKey('omni-icon-badge')),
      );
      expect(bell.contains(badge.topRight - const Offset(0.5, -0.5)), isTrue);
      final help = tester.getRect(find.byKey(const ValueKey('help-home')));
      expect(badge.overlaps(help), isFalse);
    });

    testWidgets('Help and Add move into More, the badge stays inside the '
        'bell, and the greeting wraps', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpHome(tester, household());
      expect(find.byKey(const ValueKey('help-home')), findsNothing);
      expect(find.byKey(const ValueKey('add-device')), findsNothing);
      final bell = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('open-alerts')),
          matching: find.byType(IconButton),
        ),
      );
      final badge = tester.getRect(
        find.byKey(const ValueKey('omni-icon-badge')),
      );
      expect(badge.right, lessThanOrEqualTo(bell.right + 0.5));
      final more = tester.getRect(find.byKey(const ValueKey('home-more')));
      expect(badge.overlaps(more), isFalse);
      await tester.tap(find.byKey(const ValueKey('home-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-more-help')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-more-add')), findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      // The small title in the bar wraps to two lines rather than cutting.
      await tester.drag(
        find.byKey(const ValueKey('home-list')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      final titles = tester.widgetList<Text>(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data?.startsWith('Good') ?? false) &&
              w.maxLines != null,
        ),
      );
      expect(titles, isNotEmpty);
      expect(titles.every((t) => t.maxLines! >= 2), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the presence notice says it in a line', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final engine = household();
      engine.devices = [lamp(), bulb(), phone(), unseenPerson()];
      engine.answers['zone.list'] = {'ok': true, 'zones': const <Object?>[]};
      await pumpHome(tester, engine);
      final notice = find.byKey(const ValueKey('home-notice-presence'));
      expect(notice, findsOneWidget);
      expect(
        find.descendant(
          of: notice,
          matching: find.textContaining('does not say you are away'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: notice,
          matching: find.text('OmniFlow cannot tell yet whether you are home.'),
        ),
        findsOneWidget,
      );
    });
  });

  group('16 search', () {
    testWidgets('with nothing to suggest there is no Try heading', (
      tester,
    ) async {
      final engine = household()..devices = [bulb(), phone()];
      engine.answers['automation.list'] = {'ok': true, 'automations': []};
      await pumpHome(tester, engine);
      await openSearch(tester);
      expect(find.text('Try'), findsNothing);
    });
  });

  group('19 device Activity', () {
    List<Map<String, Object?>> changes(int n) => [
      for (var i = 0; i < n; i++)
        {
          'at': DateTime.now()
              .subtract(Duration(hours: i * 3))
              .toUtc()
              .toIso8601String(),
          'key': 'state',
          'value': i.isEven,
          'by': 'user',
        },
    ];

    testWidgets('a device not answering says when it stopped', (tester) async {
      final engine = FakeEngine()
        ..devices = [
          {
            ...FakeEngine.lamp(),
            'online': false,
            'lastSeen': DateTime(2026, 11, 19, 14, 47).toIso8601String(),
          },
        ];
      engine.answers['device.history'] = {'ok': true, 'entries': []};
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await openSectionKey(tester, 'device-activity-desk_lamp');
      final row = find.byKey(const ValueKey('activity-stopped-desk_lamp'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('Stopped answering')),
        findsOneWidget,
      );
    });

    testWidgets('Earlier shows more, then pages back with before, never a '
        'longer read', (tester) async {
      final all = changes(100);
      final engine = FakeEngine()..devices = [FakeEngine.lamp()];
      engine.answerers['device.history'] = (args) {
        final before = DateTime.tryParse('${args['before']}');
        return {
          'ok': true,
          'entries': all
              .where(
                (e) =>
                    before == null ||
                    DateTime.parse('${e['at']}').isBefore(before),
              )
              .take(args['limit'] as int? ?? 100)
              .toList(),
        };
      };
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await openSectionKey(tester, 'device-activity-desk_lamp');
      expect(
        find.byKey(const ValueKey('activity-desk_lamp-7')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('activity-desk_lamp-8')), findsNothing);
      await _tapShown(tester, 'activity-earlier-desk_lamp');
      expect(
        find.byKey(const ValueKey('activity-desk_lamp-23')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('activity-desk_lamp-24')), findsNothing);
      await _tapShown(tester, 'activity-earlier-desk_lamp');
      expect(
        find.byKey(const ValueKey('activity-desk_lamp-39')),
        findsOneWidget,
      );
      final calls = engine.callsOf('device.history').map((c) => c.$2).toList();
      expect(calls.where((c) => c['before'] != null), hasLength(1));
      expect({
        for (final c in calls) c['limit'],
      }, everyElement(lessThanOrEqualTo(historyPage + 1)));
      // The 40th row is the 40th change: none lost or repeated.
      final row = tester.widget<OmniListRow>(
        find.byKey(const ValueKey('activity-desk_lamp-39')),
      );
      expect(row.title, 'Turned off by you');
    });

    testWidgets('Activity shows a device stopping answering and answering '
        'again, once, from the history', (tester) async {
      final now = DateTime.now().toUtc();
      String at(int minutes) =>
          now.subtract(Duration(minutes: minutes)).toIso8601String();
      final engine = FakeEngine()
        ..devices = [
          {...FakeEngine.lamp(), 'online': false, 'lastSeen': at(30)},
        ];
      engine.answers['device.history'] = {
        'ok': true,
        'entries': [
          {'at': at(20), 'key': 'online', 'value': false},
          {'at': at(40), 'key': 'online', 'value': true},
          {'at': at(50), 'key': 'online', 'value': false},
          {'at': at(60), 'key': 'state', 'value': true, 'by': 'user'},
        ],
      };
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await openSectionKey(tester, 'device-activity-desk_lamp');
      String title(int i) => tester
          .widget<OmniListRow>(find.byKey(ValueKey('activity-desk_lamp-$i')))
          .title;
      expect(
        [for (var i = 0; i < 4; i++) title(i)],
        [
          'Stopped answering',
          'Answering again',
          'Stopped answering',
          'Turned on by you',
        ],
      );
      expect(
        find.byKey(const ValueKey('activity-stopped-desk_lamp')),
        findsNothing,
        reason: 'the history already says it stopped',
      );
    });
  });

  group('20 snackbars', () {
    testWidgets('a message with an action stays at least 6 seconds', (
      tester,
    ) async {
      await pumpApp(tester, FakeEngine());
      showMessage('Removed', action: 'Undo', onAction: () {});
      await tester.pump();
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(bar.duration, greaterThanOrEqualTo(const Duration(seconds: 6)));
      // Still there after the 4 seconds a plain message gets.
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Undo'), findsOneWidget);
      // Gone on its own once its time is up.
      await tester.pump(messageWithActionFor);
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
    });
  });

  group('21 the torch', () {
    testWidgets('a phone switch Android never reports says so, not "Not '
        'read yet"', (tester) async {
      final engine = FakeEngine()
        ..devices = [
          {
            ...phone(),
            'capabilities': [
              {
                'id': 'torch',
                'type': 'toggle',
                'label': 'Torch',
                'stateKey': 'torch',
              },
            ],
          },
        ];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'this_phone');
      await tester.ensureVisible(
        find.byKey(const ValueKey('this_phone.torch')),
      );
      expect(find.text('Not read yet'), findsNothing);
      expect(find.text('It does not report whether it is on'), findsOneWidget);
    });
  });

  testWidgets('Home says "not answering", never "offline"', (tester) async {
    await pumpHome(tester, household());
    expect(find.text('Hall bulb is not answering'), findsOneWidget);
    expect(find.textContaining('offline'), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
