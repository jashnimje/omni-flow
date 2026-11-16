import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart' show UsageException;
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/cli/parity_cli.dart' show diagramTree;
import 'package:test/test.dart';

/// The CLI reaches every home helper the app does, through the same
/// commands.
void main() {
  late Directory home;
  late InMemorySecretStore secrets;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_parity_cli');
    secrets = InMemorySecretStore();
  });

  tearDown(() => home.delete(recursive: true));

  Future<(int, String)> omni(List<String> args, {String input = ''}) async {
    final out = StringBuffer();
    final code = await OmniCommandRunner(
      out: out,
      input: Stream.value(utf8.encode(input)),
      engineFactory: (h, {tap}) =>
          OmniEngine.open(home: h, secrets: secrets, tap: tap),
    ).run(['--home', home.path, ...args]);
    return (code, out.toString());
  }

  Future<Map> ok(List<String> args) async {
    final (code, out) = await omni(args);
    expect(code, 0, reason: out);
    return jsonDecode(out) as Map;
  }

  test('energy, weather, sun and away lighting have verbs', () async {
    expect(
      (await ok(['energy', 'summary', '--days', '3'])).keys,
      contains('ok'),
    );
    expect((await ok(['energy', 'price', '8.5', 'Rs']))['perKwh'], 8.5);
    expect((await ok(['energy', 'price']))['currency'], 'Rs');
    expect((await ok(['energy', 'price', '--clear']))['perKwh'], isNull);
    expect((await ok(['weather', 'refresh']))['weather'], isEmpty);
    final (code, out) = await omni(['weather', 'add']);
    expect(code, 1);
    expect(out, contains('where home is'));
    expect((await ok(['sunlight', 'get']))['ok'], isTrue);
    expect((await ok(['away', 'get']))['enabled'], isFalse);
    expect((await ok(['away', 'preview']))['ok'], isTrue);
    expect((await ok(['board', 'ports']))['canFlash'], isFalse);
  });

  test('flow run and automation run start a time-only rule now', () async {
    await ok([
      'rule',
      'add',
      'Evening',
      '--when',
      'time:18:00',
      '--then',
      'notify:Evening',
    ]);
    final run = await ok(['flow', 'run', 'evening']);
    expect(run['ok'], isTrue);
    expect((await ok(['automation', 'run', 'evening']))['ok'], isTrue);
    expect((await ok(['automation', 'disable', 'evening']))['ok'], isTrue);
    final log = await ok(['automation', 'log', 'evening', '--limit', '5']);
    expect(log['runs'], isNotEmpty);
    expect((await ok(['automation', 'remove', 'evening']))['ok'], isTrue);
    final removed = await ok(['automation', 'removed']);
    expect(
      (removed['removed'] as List).map((r) => (r as Map)['id']),
      contains('evening'),
    );
    expect((await ok(['automation', 'unremove', 'evening']))['ok'], isTrue);
    expect((await ok(['automation', 'versions', 'evening']))['ok'], isTrue);
  });

  test('the diagram prints as an indented tree, with the last run', () async {
    await ok([
      'rule',
      'add',
      'Hello',
      '--when',
      'manual',
      '--then',
      'notify:Hi',
      '--then',
      'wait:2s',
    ]);
    await ok(['automation', 'run', 'hello']);
    final (code, out) = await omni([
      'automation',
      'diagram',
      'hello',
      '--run',
      'last',
    ]);
    expect(code, 0, reason: out);
    final lines = out.trim().split('\n');
    expect(lines.first, isNot(startsWith(' ')));
    expect(out, contains('notify "Hi"'));
    expect(out, contains('[ran]'));
    expect(lines.where((l) => l.startsWith('  ')), isNotEmpty);
  });

  test('a diagram tree writes a node reached twice once more', () {
    final tree = diagramTree({
      'nodes': [
        {'id': 'a', 'words': 'When it starts'},
        {'id': 'b', 'words': 'if it is on'},
        {'id': 'c', 'words': 'notify "Hi"', 'status': 'ran'},
      ],
      'edges': [
        {'from': 'a', 'to': 'b'},
        {'from': 'b', 'to': 'c', 'label': 'yes', 'taken': true},
        {'from': 'b', 'to': 'c', 'label': 'no'},
      ],
    });
    expect(tree.split('\n').where((l) => l.isNotEmpty), [
      'When it starts',
      '  if it is on',
      '    yes (taken): notify "Hi"  [ran]',
      '    no: notify "Hi"  [ran]  (as above)',
    ]);
  });

  test(
    'android pair reads the code from stdin, never from the arguments',
    () async {
      final (code, out) = await omni([
        'android',
        'pair',
        '127.0.0.1',
        '1',
      ], input: '12345\n');
      expect(code, 1);
      expect(out, contains('Pairing code'));
      expect(out, contains('six digits'));
      await expectLater(
        omni(['android', 'pair', '127.0.0.1']),
        throwsA(isA<UsageException>()),
      );
    },
  );

  test('tv notifications and device move have verbs', () async {
    final (code, out) = await omni(['tv', 'nope', 'notifications', 'collapse']);
    expect(code, 1);
    expect(out, contains('nope'));
    final (moved, said) = await omni(['device', 'move', 'nope', '10.0.0.2']);
    expect(moved, 1);
    expect(said, contains('no device nope'));
  });
}
