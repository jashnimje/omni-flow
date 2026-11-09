import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/tv/fake_tvs.dart';

void main() {
  late Directory home;
  late InMemorySecretStore secrets;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_pairing_cli');
    secrets = InMemorySecretStore();
  });

  tearDown(() => home.delete(recursive: true));

  Future<(int, String)> omni(List<String> args) async {
    final out = StringBuffer();
    final code = await OmniCommandRunner(
      out: out,
      engineFactory: (h, {tap}) =>
          OmniEngine.open(home: h, secrets: secrets, tap: tap),
      socketPath: '${home.path}/none.sock',
    ).run(['--home', home.path, ...args]);
    return (code, out.toString());
  }

  test('omni device pair prints the prompt first, then the result', () async {
    final tv = await FakeWebOsTv.start();
    addTearDown(tv.close);
    final (addCode, _) = await omni([
      'device',
      'add',
      'lounge',
      '--driver',
      'lg_webos_tv',
      '--host',
      '127.0.0.1',
      '--port',
      '${tv.port}',
    ]);
    expect(addCode, 0);

    final (code, out) = await omni(['device', 'pair', 'lounge']);
    expect(code, 0, reason: out);
    final firstLine = out.split('\n').first;
    expect(jsonDecode(firstLine), {
      'event': 'pairing.started',
      'method': 'tv',
      'prompt': contains('Allow'),
    });
    final result =
        jsonDecode(out.substring(firstLine.length + 1)) as Map<String, Object?>;
    expect(result, containsPair('paired', true));
    expect(out, isNot(contains('fake-client-key')));
    expect(
      await secrets.read(deviceSecretKey('lounge', 'clientKey')),
      isNotNull,
    );
  });

  test('omni device hostkey refuses a device that has no SSH host', () async {
    await omni([
      'device',
      'add',
      'bulb',
      '--driver',
      'philips_wiz_udp',
      '--host',
      '127.0.0.1',
    ]);
    final (code, out) = await omni(['device', 'hostkey', 'bulb']);
    expect(code, 1);
    expect(
      ((jsonDecode(out) as Map)['error'] as Map)['message'],
      contains('does not run commands over SSH'),
    );
    await expectLater(
      omni(['device', 'hostkey', 'bulb', '--accept', 'SHA256:x', '--clear']),
      throwsA(isA<UsageException>()),
    );
  });
}
