import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// The engine for one test, kept open across the CLI's connect and close.
class _Shared implements EngineConnection {
  _Shared(this.engine);

  final OmniEngine engine;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) {
    calls.add((command, args));
    return engine.handle(command, args);
  }

  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) async =>
      engine.events;

  @override
  Future<void> close() async {}
}

class _Runner extends OmniCommandRunner {
  _Runner(this.shared, StringSink out)
    : super(out: out, input: const Stream.empty());

  final _Shared shared;

  @override
  Future<EngineConnection> connect({PacketTap? tap}) async => shared;
}

void main() {
  late Directory home;
  late OmniEngine engine;
  late _Shared shared;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_organize_cli');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    shared = _Shared(engine);
    await engine.handle('device.add', {
      'id': 'lamp',
      'driver': 'philips_wiz_udp',
      'host': '127.0.0.1',
    });
    await engine.handle('device.add', {'id': 'jade', 'driver': 'person'});
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<(int, Map<String, Object?>)> omni(List<String> args) async {
    final out = StringBuffer();
    final code = await _Runner(shared, out).run(args);
    return (code, jsonDecode(out.toString()) as Map<String, Object?>);
  }

  List<Object?> lastCall() => [shared.calls.last.$1, shared.calls.last.$2];

  test('omni room saves, lists, orders and removes rooms', () async {
    expect((await omni(['room', 'save', 'Study'])).$1, 0);
    await omni(['room', 'save', 'Kitchen', '--order', '0']);
    expect(lastCall(), [
      'room.save',
      {'name': 'Kitchen', 'order': 0},
    ]);
    final (_, listed) = await omni(['room', 'list']);
    expect(
      [for (final r in (listed['rooms'] as List).cast<Map>()) r['id']],
      ['kitchen', 'study'],
    );
    await omni(['room', 'order', 'study', 'kitchen']);
    expect(lastCall(), [
      'room.order',
      {
        'ids': ['study', 'kitchen'],
      },
    ]);
    final (code, removed) = await omni(['room', 'remove', 'kitchen']);
    expect((code, removed['removed']), (0, true));
  });

  test('omni device organize sends only what changes, and history reads '
      'back', () async {
    final (code, out) = await omni([
      'device',
      'organize',
      'lamp',
      '--room',
      'Study',
      '--favourite',
      '--order',
      '2',
    ]);
    expect(code, 0, reason: '$out');
    expect(lastCall(), [
      'device.organize',
      {'id': 'lamp', 'room': 'Study', 'favourite': true, 'order': 2},
    ]);
    await omni(['device', 'organize', 'lamp', '--no-room', '--no-favourite']);
    expect(lastCall(), [
      'device.organize',
      {'id': 'lamp', 'room': null, 'favourite': false},
    ]);
    final device =
        (await engine.handle('device.get', {'id': 'lamp'}))['device'] as Map;
    expect((device['favourite'], device['order']), (false, 2));

    await engine.devices.mergeState('lamp', {'dimming': 30});
    final (_, history) = await omni([
      'device',
      'history',
      'lamp',
      '--key',
      'dimming',
      '--limit',
      '5',
    ]);
    expect(lastCall(), [
      'device.history',
      {'id': 'lamp', 'key': 'dimming', 'limit': 5},
    ]);
    expect((history['entries'] as List).single, containsPair('value', 30));
  });

  test('omni scene saves trusted, lists, runs and removes', () async {
    final (code, saved) = await omni([
      'scene',
      'save',
      'Bright',
      '--do',
      'lamp.brightness=90',
      '--icon',
      'light_mode',
    ]);
    expect(code, 0, reason: '$saved');
    expect(lastCall(), [
      'scene.save',
      {
        'name': 'Bright',
        'icon': 'light_mode',
        'actions': ['lamp.brightness=90'],
        'trusted': true,
      },
    ]);
    expect((saved['id'], saved['approved']), ('bright', true));
    final (_, listed) = await omni(['scene', 'list']);
    expect(
      (listed['scenes'] as List).single,
      containsPair('icon', 'light_mode'),
    );
    await omni(['scene', 'run', 'bright']);
    expect(lastCall(), [
      'scene.run',
      {'id': 'bright'},
    ]);
    final (removedCode, _) = await omni(['scene', 'remove', 'bright']);
    expect(removedCode, 0);
  });

  test('omni automation lists with filters and fills a template', () async {
    await omni(['automation', 'list', '--device', 'lamp', '--needs-you']);
    expect(lastCall(), [
      'automation.list',
      {'device': 'lamp', 'needsYou': true},
    ]);
    final (code, filled) = await omni([
      'automation',
      'templates',
      'bedtime',
      'things=["lamp.power"]',
      'time=22:30',
    ]);
    expect(code, 0, reason: '$filled');
    final spec = ((filled['templates'] as List).single as Map)['spec'] as Map;
    expect(spec['when'], [
      {'time': '22:30'},
    ]);
  });

  test('omni presence says whether you are home', () async {
    final (code, out) = await omni(['presence', 'home']);
    expect(code, 0, reason: '$out');
    expect((out['state'] as Map)['homeSource'], 'manual');
    expect(lastCall(), [
      'presence.set',
      {'home': true},
    ]);
  });
}
