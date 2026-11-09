import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';
import 'tv_fixtures.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = tvEngine());

  group('the TV card', () {
    testWidgets('a TV gets the compact card, not one control per capability', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      expect(find.byKey(const ValueKey('tv-open-$tvId')), findsOneWidget);
      expect(find.byKey(const ValueKey('$tvId.remote')), findsNothing);
      expect(find.byKey(const ValueKey('$tvId.wake')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('tv-card-now-$tvId')))
            .data,
        'com.netflix.ninja  Playing',
      );
      expect(find.byKey(const ValueKey('desk_lamp.power')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-menu-$tvId')), findsOneWidget);
    });

    testWidgets('high-risk TV capabilities do not say they run host commands', (
      tester,
    ) async {
      final tv = tvDevice();
      tv['capabilities'] = [
        ...(tv['capabilities'] as List),
        {
          'id': 'set_setting',
          'type': 'action',
          'label': 'Set a setting',
          'highRisk': true,
          'params': {},
        },
      ];
      engine.devices = [tv, FakeEngine.lamp()];
      await pumpTv(tester, engine);
      expect(find.byKey(const ValueKey('tv-open-$tvId')), findsOneWidget);
      expect(find.byKey(const ValueKey('high-risk-$tvId')), findsNothing);
    });

    testWidgets('power sleeps a TV that is on, and the slider sets volume', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await tester.tap(find.byKey(const ValueKey('tv-card-power-$tvId')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key').single, {'id': tvId, 'keycode': 223});
      await tester.tap(find.byKey(const ValueKey('tv-card-volume-$tvId')));
      await tester.pumpAndSettle();
      final level = argsOf(engine, 'tv.volume').single['level'] as int;
      expect(level, inInclusiveRange(40, 60));
    });

    testWidgets('a sleeping TV offers wake', (tester) async {
      engine.devices = [
        tvDevice(state: const {'power': 'asleep'}),
      ];
      await pumpTv(tester, engine);
      expect(find.text('Asleep'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tv-card-power-$tvId')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key').single, {'id': tvId, 'keycode': 224});
    });
  });

  group('the live header', () {
    testWidgets('shows power, the app in front, playback and volume', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      expect(argsOf(engine, 'tv.state').first, {'id': tvId});
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-power-state'))).data,
        'On',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-app'))).data,
        'com.netflix.ninja',
      );
      expect(find.text('Paused'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-volume-value'))).data,
        '30',
      );
    });

    testWidgets('mute sends the catalog key and the slider the level', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      await tester.tap(find.byKey(const ValueKey('tv-mute')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key').single, {'id': tvId, 'key': 'mute'});
      await tester.tap(find.byKey(const ValueKey('tv-volume')));
      await tester.pumpAndSettle();
      final level = argsOf(engine, 'tv.volume').single['level'] as int;
      expect(level, inInclusiveRange(40, 60));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-volume-value'))).data,
        '$level',
      );
    });

    testWidgets('an unreachable TV shows why, and retry reads it again', (
      tester,
    ) async {
      engine.answers['tv.state'] = {
        'ok': false,
        'error': {
          'type': 'unavailable',
          'message': 'no answer from 192.168.1.60:5555',
        },
      };
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      expect(find.byKey(const ValueKey('tv-offline')), findsOneWidget);
      expect(
        find.textContaining('no answer from 192.168.1.60'),
        findsOneWidget,
      );
      final before = engine.callsOf('tv.state').length;
      engine.answers['tv.state'] = {'ok': true, 'power': 'on'};
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tv.state').length, before + 1);
      expect(find.byKey(const ValueKey('tv-offline')), findsNothing);
    });

    testWidgets('a poll failure from the hub marks the TV offline', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      engine.eventsOut.add({
        'event': 'device.pollFailed',
        'device': tvId,
        'error': 'connection refused',
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('connection refused'), findsWidgets);
    });

    testWidgets('a stateChanged event updates the header', (tester) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      engine.eventsOut.add({
        'event': 'device.stateChanged',
        'device': {
          'id': tvId,
          'state': {'power': 'on', 'app': 'com.sonyliv', 'volume': 12},
        },
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-app'))).data,
        'com.sonyliv',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-volume-value'))).data,
        '12',
      );
    });
  });

  group('the remote', () {
    testWidgets('keys go by catalog name, or by keycode when it has none', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      await tester.tap(find.byKey(const ValueKey('key-23')));
      await tester.tap(find.byKey(const ValueKey('key-244')));
      await tester.tap(find.byKey(const ValueKey('key-245')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key'), [
        {'id': tvId, 'key': 'ok'},
        {'id': tvId, 'key': 'hdmi_2'},
        {'id': tvId, 'keycode': 245},
      ]);
    });

    testWidgets('every part of the layout is there', (tester) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      for (final code in [
        26,
        223,
        224,
        178,
        243,
        246,
        4,
        3,
        82,
        19,
        20,
        21,
        22,
        23,
        176,
        219,
        24,
        25,
        164,
        166,
        167,
        172,
        165,
        175,
        85,
        89,
        90,
        7,
        16,
        183,
        186,
      ]) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('key-$code')),
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('tv-remote')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.byKey(ValueKey('key-$code')), findsOneWidget);
      }
    });

    testWidgets('long press holds the key, and so does the Long press mode', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      await tester.longPress(find.byKey(const ValueKey('key-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('long-press')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('key-19')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key'), [
        {'id': tvId, 'key': 'home', 'longPress': true},
        {'id': tvId, 'key': 'up', 'longPress': true},
      ]);
    });

    testWidgets('the text box types on the TV and clears', (tester) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      final box = find.byKey(const ValueKey('tv-text'));
      await tester.scrollUntilVisible(
        box,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('tv-remote')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(box, 'stranger things');
      await tester.tap(find.byKey(const ValueKey('tv-text-send')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.text').single, {
        'id': tvId,
        'text': 'stranger things',
      });
      expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    });

    testWidgets('catalog keys the layout does not place are under More', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      final zoom = find.byKey(const ValueKey('catalog-zoom'));
      await tester.scrollUntilVisible(
        zoom,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('tv-remote')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('More system keys'), findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-ok')), findsNothing);
      await tester.tap(zoom);
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key').single, {'id': tvId, 'key': 'zoom'});
    });

    testWidgets('a failed key shows the error', (tester) async {
      engine.answers['tv.key'] = {
        'ok': false,
        'error': {'type': 'unavailable', 'message': 'the TV is off'},
      };
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Remote');
      await tester.tap(find.byKey(const ValueKey('key-23')));
      await tester.pumpAndSettle();
      expect(find.text('the TV is off'), findsOneWidget);
    });
  });
}
