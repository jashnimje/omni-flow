import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_calls.dart';
import 'package:omniflow_app/ui/devices/host_key_sheet.dart';
import 'package:omniflow_app/ui/settings/variables_page.dart';

import 'automations_fixtures.dart' show tapKey;
import 'fake_engine.dart';
import 'screen_harness.dart';

void main() {
  late FakeEngine engine;
  setUp(() => engine = FakeEngine());

  group('variables', () {
    setUp(() {
      engine.answers['var.list'] = {
        'ok': true,
        'variables': {
          'Mood': 'cosy',
          'Away': true,
          'HomeWifiConnected': true,
          'keep_hold_relay_then_0': 1,
          '_scheduled_x': '2026-11-09',
        },
      };
    });

    testWidgets('shows the ones automations set, apart from OmniFlow\'s', (
      tester,
    ) async {
      await pumpScreen(tester, engine, const VariablesPage());
      expect(find.text('\$Mood'), findsOneWidget);
      expect(find.text('cosy'), findsOneWidget);
      expect(find.text('\$Away'), findsOneWidget);
      expect(find.text('Set by OmniFlow'), findsOneWidget);
      expect(find.text('\$HomeWifiConnected'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('var-clear-HomeWifiConnected')),
        findsNothing,
      );
      expect(find.textContaining('keep_'), findsNothing);
      expect(find.textContaining('_scheduled'), findsNothing);
    });

    testWidgets('a value is changed, and one is cleared', (tester) async {
      await pumpScreen(tester, engine, const VariablesPage());
      await tapKey(tester, 'var-Mood');
      await tester.enterText(
        find.byKey(const ValueKey('var-edit-value')),
        'off',
      );
      await tester.pump();
      await tapKey(tester, 'form-done');
      expect(engine.callsOf('var.set').single.$2, {
        'name': 'Mood',
        'value': false,
      });
      await tapKey(tester, 'var-clear-Away');
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(engine.callsOf('var.remove').single.$2, {'name': 'Away'});
    });
  });

  testWidgets('a changed host key is shown and trusted on purpose', (
    tester,
  ) async {
    engine.answerers['device.hostkey'] = (args) => {
      'ok': true,
      'pinned': 'ssh-ed25519 SHA256:old',
      'offered': 'ssh-ed25519 SHA256:new',
      'matches': args['action'] == 'accept' ? true : false,
    };
    final mac = DeviceView({
      'id': 'mac_mini',
      'name': 'Mac mini',
      'host': '192.168.1.20',
      'capabilities': [
        {'id': 'shell', 'type': 'exec'},
      ],
    });
    expect(usesSsh(mac), isTrue);
    await pumpScreen(
      tester,
      engine,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open'),
            onPressed: () => showHostKeySheet(context, mac),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tapKey(tester, 'open');
    expect(find.byKey(const ValueKey('hostkey-changed')), findsOneWidget);
    await tapKey(tester, 'hostkey-accept');
    await tester.tap(find.text('Trust it'));
    await tester.pumpAndSettle();
    final accept = engine
        .callsOf('device.hostkey')
        .where((c) => c.$2['action'] == 'accept')
        .single;
    expect(accept.$2['fingerprint'], 'ssh-ed25519 SHA256:new');
  });
}
