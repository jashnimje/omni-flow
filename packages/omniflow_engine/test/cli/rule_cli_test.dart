import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/cli/rule_cli.dart';
import 'package:test/test.dart';

import '../api/automation_harness.dart';

/// The CLI with `omni rule`, talking to [harness] as it would to a hub.
class _Runner extends OmniCommandRunner {
  _Runner(this.harness, StringSink out)
    : super(out: out, input: const Stream.empty()) {
    if (!commands.containsKey('rule')) addCommand(RuleCommand());
  }

  final AutomationHarness harness;

  @override
  Future<EngineConnection> connect({PacketTap? tap}) async => harness;
}

void main() {
  late Directory home;
  late AutomationHarness h;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_rule_cli');
    h = await AutomationHarness.open(home);
  });

  tearDown(() async {
    await h.shutdown();
    await home.delete(recursive: true);
  });

  Future<(int, Map<String, Object?>)> omni(List<String> args) async {
    final out = StringBuffer();
    final code = await _Runner(h, out).run(args);
    return (code, jsonDecode(out.toString()) as Map<String, Object?>);
  }

  test('rule add sends the shorthand as written, trusted', () async {
    final (code, saved) = await omni([
      'rule',
      'add',
      'Welcome home',
      '--when',
      'home:entered',
      '--when',
      'nfc:front_door',
      '--only-if',
      'lamp.power=false',
      '--only-if',
      'time:17:00-23:59',
      '--then',
      'lamp.power=true',
      '--then',
      'wait:2s',
      '--then',
      'notify:"Welcome, home"',
      '--then',
      '{"if": ["jade.home"], "then": ["set:\$Seen=true"]}',
      '--mode',
      'queued',
    ]);
    expect(code, 0, reason: '$saved');
    expect(saved, containsPair('id', 'welcome_home'));
    expect(saved, containsPair('approved', true));
    final (_, got) = await omni(['rule', 'show', 'welcome_home']);
    final spec = got['spec'] as Map;
    expect(spec['when'], [
      {
        'on': 'jade.home',
        'change': {'to': true},
      },
      {'on': 'front_door.scanned', 'event': true},
    ]);
    expect(spec['then'], [
      {
        'do': 'lamp.power',
        'params': {'value': true},
      },
      {'wait': 2000},
      {
        'notify': {'title': 'Welcome, home'},
      },
      {
        'if': [
          {'state': 'jade.home', 'op': '==', 'value': true},
        ],
        'then': [
          {
            'set': {'var': r'$Seen', 'value': true},
          },
        ],
      },
    ]);
    expect(spec['mode'], 'queued');
  });

  test(
    'rule add refuses an id a rule has, and --replace replaces it',
    () async {
      List<String> evening(String then) => [
        'rule',
        'add',
        'Evening',
        '--when',
        'time:18:00',
        '--then',
        then,
      ];
      expect((await omni(evening('lamp.power=true'))).$1, 0);
      final (code, refused) = await omni(evening('lamp.power=false'));
      expect(code, 1);
      expect(refused['error'], containsPair('type', 'exists'));
      expect((await omni([...evening('lamp.power=false'), '--replace'])).$1, 0);
      final (_, got) = await omni(['rule', 'show', 'evening']);
      expect(((got['spec'] as Map)['then'] as List).single, {
        'do': 'lamp.power',
        'params': {'value': false},
      });
    },
  );

  test('rule list shows only rules, and rule remove removes one', () async {
    await omni([
      'rule',
      'add',
      'Evening',
      '--when',
      'time:18:00',
      '--then',
      'lamp.power=true',
      '--disabled',
    ]);
    await h.handle('link.create', {
      'from': 'jade.home',
      'to': 'lamp.power',
      'mode': 'toggle',
    });
    final (_, listed) = await omni(['rule', 'list']);
    final rules = (listed['automations'] as List).cast<Map>();
    expect(
      [for (final r in rules) (r['id'], r['enabled'])],
      [('evening', false)],
    );
    final (code, removed) = await omni(['rule', 'remove', 'evening']);
    expect((code, removed['removed']), (0, true));
    final (missing, _) = await omni(['rule', 'show', 'evening']);
    expect(missing, 1);
  });

  test(
    'rule show and rule remove refuse an automation that is not a rule',
    () async {
      final link = await h.handle('link.create', {
        'from': 'jade.home',
        'to': 'lamp.power',
        'mode': 'toggle',
      });
      expect(link['ok'], isTrue, reason: '$link');
      final linkId = link['id'] as String;
      for (final verb in ['show', 'remove']) {
        final (code, refused) = await omni(['rule', verb, linkId]);
        expect(code, 1, reason: verb);
        expect((refused['error'] as Map)['message'], contains('omni link'));
      }
      final (missingCode, missing) = await omni(['rule', 'remove', 'nothing']);
      expect(missingCode, 1);
      expect((missing['error'] as Map)['type'], 'not_found');
      final still = await h.handle('automation.get', {'id': linkId});
      expect(still['ok'], isTrue);
    },
  );

  test('a rule the engine refuses exits 1 with the rule path', () async {
    final (code, result) = await omni([
      'rule',
      'add',
      'Broken',
      '--when',
      'garage.door',
      '--then',
      'lamp.power=true',
    ]);
    expect(code, 1);
    expect(
      ((result['error'] as Map)['issues'] as List).single,
      containsPair('path', 'when[0].on'),
    );
  });

  test('rule add sets the colour, icon, ask first and notify on run', () async {
    final (code, saved) = await omni([
      'rule',
      'add',
      'Movie time',
      '--when',
      'every:60s',
      '--then',
      'notify:hi',
      '--color',
      '#A78BFA',
      '--icon',
      'movie',
      '--ask-first',
      '--notify-on-run',
    ]);
    expect(code, 0, reason: '$saved');
    final got = await h.handle('automation.get', {'id': saved['id']});
    expect(got['spec'], containsPair('color', '#A78BFA'));
    expect(got['spec'], containsPair('askFirst', true));
    expect(got['spec'], containsPair('notifyOnRun', true));
  });

  test('a rule of keep steps alone needs no --when', () async {
    final (code, saved) = await omni([
      'rule',
      'add',
      'Evening lamp',
      '--then',
      jsonEncode({
        'keep': {
          'target': 'lamp.power',
          'value': true,
          'while': [
            {
              'between': ['18:00', '23:00'],
            },
          ],
        },
      }),
    ]);
    expect(code, 0, reason: '$saved');
    expect(saved['ok'], isTrue);
  });

  test('usage mistakes are caught before the engine', () async {
    final runner = _Runner(h, StringBuffer());
    for (final args in [
      ['rule', 'add', '--when', 'manual', '--then', 'wait:1s'],
      ['rule', 'add', 'Only when', '--when', 'manual'],
      ['rule', 'add', 'Bad json', '--when', 'manual', '--then', '{"do":'],
      ['rule', 'show'],
    ]) {
      await expectLater(
        runner.run(args),
        throwsA(isA<UsageException>()),
        reason: '$args',
      );
    }
  });
}
