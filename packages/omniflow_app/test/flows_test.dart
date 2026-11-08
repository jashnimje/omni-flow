import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/flows_screen.dart';

import 'fake_engine.dart';

void main() {
  late FakeEngine engine;

  final mac = {
    'id': 'mac',
    'name': 'Mac mini',
    'driver': 'macos_host',
    'host': '192.168.1.20',
    'settings': const <String, Object?>{},
    'state': const <String, Object?>{},
    'capabilities': [
      {
        'id': 'display_wake',
        'type': 'action',
        'label': 'Wake display',
        'highRisk': true,
        'params': {},
      },
    ],
  };

  setUp(() {
    engine = FakeEngine();
    engine.devices = [FakeEngine.lamp(), mac];
    engine.answers['flow.get'] = {
      'ok': true,
      'revision': 'a1b2c3',
      'approved': false,
      'flow': {
        'id': 'wake_mac',
        'name': 'Wake the Mac',
        'nodes': [
          {'id': 'trig', 'type': 'manual', 'label': 'Harmless', 'config': {}},
          {
            'id': 'wake',
            'type': 'device_capability',
            'label': 'Turn on the lamp',
            'config': {
              'deviceId': 'mac',
              'capabilityId': 'display_wake',
              'params': {},
            },
          },
          {
            'id': 'dim',
            'type': 'device_capability',
            'label': 'Dim',
            'config': {
              'deviceId': 'desk_lamp',
              'capabilityId': 'brightness',
              'params': {'value': 40, 'scene': '{{msg.value}}'},
            },
          },
          {
            'id': 'flip',
            'type': 'device_toggle',
            'label': 'Flip',
            'config': {'deviceId': 'desk_lamp', 'capabilityId': 'power'},
          },
          {
            'id': 'next',
            'type': 'run_flow',
            'label': 'Then',
            'config': {'flowId': 'evening'},
          },
        ],
      },
    };
  });

  Future<void> openFlows(WidgetTester tester) async {
    await pumpApp(tester, engine);
    await tester.tap(find.text('Flows'));
    await tester.pumpAndSettle();
  }

  testWidgets('a flow waiting for approval has no one-tap approve', (
    tester,
  ) async {
    await openFlows(tester);
    expect(find.text('Needs approval'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('the approval page shows what will run and sends the revision', (
    tester,
  ) async {
    await openFlows(tester);
    await tester.tap(find.byKey(const ValueKey('review-wake_mac')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('flow.get').single.$2, {'id': 'wake_mac'});
    expect(find.byKey(const ValueKey('effect-trig')), findsNothing);
    expect(find.text('Mac mini (mac)'), findsOneWidget);
    expect(
      find.text(
        'driver macos_host\ncapability display_wake\n'
        'runs a command on 192.168.1.20',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    expect(
      find.text(
        'driver philips_wiz_udp\ncapability brightness\nvalue = 40\n'
        'scene = {{msg.value}} (filled in when it runs)',
      ),
      findsOneWidget,
    );
    expect(find.text('driver philips_wiz_udp\ntoggle power'), findsOneWidget);
    expect(find.text('Run the flow evening'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approve')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('flow.approve'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('confirm')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('flow.approve').single.$2, {
      'id': 'wake_mac',
      'revision': 'a1b2c3',
    });
    expect(find.text('Review Wake the Mac'), findsNothing);
  });

  testWidgets('running a flow reports how it went', (tester) async {
    engine.answers['flow.run'] = {
      'ok': true,
      'runs': [
        {
          'outcome': 'failed',
          'nodes': [
            {'node': 'trig', 'type': 'manual'},
            {'node': 'lamp', 'type': 'device_capability', 'error': 'no reply'},
          ],
        },
      ],
    };
    await openFlows(tester);
    await tester.tap(find.byKey(const ValueKey('run-evening')));
    await tester.pump();
    expect(engine.callsOf('flow.run').single.$2, {'id': 'evening'});
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Evening desk: failed at lamp: no reply'), findsOneWidget);
  });

  testWidgets('the switch enables a flow and reloads the list', (tester) async {
    await openFlows(tester);
    final before = engine.callsOf('flow.list').length;
    await tester.tap(find.byKey(const ValueKey('enable-evening')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('flow.enable').single.$2, {
      'id': 'evening',
      'enabled': false,
    });
    expect(engine.callsOf('flow.list').length, before + 1);
  });

  testWidgets('a flow is removed after a confirm', (tester) async {
    await openFlows(tester);
    await tester.tap(find.byKey(const ValueKey('flow-menu-evening')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('flow.remove').single.$2, {'id': 'evening'});
  });

  testWidgets('runs finishing together reload the flow list once', (
    tester,
  ) async {
    await openFlows(tester);
    final before = engine.callsOf('flow.list').length;
    for (var i = 0; i < 5; i++) {
      engine.eventsOut.add({'event': 'run.finished', 'flow': 'evening'});
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(engine.callsOf('flow.list').length, before + 1);
  });

  testWidgets('the card view opens from the list', (tester) async {
    await openFlows(tester);
    await tester.tap(find.text('Evening desk'));
    await tester.pumpAndSettle();
    expect(find.text('WHEN'), findsOneWidget);
    expect(find.text('IF'), findsOneWidget);
    expect(find.text('THEN'), findsOneWidget);
    expect(find.text('Lamp warm'), findsOneWidget);
  });

  testWidgets('the card view shows an engine error', (tester) async {
    engine.answers['flow.cards'] = {
      'ok': false,
      'error': {'type': 'not_found', 'message': 'no flow evening'},
    };
    await openFlows(tester);
    await tester.tap(find.text('Evening desk'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cards-error'))).data,
      'no flow evening',
    );
    expect(find.textContaining('canvas'), findsNothing);
  });

  testWidgets('the card view shows a failed call instead of spinning', (
    tester,
  ) async {
    engine.throwOn.add('flow.cards');
    await openFlows(tester);
    await tester.tap(find.text('Evening desk'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('flow.cards broke'), findsOneWidget);
  });

  testWidgets('the card view asks the engine once across rebuilds', (
    tester,
  ) async {
    await openFlows(tester);
    await tester.tap(find.text('Evening desk'));
    await tester.pumpAndSettle();
    tester.element(find.byType(FlowCardsPage)).markNeedsBuild();
    await tester.pumpAndSettle();
    expect(engine.callsOf('flow.cards'), hasLength(1));
  });

  testWidgets('the flows screen meets the tap target and contrast guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openFlows(tester);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await tester.tap(find.text('Evening desk'));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });
}
