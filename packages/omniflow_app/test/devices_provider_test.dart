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
      overrides: [engineClientProvider.overrideWithValue(engine)],
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
}
