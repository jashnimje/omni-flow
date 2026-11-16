import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart';

import 'fake_engine.dart';

void main() {
  test('a state change heard while the list loads is not lost', () async {
    final engine = FakeEngine()..delay = const Duration(milliseconds: 50);
    engine.devices = [
      FakeEngine.lamp(state: const {'state': false}),
    ];
    final container = ProviderContainer(
      overrides: [engineConnectionProvider.overrideWithValue(engine)],
    );
    addTearDown(container.dispose);
    final loading = container.read(devicesProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    engine.eventsOut.add({
      'event': 'device.stateChanged',
      'device': {
        'id': 'desk_lamp',
        'state': {'state': true},
      },
    });
    final devices = await loading;
    expect((devices.single['state'] as Map)['state'], isTrue);
  });

  test('a failed reload keeps the list, and a failed first load is an '
      'error', () async {
    final engine = FakeEngine();
    final container = ProviderContainer(
      overrides: [engineConnectionProvider.overrideWithValue(engine)],
    );
    addTearDown(container.dispose);
    expect(await container.read(devicesProvider.future), hasLength(1));
    engine.answers['device.list'] = {
      'ok': false,
      'error': {'type': 'timeout', 'message': 'no answer'},
    };
    await container.read(devicesProvider.notifier).refresh();
    expect(container.read(devicesProvider).value, hasLength(1));

    final fresh = ProviderContainer(
      overrides: [engineConnectionProvider.overrideWithValue(engine)],
      // Riverpod retries a failed load by itself: this is the first try.
      retry: (_, _) => null,
    );
    addTearDown(fresh.dispose);
    await expectLater(
      fresh.read(devicesProvider.future),
      throwsA(isA<EngineReadFailed>()),
    );
  });
}
