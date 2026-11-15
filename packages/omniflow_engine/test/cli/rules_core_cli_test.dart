import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// `omni rule why-not`, `conflicts`, `versions` and `restore`, each on an
/// engine of its own over one home, as the CLI opens it.
class _Runner extends OmniCommandRunner {
  _Runner(this.dir, StringSink out)
    : super(out: out, input: const Stream.empty());

  final Directory dir;

  @override
  Future<EngineConnection> connect({PacketTap? tap}) async =>
      InProcessConnection(
        await OmniEngine.open(
          home: dir,
          secrets: InMemorySecretStore(),
          mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
        ),
      );
}

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_rules_core_cli');
  });

  tearDown(() => home.delete(recursive: true));

  Future<(int, Map<String, Object?>)> omni(List<String> args) async {
    final out = StringBuffer();
    final code = await _Runner(home, out).run(args);
    return (code, jsonDecode(out.toString()) as Map<String, Object?>);
  }

  test('versions and restore, why-not and conflicts', () async {
    for (final title in ['one', 'two']) {
      final (code, _) = await omni([
        'rule',
        'add',
        'Versioned',
        '--when',
        'manual',
        '--then',
        'notify:$title',
        '--replace',
      ]);
      expect(code, 0);
    }
    final (_, versions) = await omni(['rule', 'versions', 'versioned']);
    final list = (versions['versions'] as List).cast<Map>();
    expect(list.single['version'], 1);
    final (code, restored) = await omni(['rule', 'restore', 'versioned', '1']);
    expect(code, 0, reason: '$restored');
    expect(restored['restored'], 1);
    final (_, skips) = await omni(['rule', 'why-not', 'versioned']);
    expect(skips['skips'], isEmpty);
    final (_, conflicts) = await omni(['rule', 'conflicts']);
    expect(conflicts['conflicts'], isEmpty);
    await expectLater(
      omni(['rule', 'restore', 'versioned']),
      throwsA(isA<UsageException>()),
    );
  });
}
