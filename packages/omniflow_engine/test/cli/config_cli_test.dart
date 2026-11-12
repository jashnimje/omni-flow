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
    home = await Directory.systemTemp.createTemp('omni_config_cli');
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    shared = _Shared(engine);
    await engine.handle('device.add', {'id': 'jade', 'driver': 'person'});
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<(int, String)> omni(List<String> args) async {
    final out = StringBuffer();
    final code = await _Runner(shared, out).run(args);
    return (code, out.toString());
  }

  test('omni config exports to a file and imports it back', () async {
    final file = '${home.path}/backup.json';
    final (code, _) = await omni(['config', 'export', '--out', file]);
    expect(code, 0);
    final backup = jsonDecode(File(file).readAsStringSync()) as Map;
    expect(backup['schema'], 'omniflow.backup');

    final (dryCode, dry) = await omni([
      'config',
      'import',
      file,
      '--replace',
      '--dry-run',
    ]);
    expect(dryCode, 0, reason: dry);
    expect(shared.calls.last.$1, 'config.import');
    expect(shared.calls.last.$2, containsPair('mode', 'replace'));
    expect(shared.calls.last.$2, containsPair('dryRun', true));
    expect((jsonDecode(dry) as Map)['applied'], isFalse);
  });

  test('omni home location set takes negative degrees', () async {
    final (code, out) = await omni([
      'home',
      'location',
      'set',
      '--latitude',
      '51.5074',
      '--longitude',
      '-0.1278',
    ]);
    expect(code, 0, reason: out);
    expect(shared.calls.last.$2, {'latitude': 51.5074, 'longitude': -0.1278});
    final (_, shown) = await omni(['home', 'location', 'show']);
    expect((jsonDecode(shown) as Map)['location'], {
      'latitude': 51.5074,
      'longitude': -0.1278,
    });
  });
}
