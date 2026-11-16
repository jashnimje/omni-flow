import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/service/engine_host.dart';
import 'package:omniflow_app/service/engine_link.dart';

import 'fake_engine.dart';

void main() {
  test('packet captures reach the UI only while a session asks', () async {
    final sent = <Map<String, Object?>>[];
    final host = EngineHost(send: (m) => sent.add(LinkMessage.decode(m)!));
    final engine = FakeEngine();
    host.attach(engine);

    List<Object?> packets() => [
      for (final m in sent)
        if (m['t'] == LinkMessage.event &&
            (m['event'] as Map)['event'] == 'packet.captured')
          (m['event'] as Map)['n'],
    ];

    Future<void> ask(bool on, int id) => host.receive(
      LinkMessage.encode({
        't': LinkMessage.call,
        's': 'ui',
        'id': id,
        'command': EngineHost.packetsCommand,
        'args': {'on': on},
      }),
    );

    engine.eventsOut.add({'event': 'packet.captured', 'n': 1});
    engine.eventsOut.add({'event': 'device.state', 'n': 0});
    await Future<void>.delayed(Duration.zero);
    expect(packets(), isEmpty);
    expect(
      sent.where((m) => m['t'] == LinkMessage.event),
      hasLength(1),
      reason: 'other events still go through',
    );

    await ask(true, 1);
    engine.eventsOut.add({'event': 'packet.captured', 'n': 2});
    await Future<void>.delayed(Duration.zero);
    expect(packets(), [2]);

    await ask(false, 2);
    engine.eventsOut.add({'event': 'packet.captured', 'n': 3});
    await Future<void>.delayed(Duration.zero);
    expect(packets(), [2]);
    expect(
      engine.calls.where((c) => c.$1 == EngineHost.packetsCommand),
      isEmpty,
    );
  });
}
