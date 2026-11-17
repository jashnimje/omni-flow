import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/diagram_calls.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/api/tv_calls.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/automations/automations.dart';
import 'package:omniflow_app/ui/automations/diagram/diagram.dart';
import 'package:omniflow_app/ui/automations/test_run.dart' show RunNodeRows;
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/devices/device_page.dart';
import 'package:omniflow_app/ui/home/energy_card.dart';
import 'package:omniflow_app/ui/settings/alerts_page.dart';
import 'package:omniflow_app/ui/tv/tv_frame.dart';

import 'automations_fixtures.dart';
import 'diagram_fixtures.dart';
import 'fake_engine.dart';
import 'screen_harness.dart';
import 'tv_fixtures.dart';

/// The audit's fixes: plain errors, the diagram editor's locks and tap
/// areas, the test run's words and icons, the layout bugs, and the TV and
/// energy reads that ran too often.

Future<void> _openEditor(WidgetTester tester, FakeEngine engine) async {
  engine.answers[DiagramCalls.diagram] = everyPartDiagram();
  await pumpScreen(
    tester,
    engine,
    RuleEditorPage(initial: everyPartSpec()),
    overrides: [
      ruleViewStoreProvider.overrideWithValue(
        MemoryRuleViewStore(RuleView.diagram),
      ),
    ],
  );
}

