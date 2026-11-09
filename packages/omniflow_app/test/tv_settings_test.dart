import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine.dart';
import 'tv_fixtures.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = tvEngine());

  Future<void> expand(WidgetTester tester, String category) async {
    await tester.tap(find.text(category));
    await tester.pumpAndSettle();
  }

  group('curated settings', () {
    testWidgets('each category shows its settings with their descriptions', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      expect(argsOf(engine, 'tv.settings.catalog').single, {'id': tvId});
      expect(find.text('Display and sound'), findsOneWidget);
      expect(find.text('Network'), findsOneWidget);
      expect(find.text('Developer'), findsOneWidget);
      expect(find.textContaining('Backlight level'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('setting-value-screen_brightness')),
            )
            .data,
        '128',
      );
    });

    testWidgets('a slider writes the whole number it lands on', (tester) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      await tester.tap(
        find.byKey(const ValueKey('setting-slider-screen_brightness')),
      );
      await tester.pumpAndSettle();
      final put = argsOf(engine, 'tv.settings.put').single;
      expect(put['namespace'], 'system');
      expect(put['key'], 'screen_brightness');
      expect(put['value'], isA<int>());
      expect(find.byKey(const ValueKey('confirm')), findsNothing);
    });

    testWidgets('the value shown after a write is what the TV read back', (
      tester,
    ) async {
      engine.answers['tv.settings.put'] = {
        'ok': true,
        'namespace': 'system',
        'key': 'screen_brightness',
        'value': '77',
        'setting': {'key': 'screen_brightness', 'type': 'int', 'value': 77},
        'previous': '128',
        'raw': false,
      };
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      await tester.tap(
        find.byKey(const ValueKey('setting-slider-screen_brightness')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('setting-value-screen_brightness')),
            )
            .data,
        '77',
      );
    });

    testWidgets('a switch writes true or false', (tester) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      await expand(tester, 'Developer');
      await tester.tap(find.text('Stay awake'));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.settings.put').single, {
        'id': tvId,
        'namespace': 'global',
        'key': 'stay_on_while_plugged_in',
        'value': true,
      });
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
    });

    testWidgets('a refused write leaves the shown value as it was', (
      tester,
    ) async {
      engine.answers['tv.settings.put'] = {
        'ok': false,
        'error': {'type': 'invalid', 'message': 'value out of range'},
      };
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      await expand(tester, 'Developer');
      await tester.tap(find.text('Stay awake'));
      await tester.pumpAndSettle();
      expect(find.text('value out of range'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
    });

    testWidgets('a Private DNS change asks first, and Cancel writes nothing', (
      tester,
    ) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      await expand(tester, 'Network');
      await tester.tap(
        find.byKey(const ValueKey('setting-enum-private_dns_mode')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatic').last);
      await tester.pumpAndSettle();
      expect(find.text('Change Private DNS?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tv.settings.put'), isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('setting-text-private_dns_specifier')),
        'abc.dns.nextdns.io',
      );
      await tester.tap(
        find.byKey(const ValueKey('setting-save-private_dns_specifier')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Change Private DNS hostname?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.settings.put').single, {
        'id': tvId,
        'namespace': 'global',
        'key': 'private_dns_specifier',
        'value': 'abc.dns.nextdns.io',
      });
    });
  });

  group('all settings', () {
    Future<void> openAll(WidgetTester tester) async {
      await pumpTv(tester, engine);
      await openTvTab(tester, 'Settings');
      await tester.tap(find.byKey(const ValueKey('settings-all')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists a namespace with search', (tester) async {
      await openAll(tester);
      expect(argsOf(engine, 'tv.settings.list').first, {
        'id': tvId,
        'namespace': 'system',
      });
      expect(find.text('screen_off_timeout'), findsOneWidget);
      expect(find.text('volume_music'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('raw-search-system')),
        'screen',
      );
      await tester.pump();
      expect(find.text('volume_music'), findsNothing);
      await tester.tap(find.text('global'));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.settings.list').last['namespace'], 'global');
    });

    testWidgets('a raw edit is confirmed before it is written', (tester) async {
      await openAll(tester);
      await tester.tap(find.byKey(const ValueKey('raw-system.volume_music')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ask-text')), '25');
      await tester.tap(find.byKey(const ValueKey('ask-text-ok')));
      await tester.pumpAndSettle();
      expect(find.text('Write system/volume_music?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tv.settings.put'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('raw-system.volume_music')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ask-text')), '25');
      await tester.tap(find.byKey(const ValueKey('ask-text-ok')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.settings.put').single, {
        'id': tvId,
        'namespace': 'system',
        'key': 'volume_music',
        'value': '25',
      });
    });

    testWidgets('a new raw setting takes a valid key', (tester) async {
      await openAll(tester);
      await tester.tap(find.byKey(const ValueKey('raw-add-system')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ask-text')), 'bad key');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('ask-text-ok')))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byKey(const ValueKey('ask-text')), 'my_key');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ask-text-ok')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ask-text')), '1');
      await tester.tap(find.byKey(const ValueKey('ask-text-ok')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.settings.put').single['key'], 'my_key');
    });

    testWidgets('delete asks first, then deletes and reloads', (tester) async {
      await openAll(tester);
      await tester.tap(
        find.byKey(const ValueKey('raw-delete-system.volume_music')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete system/volume_music?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('tv.settings.delete'), isEmpty);

      final listed = engine.callsOf('tv.settings.list').length;
      await tester.tap(
        find.byKey(const ValueKey('raw-delete-system.volume_music')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm')));
      await tester.pumpAndSettle();
      expect(argsOf(engine, 'tv.settings.delete').single, {
        'id': tvId,
        'namespace': 'system',
        'key': 'volume_music',
      });
      expect(engine.callsOf('tv.settings.list').length, listed + 1);
    });
  });
}
