import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omniflow_app/ui/add/add_page.dart';
import 'package:omniflow_app/api/engine_calls.dart' show Json;
import 'package:omniflow_app/api/plain_error.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/fun/your_home_page.dart';
import 'package:omniflow_app/ui/settings/away_lighting_page.dart';
import 'package:omniflow_app/ui/settings/inspector.dart';
import 'package:omniflow_app/ui/settings/places_page.dart';
import 'package:omniflow_app/ui/settings/rooms_page.dart';
import 'package:omniflow_app/ui/settings/variables_page.dart';
import 'package:omniflow_app/ui/tags/tags_page.dart';

import 'fake_engine.dart';
import 'fun_test.dart' show statsReply;
import 'screen_harness.dart';

void main() {
  testWidgets('the stopped-hub banner and its Start reach a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final engine = FakeEngine()
      ..answers['engine.status'] = {'ok': true, 'hubRunning': false};
    await pumpApp(tester, engine);
    expect(find.byKey(const ValueKey('hub-stopped')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Automations are stopped')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Start'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('at large text the floating button is just its icon, still '
      'named', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(
      tester,
      FakeEngine()
        ..answers['automation.list'] = {
          'ok': true,
          'automations': [
            {
              'id': 'evening',
              'name': 'Evening',
              'source': 'rule',
              'enabled': true,
              'approved': true,
              'sentence': <Object?>[],
            },
          ],
        },
    );
    await openTab(tester, 'Automations');
    final fab = find.byKey(const ValueKey('new-rule'));
    expect(fab, findsOneWidget);
    expect(find.descendant(of: fab, matching: find.text('New')), findsNothing);
    expect(tester.getSize(fab).width, lessThanOrEqualTo(56));
    expect(find.byTooltip('New'), findsOneWidget);
  });

  testWidgets('on a wide screen the button sits in the rail, over nothing', (
    tester,
  ) async {
    await pumpApp(
      tester,
      FakeEngine()
        ..answers['automation.list'] = {
          'ok': true,
          'automations': [
            {
              'id': 'evening',
              'name': 'Evening',
              'source': 'rule',
              'enabled': true,
              'approved': true,
              'sentence': <Object?>[],
            },
          ],
        },
    );
    tester.view.physicalSize = const Size(3000, 1300);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Automations').last);
    await tester.pumpAndSettle();
    final rail = find.byKey(const ValueKey('shell-rail'));
    expect(
      find.descendant(
        of: rail,
        matching: find.byKey(const ValueKey('new-rule')),
      ),
      findsOneWidget,
    );
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('Developer, Engine reads again after a change made elsewhere', (
    tester,
  ) async {
    final engine = FakeEngine()
      ..answers['engine.status'] = {
        'ok': true,
        'hubRunning': true,
        'flows': ['a', 'b'],
      };
    await pumpApp(tester, engine);
    await openDeveloper(tester);
    await tester.tap(find.text('Engine'));
    await tester.pumpAndSettle();
    expect(rowValue(tester, 'Automations loaded'), '2');
    engine.answers['engine.status'] = {
      'ok': true,
      'hubRunning': true,
      'flows': ['a', 'b', 'c'],
    };
    engine.eventsOut.add({'event': 'automation.changed', 'id': 'c'});
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(rowValue(tester, 'Automations loaded'), '3');
    engine.answers['engine.status'] = {
      'ok': true,
      'hubRunning': true,
      'flows': ['a'],
    };
    engine.eventsOut.add({'event': 'device.changed'});
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(rowValue(tester, 'Automations loaded'), '1');
  });

  group('plain errors', () {
    test('a full stop is never added after a question or a stop', () {
      expect(
        plainError(
          'device_error',
          'Bed lamp did not answer. Is it switched on?',
        ),
        'Bed lamp did not answer. Is it switched on?',
      );
      expect(
        plainError('timeout', null),
        'The device did not answer. Check that it is on and on this Wi-Fi.',
      );
      expect(plainError('device_error', 'it said no'), 'It said no.');
    });
  });

  group('Settings pages', () {
    testWidgets('Places and people opens a page of that name', (tester) async {
      await pumpScreen(tester, FakeEngine(), const PlacesPage());
      expect(find.text('Places and people'), findsWidgets);
    });

    testWidgets('Variables names its Add in words, with no lone +', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        FakeEngine()
          ..answers['var.list'] = {
            'ok': true,
            'variables': {'WifiSsid': 'Home'},
          },
        const VariablesPage(),
      );
      final empty = tester.widget<OmniEmptyState>(
        find.byKey(const ValueKey('vars-empty')),
      );
      expect(empty.message, isNot(contains('+')));
      expect(empty.message, contains('plus at the top'));
      expect(empty.action, isNull);
    });

    testWidgets('Rooms adds from the header +, with no bottom bar', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        FakeEngine()..answers['room.list'] = {'ok': true, 'rooms': const []},
        const RoomsPage(),
      );
      expect(find.byType(OmniActionBar), findsNothing);
      expect(find.byKey(const ValueKey('rooms-empty')), findsOneWidget);
      expect(find.byType(OmniButton), findsNothing);
      expect(find.byTooltip('Add a room'), findsOneWidget);
    });

    testWidgets('NFC tags has one Add, the header +', (tester) async {
      await pumpScreen(tester, FakeEngine(), const TagsPage());
      expect(find.byKey(const ValueKey('tags-empty')), findsOneWidget);
      expect(find.byType(OmniButton), findsNothing);
      expect(find.byKey(const ValueKey('tags-add')), findsOneWidget);
    });

    testWidgets('Packets with nothing yet uses the shared empty state', (
      tester,
    ) async {
      await pumpScreen(tester, FakeEngine(), const Scaffold(body: Inspector()));
      expect(find.byKey(const ValueKey('packets-empty')), findsOneWidget);
      expect(find.text('No packets yet'), findsOneWidget);
      expect(find.textContaining('...'), findsNothing);
    });

    testWidgets('Away lighting: the switch row has its icon box', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        FakeEngine()
          ..devices = const []
          ..answers['awaylight.get'] = {
            'ok': true,
            'enabled': false,
            'lights': const <Object?>[],
            'away': false,
            'running': false,
          },
        const AwayLightingPage(),
      );
      expect(
        tester
            .widget<OmniListRow>(find.byKey(const ValueKey('away-enabled')))
            .icon,
        isNotNull,
      );
      expect(
        tester
            .widget<OmniEmptyState>(
              find.byKey(const ValueKey('away-lights-empty')),
            )
            .message,
        isNotNull,
      );
    });

    testWidgets('a long subtitle wraps at large text instead of cutting off', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpScreen(
        tester,
        FakeEngine(),
        const Scaffold(
          body: OmniListRow(
            key: ValueKey('row'),
            title: 'Variables',
            subtitle: 'Values automations set, to see or clear',
          ),
        ),
        size: const Size(1080, 1920),
      );
      final text = tester.widget<Text>(
        find.text('Values automations set, to see or clear'),
      );
      expect(text.maxLines, greaterThan(1));
    });

    testWidgets('each achievement is read out on its own', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(
        tester,
        FakeEngine()..answers['home.stats'] = statsReply(),
        const YourHomePage(),
      );
      await tester.tap(find.text('Achievements'));
      await tester.pumpAndSettle();
      final node = tester.getSemantics(
        find.byKey(const ValueKey('achievement-runs_100')),
      );
      expect(node.label, startsWith('100 runs'));
      expect(node.label, isNot(contains('First automation')));
      handle.dispose();
    });
  });

  group('Add', () {
    Json group(String driver, String category, List<String> hosts) => {
      'driver': driver,
      'name': driver,
      'category': category,
      'candidates': [
        for (final h in hosts)
          {'driver': driver, 'host': h, 'name': 'Thing $h'},
      ],
    };

    testWidgets('the by-hand kinds keep their order once the look ends, and '
        'found things keep theirs on a second look', (tester) async {
      final engine = FakeEngine()
        ..delay = const Duration(milliseconds: 200)
        ..answers['driver.list'] = {
          'ok': true,
          'drivers': [
            {'id': 'wiz', 'name': 'WiZ', 'category': 'lighting'},
            {'id': 'plug', 'name': 'Plug', 'category': 'power'},
          ],
        }
        ..answers['thing.add'] = {
          'ok': true,
          'groups': [
            group('wiz', 'lighting', ['10.0.0.1']),
            group('plug', 'power', ['10.0.0.2']),
          ],
          'manual': const [],
        };
      await pumpScreen(tester, engine, const AddPage(), settle: false);
      String? keyOf(Widget w) =>
          (w is OmniListRow || w is AddKindTile) && w.key is ValueKey<String>
          ? (w.key! as ValueKey<String>).value
          : null;
      bool isKind(String? k) =>
          k != null &&
          (k.startsWith('manual-kind-') || k == 'add-another-phone');
      List<String> kinds() => [
        for (final e in find.byWidgetPredicate((_) => true).evaluate())
          if (keyOf(e.widget) case final k? when isKind(k)) k,
      ];
      expect(kinds(), isEmpty, reason: 'the kinds wait for the drivers');
      await tester.pump(const Duration(milliseconds: 250));
      final during = kinds();
      expect(during, [
        'manual-kind-lights',
        'manual-kind-plugs',
        'add-another-phone',
      ]);
      await tester.pumpAndSettle();
      expect(kinds(), during);
      expect(find.text('Thing 10.0.0.1'), findsOneWidget);
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Thing 10.0.0.1'), lessThan(top('Thing 10.0.0.2')));

      engine.answers['thing.add'] = {
        'ok': true,
        'groups': [
          group('plug', 'power', ['10.0.0.2']),
          group('wiz', 'lighting', ['10.0.0.1']),
        ],
        'manual': const [],
      };
      await tester.tap(find.byKey(const ValueKey('add-rescan')));
      await tester.pumpAndSettle();
      expect(top('Thing 10.0.0.1'), lessThan(top('Thing 10.0.0.2')));
    });
  });
}

/// The value shown on the list row titled [title].
String? rowValue(WidgetTester tester, String title) => tester
    .widget<OmniListRow>(
      find.ancestor(of: find.text(title), matching: find.byType(OmniListRow)),
    )
    .value;
