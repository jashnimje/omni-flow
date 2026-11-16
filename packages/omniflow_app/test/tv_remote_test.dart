import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';
import 'tv_fixtures.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = tvEngine());

  Finder remoteScroll() => find
      .descendant(
        of: find.byKey(const ValueKey('tv-remote')),
        matching: find.byType(Scrollable),
      )
      .first;

  bool volumeShows(String value) => find
      .descendant(
        of: find.byKey(const ValueKey('tv-volume')),
        matching: find.text(value),
      )
      .evaluate()
      .isNotEmpty;

  group('the live header', () {
    testWidgets('names the app in front, its playback and the volume', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      expect(argsOf(engine, 'tv.state').first, {
        'id': tvId,
        'allowPairing': false,
      });
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-app'))).data,
        'Netflix',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-playing'))).data,
        ' · paused',
      );
      expect(volumeShows('30'), isTrue);
      expect(find.byKey(const ValueKey('tv-power-state')), findsNothing);
    });

    testWidgets('a sleeping TV says so in place of the app', (tester) async {
      engine.answers['tv.state'] = {'ok': true, 'power': 'asleep'};
      await pumpTv(tester, engine);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tv-power-state'))).data,
        'Asleep',
      );
      await tester.tap(find.byKey(const ValueKey('tv-header-power')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key').single, {'id': tvId, 'keycode': 224});
    });

    testWidgets('mute sends the catalog key and the slider the level', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await tester.tap(find.byKey(const ValueKey('tv-mute')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key').single, {'id': tvId, 'key': 'mute'});
      await tester.tap(find.byKey(const ValueKey('tv-volume')));
      await tester.pumpAndSettle();
      final level = argsOf(engine, 'tv.volume').last['level'] as int;
      expect(level, inInclusiveRange(40, 60));
      expect(volumeShows('$level'), isTrue);
    });

    testWidgets('the header opens the room, name and settings of the TV', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await tester.tap(find.byKey(const ValueKey('tv-header-device')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('device-details-$tvId')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-remove-$tvId')), findsOneWidget);
    });

    testWidgets('a TV that has not let OmniFlow in says to pair, and the '
        'reads never prompt it', (tester) async {
      engine.answers['tv.state'] = {
        'ok': false,
        'error': {'type': 'needs_user', 'message': 'lounge_tv is not paired'},
      };
      await pumpTv(tester, engine);
      expect(find.textContaining('has not let OmniFlow in'), findsOneWidget);
      expect(
        argsOf(engine, 'tv.state').every((a) => a['allowPairing'] == false),
        isTrue,
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
      expect(find.byKey(const ValueKey('tv-offline')), findsOneWidget);
      // Plain words: the address and port stay out of what it says.
      expect(find.textContaining('did not answer'), findsOneWidget);
      expect(find.textContaining('192.168.1.60'), findsNothing);
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
      engine.eventsOut.add({
        'event': 'device.pollFailed',
        'device': tvId,
        'error': 'connection refused',
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('onnection refused'), findsWidgets);
    });

    testWidgets('a stateChanged event updates the header', (tester) async {
      await pumpTv(tester, engine);
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
        'Sony LIV',
      );
      expect(volumeShows('12'), isTrue);
    });

    testWidgets('the header stays on every tab', (tester) async {
      await pumpTv(tester, engine);
      for (final tab in ['Apps', 'Settings', 'Files', 'Console']) {
        await openTvTab(tester, tab);
        expect(find.byKey(const ValueKey('tv-volume')), findsOneWidget);
        expect(find.byKey(const ValueKey('tv-header-power')), findsOneWidget);
      }
    });
  });

  group('the remote', () {
    testWidgets('keys go by catalog name, or by keycode when it has none', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await tester.tap(find.byKey(const ValueKey('key-23')));
      await tester.pumpAndSettle();
      for (final code in [244, 245]) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('key-$code')),
          200,
          scrollable: remoteScroll(),
        );
        await tester.tap(find.byKey(ValueKey('key-$code')));
        await tester.pumpAndSettle();
      }
      expect(argsOf(engine, 'tv.key'), [
        {'id': tvId, 'key': 'ok'},
        {'id': tvId, 'key': 'hdmi_2'},
        {'id': tvId, 'keycode': 245},
      ]);
    });

    testWidgets('the top row, the D-pad, then back, menu, info, volume and '
        'media come first', (tester) async {
      await pumpTv(tester, engine);
      double top(int code) =>
          tester.getTopLeft(find.byKey(ValueKey('key-$code'))).dy;
      double left(int code) =>
          tester.getTopLeft(find.byKey(ValueKey('key-$code'))).dx;
      final topRow = [26, 178, 3, 219];
      for (final code in topRow.skip(1)) {
        expect(top(code), top(26));
      }
      expect([
        for (final c in topRow) left(c),
      ], orderedEquals([for (final c in topRow) left(c)]..sort()));
      expect(top(19), greaterThan(top(26)));
      expect(top(23), greaterThan(top(19)));
      expect(top(20), greaterThan(top(23)));
      for (final (row, codes) in [
        (0, [4, 82, 165]),
        (1, [25, 164, 24]),
        (2, [88, 85, 87]),
      ]) {
        for (final code in codes) {
          expect(top(code), top(codes.first), reason: 'row $row');
        }
        expect(top(codes.first), greaterThan(top(20)));
      }
      expect(top(25), greaterThan(top(4)));
      expect(top(88), greaterThan(top(25)));
    });

    testWidgets('every part of the layout is there', (tester) async {
      await pumpTv(tester, engine);
      for (final code in [
        26,
        178,
        3,
        219,
        19,
        20,
        21,
        22,
        23,
        4,
        82,
        165,
        25,
        164,
        24,
        88,
        85,
        87,
        8,
        16,
        7,
        67,
        66,
        183,
        184,
        185,
        186,
        166,
        167,
        229,
        243,
        246,
        172,
        175,
        176,
        223,
        224,
        84,
        187,
        89,
        86,
        90,
      ]) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('key-$code')),
          200,
          scrollable: remoteScroll(),
        );
        expect(find.byKey(ValueKey('key-$code')), findsOneWidget);
      }
    });

    testWidgets('a long press on a key sends a long press', (tester) async {
      await pumpTv(tester, engine);
      await tester.longPress(find.byKey(const ValueKey('key-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('key-19')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.key'), [
        {'id': tvId, 'key': 'home', 'longPress': true},
        {'id': tvId, 'key': 'up'},
      ]);
    });

    testWidgets('the text box types on the TV and clears', (tester) async {
      await pumpTv(tester, engine);
      final box = find.byKey(const ValueKey('tv-text'));
      await tester.scrollUntilVisible(box, 200, scrollable: remoteScroll());
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
      final zoom = find.byKey(const ValueKey('catalog-zoom'));
      await tester.scrollUntilVisible(zoom, 200, scrollable: remoteScroll());
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
      await tester.tap(find.byKey(const ValueKey('key-23')));
      await tester.pumpAndSettle();
      expect(find.text('The TV is off.'), findsOneWidget);
    });

    testWidgets('meets the tap target, label and contrast guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpTv(tester, engine);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });
}
