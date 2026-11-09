import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  test('--version prints the engine version and exits 0', () async {
    final out = StringBuffer();
    final code = await OmniCommandRunner(out: out).run(['--version']);
    expect(code, 0);
    expect(out.toString().trim(), 'omni $omniflowEngineVersion');
  });

  test('an unknown command is a usage error', () {
    expect(
      () => OmniCommandRunner(out: StringBuffer()).run(['nope']),
      throwsA(isA<UsageException>()),
    );
  });

  group('as bin/omni runs it', () {
    late Directory home;
    final secrets = InMemorySecretStore();

    setUp(() async {
      home = await Directory.systemTemp.createTemp('omni_cli_main');
    });
    tearDown(() => home.delete(recursive: true));

    Future<(int, String, String)> omni(List<String> args) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runOmni(
        ['--home', home.path, ...args],
        runner: OmniCommandRunner(
          out: out,
          input: const Stream.empty(),
          engineFactory: (h, {tap}) =>
              OmniEngine.open(home: h, secrets: secrets, tap: tap),
        ),
        err: err,
      );
      return (code, out.toString(), err.toString());
    }

    test('a missing file is one line and exit 66', () async {
      final (code, _, err) = await omni([
        'flow',
        'save',
        '${home.path}/missing.json',
      ]);
      expect(code, 66);
      expect(const LineSplitter().convert(err), hasLength(1));
      expect(err, contains('missing.json'));
    });

    test('a database held by another omni is one line and exit 75', () async {
      final held = await OmniEngine.open(home: home, secrets: secrets);
      addTearDown(held.close);
      final (code, _, err) = await omni(['device', 'list']);
      expect(code, 75);
      expect(err.trim(), contains('in use by another omni process'));
      expect(const LineSplitter().convert(err), hasLength(1));
      // The usual holder is an MCP client's omni mcp started before the hub.
      expect(err, contains('omni mcp'));
      expect(err, contains('Start omni hub first'));
    });

    test('a bad number for --seconds is a usage error, exit 64', () async {
      final (code, _, err) = await omni(['hub', '--seconds', 'soon']);
      expect(code, 64);
      expect(err, contains('--seconds needs a number'));
    });

    test('--msg reaches flows that read msg.value, like links', () async {
      final engine = await OmniEngine.open(home: home, secrets: secrets);
      String linkId;
      try {
        for (final id in ['desk_lamp', 'hall_lamp']) {
          await engine.handle('device.add', {
            'id': id,
            'driver': 'philips_wiz_udp',
            'host': '127.0.0.1',
          });
        }
        await engine.devices.mergeState('desk_lamp', {'state': false});
        final link = await engine.handle('link.create', {
          'from': 'desk_lamp.state',
          'to': 'hall_lamp.power',
          'mode': 'toggle',
          'trusted': true,
        });
        expect(link['ok'], isTrue, reason: '$link');
        linkId = link['id'] as String;
      } finally {
        await engine.close();
      }
      Future<List<String>> nodesRun(List<String> extra) async {
        final (code, out, err) = await omni([
          'flow',
          'dry-run',
          linkId,
          ...extra,
        ]);
        expect(code, 0, reason: '$out$err');
        final run = (jsonDecode(out) as Map)['run'] as Map;
        return [for (final n in (run['nodes'] as List).cast<Map>()) n['node']];
      }

      expect(await nodesRun(['--msg', '{"value": true}']), contains('flip'));
      expect(await nodesRun(['value=true']), isNot(contains('flip')));
    });
  });
}
