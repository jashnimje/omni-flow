import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/design/automation_look.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/home/run_section.dart';

import 'fake_engine.dart';
import 'home_devices_test.dart' show household, tapKey;
import 'houses_test.dart' show pumpHouses, switchTo, twoHouses;
import 'tv_fixtures.dart';

/// The second fix round on Home, Devices, the TV page, Search and Your
/// activity.
void main() {
  const modes = {
    'ok': true,
    'mode': 'home',
    'modes': [
      {'id': 'home', 'name': 'Home'},
    ],
  };

  StatusKind? dotIn(WidgetTester tester, String key) => tester
      .widgetList<StatusDot>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(StatusDot),
        ),
      )
      .firstOrNull
      ?.kind;

  group('Home', () {
    testWidgets('the hero does not repeat the mode and presence, which sit '
        'in one row of chips', (tester) async {
      final engine = household()..answers['home.mode'] = modes;
      await pumpApp(tester, engine);
      expect(find.byKey(const ValueKey('home-status')), findsNothing);
      expect(find.text('Home · Home mode'), findsNothing);
      final mode = tester.getCenter(find.byKey(const ValueKey('mode-chip')));
      final presence = tester.getCenter(find.text('You are home'));
      expect((mode.dy - presence.dy).abs(), lessThan(4));
    });

    testWidgets('a Run tile failed in one house shows nothing in the other', (
      tester,
    ) async {
      final engine = twoHouses()
        ..answers['scene.run'] = {
          'ok': false,
          'error': {
            'type': 'device_error',
            'message': 'Bed lamp did not answer',
          },
        };
      await pumpHouses(tester, engine);
      await switchTo(tester, 'bangalore');
      await tapKey(tester, 'scene-flat_evening');
      expect(find.byKey(const ValueKey('run-failed-flat_evening')), findsOne);
      await switchTo(tester, 'mumbai');
      expect(find.text('Movie'), findsOneWidget);
      expect(find.byIcon(OmniIcons.error), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('run-state-movie'))).data,
        'Scene',
      );
    });

    testWidgets('offline is the muted dot on Home and Devices alike', (
      tester,
    ) async {
      await pumpApp(tester, household());
      expect(dotIn(tester, 'home-offline'), StatusKind.offline);
      await openTab(tester, 'Devices');
      expect(dotIn(tester, 'device-row-hall_bulb'), StatusKind.offline);
    });

    testWidgets('a room with every light offline is the muted offline tile', (
      tester,
    ) async {
      final engine = household()
        ..answers['room.state'] = {
          'ok': true,
          'room': {'id': 'lounge', 'name': 'Lounge'},
          'lights': 2,
          'lightsOn': 0,
          'offline': 2,
        };
      await pumpApp(tester, engine);
      final tile = tester.widget<OmniTile>(
        find.byKey(const ValueKey('room-tile-lounge')).first,
      );
      expect(tile.offline, isTrue);
      expect(tile.wash, isNull);
      expect(tile.onIconTap, isNull);
    });

    testWidgets('a room page renames the room and switches all its lights', (
      tester,
    ) async {
      final engine = household()
        ..answers['room.state'] = {
          'ok': true,
          'room': {'id': 'lounge', 'name': 'Lounge'},
          'lights': 1,
          'lightsOn': 0,
        }
        ..answers['room.invoke'] = {'ok': true, 'results': const <Object?>[]}
        ..answers['room.save'] = {'ok': true, 'id': 'lounge'};
      await pumpApp(tester, engine);
      await tester.tap(find.byKey(const ValueKey('room-tile-lounge')).first);
      await tester.pumpAndSettle();
      expect(find.text('Lights'), findsOneWidget);
      await tapKey(tester, 'room-lights-lounge');
      expect(engine.callsOf('room.invoke').single.$2, {
        'room': 'lounge',
        'capability': 'power',
        'params': {'value': true},
        'only': 'lights',
      });
      await tapKey(tester, 'room-rename');
      await tester.enterText(
        find.byKey(const ValueKey('prompt-field')),
        'Living room',
      );
      await tapKey(tester, 'prompt-save');
      expect(engine.callsOf('room.save').single.$2, {
        'id': 'lounge',
        'name': 'Living room',
        'order': 0,
      });
    });

    testWidgets('Run tiles at large text are wider and keep their names', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(412, 900),
                textScaler: TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: SizedBox(
                    width: 384,
                    child: RunSection(
                      items: const [
                        RunItem(
                          id: 'movie',
                          name: 'Movie time',
                          icon: OmniIcons.scene,
                          isScene: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final name = tester.widget<Text>(find.text('Save how things are now'));
      expect(name.maxLines, 4);
      final movie = tester.getSize(find.byKey(const ValueKey('scene-movie')));
      // Two a row, not three.
      expect(movie.width, greaterThan(170));
    });
  });

  group('Devices', () {
    testWidgets('one search: the field over the list, no header search', (
      tester,
    ) async {
      await pumpApp(tester, household());
      await openTab(tester, 'Devices');
      expect(find.byKey(const ValueKey('devices-search')), findsNothing);
      expect(find.byKey(const ValueKey('devices-filter')), findsOneWidget);
    });

    testWidgets('on a short screen the view and search scroll with the list', (
      tester,
    ) async {
      await pumpApp(tester, household());
      tester.view.physicalSize = const Size(1236, 1200);
      await tester.pumpAndSettle();
      await openTab(tester, 'Devices');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('devices-list')),
          matching: find.byKey(const ValueKey('devices-view')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('every Device row has an icon box, and automations read the '
        'same online and offline', (tester) async {
      await pumpApp(tester, household());
      await openDevicePage(tester, 'desk_lamp');
      for (final key in ['device-room-desk_lamp', 'device-details-desk_lamp']) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        expect(
          tester.widget<OmniListRow>(find.byKey(ValueKey(key))).icon,
          isNotNull,
          reason: key,
        );
      }
      expect(
        tester
            .widget<OmniListRow>(find.byKey(const ValueKey('device-advanced')))
            .icon,
        isNotNull,
      );
      expect(find.text('Automations that use it'), findsOneWidget);
      expect(find.text('Used in'), findsNothing);
      expect(find.text('Has a step on it'), findsWidgets);
    });

    testWidgets('a switch the device never reports is a switch that shows '
        'what was last set', (tester) async {
      final engine = household();
      engine.devices = [
        FakeEngine.lamp(
          extra: [
            {'id': 'torch', 'type': 'toggle', 'label': 'Torch'},
          ],
        ),
      ];
      await pumpApp(tester, engine);
      await openDevicePage(tester, 'desk_lamp');
      await tester.ensureVisible(find.byKey(const ValueKey('desk_lamp.torch')));
      expect(find.text('It does not report whether it is on'), findsOneWidget);
      expect(find.text('On'), findsNothing);
      await tapKey(tester, 'switch-desk_lamp.torch');
      expect(engine.callsOf('device.invoke').last.$2, {
        'id': 'desk_lamp',
        'capability': 'torch',
        'params': {'value': true},
      });
      expect(find.text('Last set on here'), findsOneWidget);
    });
  });

  group('Search', () {
    test('a sentence reads as one plain line, no arrows', () {
      expect(
        sentenceText(const [
          SentencePart(SentenceKind.when, 'At 7:30 PM'),
          SentencePart(SentenceKind.text, '→'),
          SentencePart(SentenceKind.then, 'wake the TV'),
        ]),
        'At 7:30 PM, wake the TV',
      );
    });

    testWidgets('an automation wears its own badge, and no results offers '
        'nothing unrelated', (tester) async {
      final engine = household();
      await pumpApp(tester, engine);
      await openSearch(tester);
      await tester.enterText(find.byType(TextField).first, 'desk button');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      final row = find.byKey(const ValueKey('search-automation-desk_button'));
      expect(
        find.descendant(of: row, matching: find.byType(AutomationBadge)),
        findsOneWidget,
      );
      expect(find.textContaining('→'), findsNothing);
      engine.answers['command.interpret'] = {'ok': false};
      await tester.enterText(find.byType(TextField).first, 'zzzz');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('search-none')), findsOneWidget);
      expect(find.text('Try'), findsNothing);
    });
  });

  group('TV', () {
    testWidgets('System names each app once, and offers no Stop for a '
        'system app', (tester) async {
      final engine = tvEngine()
        ..answers.addAll({
          'tv.system': {
            'ok': true,
            'cpu': {'percent': 42},
            'memory': {'totalKb': 2000000, 'availableKb': 500000},
          },
          'tv.processes': {
            'ok': true,
            'apps': [
              {'package': 'com.netflix.ninja', 'pid': 1, 'memoryKb': 1000},
              {'package': 'com.netflix.ninja', 'pid': 2, 'memoryKb': 1000},
              {
                'package': 'com.google.android.gms.unstable',
                'pid': 3,
                'memoryKb': 500,
              },
              {'package': 'android.process.media', 'pid': 4, 'memoryKb': 400},
            ],
          },
        });
      engine.answerers['tv.apps'] = (args) => {
        'ok': true,
        'apps': [
          {'package': 'com.google.android.gms', 'system': true},
          {'package': 'com.netflix.ninja', 'label': 'Netflix'},
        ],
      };
      await pumpTv(tester, engine);
      await openTvTab(tester, 'System');
      expect(
        find.byKey(const ValueKey('tv-process-com.netflix.ninja')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tv-process-stop-com.netflix.ninja')),
        findsOneWidget,
      );
      expect(find.text('Google Play services'), findsOneWidget);
      expect(find.text('Unstable'), findsNothing);
      expect(
        find.byKey(const ValueKey('tv-process-stop-com.google.android.gms')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('tv-process-stop-android.process.media')),
        findsNothing,
      );
    });

    testWidgets('Settings sit in one card per group, with no type tag', (
      tester,
    ) async {
      final engine = tvEngine();
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      expect(find.text('text'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-list')),
          matching: find.byType(OmniCard),
        ),
        findsNWidgets(3),
      );
    });

    testWidgets('the remote has one row of tabs: how it works is a choice', (
      tester,
    ) async {
      final engine = tvEngine();
      await pumpTv(tester, engine);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tv-remote')),
          matching: find.byType(OmniSegmented<Object>),
        ),
        findsNothing,
      );
      expect(find.text('Keys: Buttons'), findsOneWidget);
      await tapKey(tester, 'tv-remote-mode');
      await tapKey(tester, 'tv-remote-mode-gamepad');
      expect(find.text('Keys: Gamepad'), findsOneWidget);
    });
  });
}