Future<void> _refetch(WidgetTester tester) async {
  await tester.pump(diagramRefetchDelay + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Map<String, Object?> _drawnSpec(FakeEngine engine) => Map<String, Object?>.from(
  engine.callsOf(DiagramCalls.diagram).last.$2['spec'] as Map,
);

Finder _pluses() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('diagram-plus-'),
);

Future<void> _longPressAndPick(
  WidgetTester tester,
  String node,
  String choice,
) async {
  await tester.longPress(find.byKey(ValueKey('diagram-node-$node')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('diagram-$choice')));
}

void main() {
  group('plain words', () {
    test('an address, port and retry count become what they mean', () {
      final w = plainWords(
        'Audit scene ran, but Desk lamp on failed: no reply from '
        '10.0.2.2:38899 after 3 attempts',
      );
      expect(
        w.text,
        'Audit scene ran, but Desk lamp on failed: it did not answer. '
        'Check that it is on and on this Wi-Fi.',
      );
      expect(w.details, contains('10.0.2.2:38899'));
    });

    test('a message that is all transport detail reads as one sentence', () {
      final w = plainWords('No reply from 10.0.2.2:38899 after 3 attempts.');
      expect(w.text, didNotAnswer);
      expect(w.text, isNot(contains('10.0.2.2')));
    });

    test('rule paths go, times and plain text stay', () {
      expect(plainWords('then[2].do: Pick a device').text, 'Pick a device');
      expect(
        plainWords('Runs at 18:30 on weekdays').text,
        'Runs at 18:30 on weekdays',
      );
      expect(plainWords('Runs at 18:30 on weekdays').details, isNull);
      expect(
        plainWords('No reply from desk_lamp').text,
        'No reply from desk_lamp',
      );
    });

    test('the same sentence twice reads once', () {
      expect(
        plainWords(
          'Could not reach 192.168.1.4:80.\nCould not reach 192.168.1.4:80.',
        ).text,
        didNotAnswer,
      );
    });

    testWidgets('a snackbar keeps the detail under Details, and the same '
        'message shows once', (tester) async {
      await pumpScreen(tester, FakeEngine(), const Scaffold(body: SizedBox()));
      showMessage('Desk lamp failed: no reply from 10.0.2.2:38899');
      showMessage('Desk lamp failed: no reply from 10.0.2.2:38899');
      await tester.pumpAndSettle();
      expect(find.textContaining('10.0.2.2'), findsNothing);
      expect(
        find.textContaining('Desk lamp failed: it did not answer'),
        findsOneWidget,
      );
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('error-details')), findsOneWidget);
      expect(find.textContaining('10.0.2.2:38899'), findsOneWidget);
      // The second call was the same message: nothing more comes.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.textContaining('did not answer'), findsNothing);
    });

    testWidgets('a refused save says why once, without the rule path', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['automation.save'] = {
          'ok': false,
          'error': {
            'type': 'invalid',
            'message': 'The rule is not valid',
            'issues': [
              {'path': 'then[2].do', 'message': 'needs a device'},
            ],
          },
        };
      late WidgetRef widgetRef;
      await pumpScreen(
        tester,
        engine,
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      final reply = await widgetRef.read(engineApiProvider).saveRule(const {
        'when': <Object?>[],
        'then': <Object?>[],
      }, trusted: true);
      await tester.pumpAndSettle();
      expect(reply.failure!.issues.single.path, 'then[2].do');
      expect(find.text('The rule is not valid.'), findsOneWidget);
      expect(find.textContaining('then[2]'), findsNothing);
    });

    test('an error read for a screen has no address either', () {
      expect(
        errorMessage({
          'ok': false,
          'error': {
            'type': 'timeout',
            'message': 'no reply from 10.0.2.2:38899 after 3 attempts',
          },
        }),
        didNotAnswer,
      );
    });
  });

  group('diagram editor', () {
    late FakeEngine engine;

    setUp(() => engine = automationsEngine());

    testWidgets('a failed refresh keeps the editor locked, with Retry', (
      tester,
    ) async {
      await _openEditor(tester, engine);
      expect(_pluses(), findsWidgets);
      engine.answers[DiagramCalls.diagram] = {
        'ok': false,
        'error': {'type': 'unreachable', 'message': 'gone'},
      };
      await _longPressAndPick(tester, '/then/0', 'copy');
      await _refetch(tester);
      expect(
        find.byKey(const ValueKey('diagram-refresh-failed')),
        findsOneWidget,
      );
      // The old diagram stays on screen, but nothing on it edits.
      expect(
        find.byKey(const ValueKey('diagram-node-/then/0')),
        findsOneWidget,
      );
      expect(_pluses(), findsNothing);
      final node = tester.widget<DiagramNodeCard>(
        find.byKey(const ValueKey('diagram-node-/then/0')),
      );
      expect(node.onTap, isNull);
      expect(node.onLongPress, isNull);

      engine.answers[DiagramCalls.diagram] = everyPartDiagram();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('diagram-refresh-failed')),
        findsNothing,
      );
      expect(_pluses(), findsWidgets);
      expect(_drawnSpec(engine)['then'] as List, hasLength(9));
    });

    testWidgets('a diagram of the rule before an edit never unlocks it', (
      tester,
    ) async {
      await _openEditor(tester, engine);
      final draft = tester.widget<DiagramEditor>(find.byType(DiagramEditor));
      engine.delay = const Duration(seconds: 1);
      void edit() {
        draft.draft.spec.then.add(draft.draft.spec.then.first);
        draft.draft.changed();
      }

      // The refresh for this edit goes out at 300 ms and answers at 1300.
      edit();
      await tester.pump(const Duration(milliseconds: 1100));
      // A second edit while it is out: its answer, at 1300, is of the
      // rule before this edit.
      edit();
      await tester.pump(const Duration(milliseconds: 250));
      expect(engine.callsOf(DiagramCalls.diagram), hasLength(2));
      expect(_pluses(), findsNothing);
      // The refresh for the second edit unlocks it.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(engine.callsOf(DiagramCalls.diagram), hasLength(3));
      expect(_pluses(), findsWidgets);
    });

    testWidgets('an edit between a remove and its Undo takes the Undo away', (
      tester,
    ) async {
      await _openEditor(tester, engine);
      await _longPressAndPick(tester, '/then/0', 'remove');
      await _refetch(tester);
      expect(find.text('Undo'), findsOneWidget);
      await _longPressAndPick(tester, '/then/0', 'copy');
      await _refetch(tester);
      expect(find.text('Undo'), findsNothing);
      // Copy of what is now first (the If), and the lamp step stays gone.
      final then = _drawnSpec(engine)['then'] as List;
      expect(then, hasLength(8));
      expect((then[0] as Map).containsKey('if'), isTrue);
      expect(then[1], then[0]);
    });

    testWidgets('each "+" is at least 48 dp to tap when the diagram is '
        'zoomed out to fit, and adds where it was tapped', (tester) async {
      await _openEditor(tester, engine);
      final viewer = tester.state<DiagramViewerState>(
        find.byType(DiagramViewer),
      );
      viewer.fitAll();
      await tester.pumpAndSettle();
      expect(viewer.scale, lessThan(0.9));
      for (final plus in tester.widgetList(_pluses())) {
        final rect = tester.getRect(find.byWidget(plus));
        expect(rect.width, greaterThanOrEqualTo(OmniSpace.target - 0.01));
        expect(rect.height, greaterThanOrEqualTo(OmniSpace.target - 0.01));
      }
      // The + between the notify on the If's no way and the merge: the
      // new step goes after the notify, not above it.
      final edges = everyPartDiagram()['edges'] as List;
      final i = edges.indexWhere(
        (e) => e['from'] == '/then/1/else/0' && e['to'] == '/then/1#merge',
      );
      await tester.tap(find.byKey(ValueKey('diagram-plus-$i')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-wait')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('form-done')));
      await _refetch(tester);
      final ifStep = (_drawnSpec(engine)['then'] as List)[1] as Map;
      expect(ifStep['else'], [
        {
          'notify': {'title': 'Lamp is off'},
        },
        {'wait': 3000},
      ]);
    });
  });

  group('test run', () {
    testWidgets('rows: the device step sends, the notify shows its words, '
        'and the wait says nothing borrowed', (tester) async {
      Map<String, Object?> result() => {
        'dryRun': true,
        'capabilityId': 'brightness',
        'params': {'value': 55},
      };
      final run = RunRecord.fromJson({
        'run': 'd1',
        'flow': 'audit_lamp',
        'outcome': 'completed',
        'startedAt': '2026-11-13T08:00:00Z',
        'dryRun': true,
        'nodes': [
          {
            'node': 'then_0',
            'type': 'device_capability',
            'output': {'result': result()},
          },
          {
            'node': 'then_1',
            'type': 'notify',
            'output': {
              'result': result(),
              'announced': {'type': 'notify', 'title': 'hello'},
            },
          },
          {
            'node': 'then_2',
            'type': 'delay',
            'output': {'result': result()},
          },
        ],
      });
      await pumpScreen(
        tester,
        FakeEngine(),
        Scaffold(body: RunNodeRows(run: run)),
      );
      expect(find.textContaining('would send brightness'), findsOneWidget);
      expect(find.text('would show "hello"'), findsOneWidget);
    });

    testWidgets('a run diagram shows each step its own icon, and what a '
        'check saw sits right of its yes line', (tester) async {
      final engine = automationsEngine();
      engine.answerers[DiagramCalls.diagram] = (_) => everyPartRun();
      final dry = RunRecord.fromJson({
        'run': 'd1',
        'flow': 'every_part',
        'outcome': 'completed',
        'startedAt': '2026-11-13T08:00:00Z',
        'dryRun': true,
        'nodes': const <Object?>[],
      });
      await pumpScreen(
        tester,
        engine,
        Scaffold(
          body: SingleChildScrollView(
            child: DryRunDiagram(run: dry, rule: everyPartSpec()),
          ),
        ),
      );
      IconData? iconOf(String id) => tester
          .widget<DiagramNodeCard>(find.byKey(ValueKey('diagram-node-$id')))
          .icon;
      // A notify and a wait have no device: a bell and a timer.
      expect(iconOf('/then/1/else/0'), OmniIcons.notifications);
      expect(iconOf('/then/1/then/0'), OmniIcons.wait);

      final seen = find.byKey(const ValueKey('diagram-seen-/onlyIf/0'));
      expect(seen, findsOneWidget);
      final node = tester.getRect(
        find.byKey(const ValueKey('diagram-node-/onlyIf/0')),
      );
      expect(tester.getRect(seen).left, greaterThan(node.center.dx));
    });
  });

  group('layout', () {
    testWidgets('the tab bar has no empty band above its icons', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: 156, bottom: 72);
      addTearDown(tester.view.resetPadding);
      await pumpApp(tester, FakeEngine());
      final bar = tester.widget<NavigationBar>(
        find.byKey(const ValueKey('shell-tabs')),
      );
      final size = tester.getSize(find.byKey(const ValueKey('shell-tabs')));
      // Its height plus the gesture bar, and nothing for the status bar.
      expect(size.height, bar.height! + 72 / tester.view.devicePixelRatio);
    });

    testWidgets('Alerts and modes has the standard side margins', (
      tester,
    ) async {
      await pumpScreen(tester, FakeEngine(), const AlertsPage());
      final row = tester.getRect(find.byKey(const ValueKey('alert-offline')));
      final screen = tester.getSize(find.byType(Scaffold).last);
      expect(row.left, OmniSpace.screenPadding.left);
      expect(screen.width - row.right, OmniSpace.screenPadding.right);
    });

    testWidgets('the Phone page shows its screen, and the torch is its own '
        'switch, not a power button', (tester) async {
      final engine = FakeEngine()
        ..devices = [
          {
            'id': 'pixel',
            'name': 'Pixel',
            'driver': 'phone',
            'online': true,
            'state': {'screen_on': true, 'battery': 80, 'charging': true},
            'capabilities': [
              {'id': 'shaken', 'type': 'event', 'label': 'The phone is shaken'},
              {
                'id': 'torch',
                'type': 'toggle',
                'label': 'Torch',
                'stateKey': 'torch',
              },
              {
                'id': 'screen_on',
                'type': 'sensor',
                'label': 'Screen on',
                'stateKey': 'screen_on',
              },
              {
                'id': 'battery',
                'type': 'sensor',
                'label': 'Battery',
                'stateKey': 'battery',
              },
            ],
          },
        ];
      await pumpScreen(tester, engine, const DevicePage(id: 'pixel'));
      expect(find.text('Screen on'), findsWidgets);
      expect(find.text('Battery 80%, charging'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-power-pixel')), findsNothing);
      expect(find.text('Readings'), findsOneWidget);
      expect(find.text('Torch'), findsOneWidget);
      // Its switches come before its events.
      expect(
        tester.getTopLeft(find.text('Torch')).dy,
        lessThan(tester.getTopLeft(find.text('The phone is shaken')).dy),
      );
    });
  });

  group('reads that ran too often', () {
    testWidgets('a TV frame decodes at the width it is drawn at, and the '
        'last frame leaves the cache', (tester) async {
      final png = await decodeFrame(_onePixelPng);
      final next = await decodeFrame(_onePixelPng);
      Widget at(Uint8List bytes) => Center(
        child: SizedBox(width: 200, height: 100, child: TvFrame(bytes)),
      );
      await tester.pumpWidget(at(png));
      final image = tester.widget<Image>(find.byType(Image));
      final resized = image.image as ResizeImage;
      expect(resized.width, (200 * tester.view.devicePixelRatio).round());
      await tester.runAsync(() async {
        await precacheImage(resized, tester.element(find.byType(Image)));
      });
      expect(
        PaintingBinding.instance.imageCache.containsKey(
          await resized.obtainKey(ImageConfiguration.empty),
        ),
        isTrue,
      );
      final oldKey = await resized.obtainKey(ImageConfiguration.empty);
      await tester.pumpWidget(at(next));
      expect(PaintingBinding.instance.imageCache.containsKey(oldKey), isFalse);
    });

    testWidgets('the Mouse tab stops reading the screen behind the lock '
        'screen and starts again in front', (tester) async {
      final engine = tvEngine()
        ..answers.addAll({
          TvPointerCalls.status: {
            'ok': true,
            'installed': false,
            'running': false,
          },
          TvCalls.screenshot: {
            'ok': false,
            'error': {'type': 'timeout', 'message': 'asleep'},
          },
        });
      await pumpTv(tester, engine);
      await tester.tap(find.byKey(const ValueKey('tv-remote-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mouse'));
      await tester.pumpAndSettle();
      int shots() => engine.callsOf(TvCalls.screenshot).length;
      await tester.pump(const Duration(seconds: 2));
      expect(shots(), greaterThan(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      final hidden = shots();
      await tester.pump(const Duration(seconds: 5));
      expect(shots(), hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(shots(), greaterThan(hidden));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('energy is read again on a timer, not on every state report', (
      tester,
    ) async {
      final engine = FakeEngine()
        ..answers['energy.summary'] = {'ok': true, 'devices': <Object?>[]};
      await pumpScreen(tester, engine, const Scaffold(body: SmartHomeCards()));
      final first = engine.callsOf('energy.summary').length;
      expect(first, 1);
      for (var i = 0; i < 5; i++) {
        engine.eventsOut.add({
          'event': 'device.stateChanged',
          'device': {
            ...FakeEngine.lamp(),
            'state': {'power': i.isEven},
          },
        });
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(engine.callsOf('energy.summary').length, first);
      await tester.pump(energyRefresh + const Duration(seconds: 1));
      expect(engine.callsOf('energy.summary').length, first + 1);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// A 1x1 PNG.
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
