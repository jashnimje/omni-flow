import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

void main() {
  late Directory home;

  /// Runs `omni ARGS` on an engine opened in [home] for this one command,
  /// as the CLI does with no hub running.
  Future<(int, Map<String, Object?>)> omni(List<String> args) async {
    final out = StringBuffer();
    final runner = OmniCommandRunner(
      out: out,
      input: const Stream.empty(),
      engineFactory: (dir, {tap}) => OmniEngine.open(
        home: dir,
        secrets: InMemorySecretStore(),
        mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
      ),
    );
    final code = await runner.run(['--home', home.path, ...args]);
    final text = out.toString().trim();
    return (
      code,
      text.isEmpty
          ? <String, Object?>{}
          : Map<String, Object?>.from(jsonDecode(text) as Map),
    );
  }

  List<Object?> ids(Map<String, Object?> r, String key) => [
    for (final e in r[key] as List) (e as Map)['id'],
  ];

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_house_cli');
  });

  tearDown(() => home.delete(recursive: true));

  test('omni house add, list, rename, use and remove', () async {
    var (code, r) = await omni(['house', 'list']);
    expect(code, 0);
    expect(ids(r, 'houses'), ['home']);
    // With one house, things go in it without asking.
    (code, r) = await omni(['room', 'save', 'Study']);
    expect(code, 0, reason: '$r');

    (code, r) = await omni(['house', 'add', 'Bangalore']);
    expect(code, 0);
    expect((r['house'] as Map)['id'], 'bangalore');
    (code, r) = await omni(['house', 'rename', 'home', 'Mumbai']);
    expect((r['house'] as Map)['name'], 'Mumbai');

    // Two houses and none chosen: a list shows both, a save asks which.
    (code, r) = await omni(['room', 'list']);
    expect(ids(r, 'rooms'), ['study']);
    (code, r) = await omni(['room', 'save', 'Den']);
    expect(code, 1);
    expect(
      ((r['error'] as Map)['message'] as String),
      contains('There are 2 houses: Mumbai (home), Bangalore (bangalore)'),
    );
    (code, r) = await omni(['--house', 'bangalore', 'room', 'save', 'Den']);
    expect(code, 0, reason: '$r');

    (code, r) = await omni(['house', 'use', 'Bangalore']);
    expect((code, r['house']), (0, 'bangalore'));
    (code, r) = await omni(['house', 'use']);
    expect(r['house'], 'bangalore');
    (code, r) = await omni(['room', 'list']);
    expect(ids(r, 'rooms'), ['den']);
    // --house wins over the choice.
    (code, r) = await omni(['--house', 'home', 'room', 'list']);
    expect(ids(r, 'rooms'), ['study']);

    (code, r) = await omni(['house', 'use', 'nowhere']);
    expect(code, 1);
    (code, r) = await omni(['house', 'use', '--clear']);
    expect((code, r['house']), (0, null));
    (code, r) = await omni(['house', 'remove', 'bangalore']);
    expect(code, 0, reason: '$r');
    (code, r) = await omni(['house', 'list']);
    expect(ids(r, 'houses'), ['home']);
  });
}
