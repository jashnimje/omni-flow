import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/rules/things.dart';
import 'package:omniflow_app/state/clock.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/design/design.dart';
import 'package:omniflow_app/ui/theme.dart';

import 'fake_engine.dart';

void main() {
  group('devices from anywhere', () {
    test('a thing added from the CLI shows without a restart', () async {
      final engine = FakeEngine();
      final container = ProviderContainer(
        overrides: [engineConnectionProvider.overrideWithValue(engine)],
      );
      addTearDown(container.dispose);
      final changes = container.listen(deviceChangesProvider, (_, _) {});
      expect(await container.read(devicesProvider.future), hasLength(1));

      engine.devices = [
        FakeEngine.lamp(),
        {...FakeEngine.lamp(), 'id': 'hall_lamp', 'name': 'Hall lamp'},
      ];
      // Several at once (a move adds the thing again) read the list once.
      for (var i = 0; i < 3; i++) {
        engine.eventsOut.add({
          'event': deviceChangedEvent,
          'command': 'device.add',
          'id': 'hall_lamp',
        });
      }
      await Future<void>.delayed(
        DevicesNotifier.settle + const Duration(milliseconds: 50),
      );
      expect(container.read(devicesProvider).value, hasLength(2));
      expect(engine.callsOf('device.list'), hasLength(2));
      expect(changes.read(), 1);
    });

    test('a person is read again for the house in view, not merged from '
        'the stored state', () async {
      final engine = FakeEngine();
      engine.devices = [
        {
          'id': 'jade',
          'name': 'Jade',
          'driver': 'person',
          'state': {'home': null, 'presence': 'not_set_up'},
        },
      ];
      final container = ProviderContainer(
        overrides: [engineConnectionProvider.overrideWithValue(engine)],
      );
      addTearDown(container.dispose);
      await container.read(devicesProvider.future);
      engine.eventsOut.add({
        'event': 'device.stateChanged',
        'device': {
          'id': 'jade',
          'driver': 'person',
          'state': {'home': true},
        },
      });
      await Future<void>.delayed(
        DevicesNotifier.settle + const Duration(milliseconds: 50),
      );
      final person = container.read(devicesProvider).value!.single;
      expect((person['state'] as Map)['presence'], 'not_set_up');
      expect((person['state'] as Map)['home'], isNull);
      expect(engine.callsOf('device.list'), hasLength(2));
    });
  });

  group('the phone clock', () {
    test('a 12-hour phone asks for 12-hour words, only where words hold a '
        'time', () async {
      final engine = FakeEngine();
      final container = ProviderContainer(
        overrides: [
          engineConnectionProvider.overrideWithValue(engine),
          hour12Provider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);
      final client = container.read(engineClientProvider);
      await client.call('rule.words', {'rule': const {}});
      await client.call('device.invoke', {'id': 'desk_lamp'});
      expect(engine.callsOf('rule.words').single.$2['hour12'], isTrue);
      expect(engine.callsOf('device.invoke').single.$2, {'id': 'desk_lamp'});
    });

    test(
      'a 24-hour phone sends nothing, and the engine words 24 hours',
      () async {
        final engine = FakeEngine();
        final container = ProviderContainer(
          overrides: [
            engineConnectionProvider.overrideWithValue(engine),
            hour12Provider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);
        await container.read(engineClientProvider).call('automation.list');
        expect(
          engine.callsOf('automation.list').single.$2,
          isNot(contains('hour12')),
        );
        expect(timeOfDayText(true, DateTime(2026, 1, 1, 19, 30)), '7:30 PM');
        expect(
          nextRunTextFor(
            false,
            DateTime(2026, 1, 1, 19, 30),
            now: DateTime(2026, 1, 1, 8),
          ),
          'today 19:30',
        );
      },
    );
  });

  test('a TV power label drops its list of values', () {
    final tv = Thing({
      'id': 'tv',
      'name': 'Living room TV',
      'driver': 'android_tv_adb',
      'capabilities': [
        {
          'id': 'power_state',
          'type': 'sensor',
          'label': 'Power (on, asleep or off)',
          'values': ['on', 'asleep', 'off'],
        },
      ],
    });
    expect(tv.labelOf('power_state'), 'Power');
    expect(tv.valuesOf('power_state'), ['on', 'asleep', 'off']);
  });

  testWidgets('a message floats above the Save of a form at 360x640', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.reset);
    var saved = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: omniTheme(),
        scaffoldMessengerKey: messengerKey,
        home: FormPage(
          title: 'New scene',
          onCommit: () => saved++,
          children: (_) => const [Text('Name')],
        ),
      ),
    );
    showMessage(
      'Bed lamp did not answer. Is it switched on?',
      action: 'Retry',
      onAction: () {},
    );
    await tester.pumpAndSettle();
    final snack = tester.getRect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );
    final save = find.byKey(const ValueKey('template-primary'));
    expect(snack.bottom, lessThanOrEqualTo(tester.getRect(save).top));
    await tester.tap(save);
    await tester.pump();
    expect(saved, 1);
    expect(find.text('Retry'), findsOneWidget);
    messengerKey.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
  });
}
