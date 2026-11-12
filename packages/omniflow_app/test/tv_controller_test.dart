import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/tv/tv_controller.dart';

import 'fake_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a slow TV gets one state read at a time', () async {
    final engine = FakeEngine()..delay = const Duration(milliseconds: 50);
    engine.answers['tv.state'] = {'ok': true, 'power': 'on', 'volume': 10};
    final tv = TvController(
      client: engine,
      id: 'tv',
      poll: const Duration(hours: 1),
    );
    addTearDown(tv.dispose);
    await Future.wait([tv.refresh(), tv.refresh(), tv.refresh()]);
    expect(engine.callsOf('tv.state'), hasLength(1));
  });

  test('a read that started before a volume change cannot undo it', () async {
    final engine = FakeEngine()..delay = const Duration(milliseconds: 40);
    engine.answers['tv.state'] = {'ok': true, 'power': 'on', 'volume': 10};
    engine.answers['tv.volume'] = {'ok': true, 'volume': 31};
    final tv = TvController(
      client: engine,
      id: 'tv',
      poll: const Duration(hours: 1),
    );
    addTearDown(tv.dispose);
    final read = tv.refresh();
    await tv.setVolume(30);
    await read;
    expect(tv.state.volume, 31, reason: 'what the TV reported');
  });
}
