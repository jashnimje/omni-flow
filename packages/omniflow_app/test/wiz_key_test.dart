import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/ui/add/guided_steps_page.dart';

import 'fake_engine.dart';
import 'screen_harness.dart';

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  late FakeEngine engine;

  setUp(() => engine = FakeEngine());

  testWidgets('a bulb that needs its WiZ home key says so on its page', (
    tester,
  ) async {
    engine.devices = [
      {
        ...FakeEngine.lamp(),
        'problem': {
          'message':
              'Desk lamp does not take commands until you add its WiZ '
              'home key',
          'keys': ['signingKey'],
          'action': 'setup',
        },
      },
    ];
    await pumpApp(tester, engine);
    await openDevicePage(tester, 'desk_lamp');
    expect(
      find.text(
        'Desk lamp does not take commands until you add its WiZ home key',
      ),
      findsOneWidget,
    );
    expect(find.text('Add it'), findsOneWidget);
  });

  testWidgets('the home key step offers the key another bulb already has', (
    tester,
  ) async {
    engine.answers['thing.next'] = {
      'ok': true,
      'next': {'step': 'done'},
    };
    final next = NextStep.fromJson({
      'step': 'secret',
      'keys': [
        {
          'step': 'secret',
          'key': 'signingKey',
          'label': 'WiZ home key',
          'sameAs': [
            {'id': 'kitchen', 'name': 'Kitchen'},
          ],
        },
      ],
      'remaining': ['secret:signingKey'],
    });
    expect(next.sameAs['signingKey']!.single, (id: 'kitchen', name: 'Kitchen'));
    await pumpScreen(
      tester,
      engine,
      GuidedStepsPage(id: 'desk_lamp', name: 'Desk lamp', first: next),
    );
    expect(find.text('Use the same WiZ home key as Kitchen'), findsOneWidget);
    await _tapKey(tester, 'setup-same-signingKey-kitchen');
    expect(engine.callsOf('secret.set').single.$2, {
      'deviceId': 'desk_lamp',
      'key': 'signingKey',
      'from': 'kitchen',
    });
    expect(find.byKey(const ValueKey('setup-done')), findsOneWidget);
  });
}
