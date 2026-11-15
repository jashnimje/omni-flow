import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'omni_command_runner.dart';

/// `omni rule`: add, list, show and remove rules. Every argument goes to the
/// engine as written, and the engine expands the shorthand, so the app and
/// the MCP tools read the same words.
class RuleCommand extends Command<int> {
  RuleCommand() {
    addSubcommand(RuleAddCommand());
    addSubcommand(
      _RuleApiCommand(
        'list',
        'List rules.',
        'automation.list',
        (_) => {'source': 'rule'},
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'show',
        'Show one rule as it was written, with the flow it runs as.',
        'automation.get',
        (rest) => {'id': _one(rest)},
        usage: 'ID',
        rulesOnly: true,
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'remove',
        'Remove a rule.',
        'automation.remove',
        (rest) => {'id': _one(rest)},
        usage: 'ID',
        rulesOnly: true,
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'tokens',
        'The values a step can use: omni rule tokens rule.json "then[1]"',
        'rule.tokens',
        (rest) {
          if (rest.length != 2) throw UsageException('needs FILE PATH', '');
          final Object? rule;
          try {
            rule = jsonDecode(File(rest[0]).readAsStringSync());
          } on FileSystemException catch (e) {
            throw UsageException('cannot read ${rest[0]}: ${e.message}', '');
          } on FormatException catch (e) {
            throw UsageException('${rest[0]} is not JSON: ${e.message}', '');
          }
          return {'rule': rule, 'path': rest[1]};
        },
        usage: 'FILE PATH',
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'parse',
        'Read a sentence as a rule, without saving it: '
            'omni rule parse "turn off the lights when I leave"',
        'rule.parse',
        (rest) {
          if (rest.isEmpty) throw UsageException('needs TEXT', '');
          return {'text': rest.join(' ')};
        },
        usage: 'TEXT',
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'suggestions',
        'Rules offered from your habits in device history.',
        'suggest.list',
        (_) => {},
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'dismiss-suggestion',
        'Stop offering one suggestion.',
        'suggest.dismiss',
        (rest) => {'id': _one(rest)},
        usage: 'ID',
      ),
    );
    // Why an automation did not run, which ones fight over a device, and
    // its earlier versions. Any automation, not only rules.
    addSubcommand(
      _RuleApiCommand(
        'why-not',
        'The triggers that fired lately without a run, and why.',
        'automation.skips',
        (rest) => {'id': _one(rest)},
        usage: 'ID',
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'conflicts',
        'Automations that set one device two ways on the same trigger.',
        'automation.conflicts',
        (rest) => {if (rest.isNotEmpty) 'id': _one(rest)},
        usage: '[ID]',
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'versions',
        'The last 10 saved versions of an automation.',
        'automation.versions',
        (rest) => {'id': _one(rest)},
        usage: 'ID',
      ),
    );
    addSubcommand(
      _RuleApiCommand(
        'restore',
        'Go back to a saved version.',
        'automation.restore',
        (rest) {
          final version = rest.length == 2 ? int.tryParse(rest[1]) : null;
          if (version == null) throw UsageException('needs ID VERSION', '');
          return {'id': rest[0], 'version': version, 'trusted': true};
        },
        usage: 'ID VERSION',
      ),
    );
  }

  @override
  String get name => 'rule';

  @override
  String get description =>
      'Rules: when something happens, only if conditions hold, run steps.';

  static String _one(List<String> rest) {
    if (rest.length != 1) throw UsageException('needs ID', '');
    return rest.single;
  }
}

/// Sends one core API command and prints the result.
abstract class _RuleCommandBase extends Command<int> {
  String get apiCommand;

  Map<String, Object?> buildArgs();

  /// Acts only on an automation saved as a rule, so `omni rule remove`
  /// cannot delete a graph flow or a link that shares the id space.
  bool get rulesOnly => false;

  @override
  Future<int> run() async {
    final args = buildArgs();
    final omni = runner! as OmniCommandRunner;
    final engine = await omni.connect();
    try {
      var result = rulesOnly
          ? await engine.handle('automation.get', {'id': args['id']})
          : null;
      if (result != null && result['ok'] == true) {
        final source = result['source'];
        if (source != 'rule') {
          result = {
            'ok': false,
            'error': {
              'type': 'invalid',
              'message':
                  '${args['id']} is a $source, not a rule. Use '
                  '${switch (source) {
                    'link' => 'omni link',
                    'scene' => 'omni scene',
                    _ => 'omni flow',
                  }} for it',
            },
          };
        } else if (apiCommand != 'automation.get') {
          result = null;
        }
      }
      result ??= await engine.handle(apiCommand, args);
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return result['ok'] == true ? 0 : 1;
    } finally {
      await engine.close();
    }
  }
}

class _RuleApiCommand extends _RuleCommandBase {
  _RuleApiCommand(
    this.name,
    this.description,
    this.apiCommand,
    this._build, {
    this._usage = '',
    this.rulesOnly = false,
  });

  @override
  final bool rulesOnly;

  @override
  final String name;
  @override
  final String description;
  @override
  final String apiCommand;
  final Map<String, Object?> Function(List<String> rest) _build;
  final String _usage;

  @override
  String get invocation =>
      '${super.invocation.replaceFirst(' [arguments]', '')} $_usage'
          .trimRight();

  @override
  Map<String, Object?> buildArgs() => _build(argResults!.rest);
}

/// `omni rule add "Evening lights" --when home:entered --when time:18:00
/// --only-if lamp.power=false --then lamp.power=true --then wait:2s
/// --then notify:"Welcome home"`.
class RuleAddCommand extends _RuleCommandBase {
  RuleAddCommand() {
    argParser
      ..addMultiOption(
        'when',
        splitCommas: false,
        help:
            'A trigger, repeatable: thing.key, thing.key=value, thing.key>28, '
            'nfc:TAG, PLACE:entered, PLACE:left, time:18:00[@mon,fri], '
            'every:30s, manual, or a JSON object.',
      )
      ..addMultiOption(
        'only-if',
        splitCommas: false,
        help:
            'A condition, repeatable, all must hold: thing.key, '
            'thing.key=value, thing.key>=20, \$Var=value, '
            'time:18:00-23:00, days:mon,fri, not:..., or a JSON object.',
      )
      ..addMultiOption(
        'then',
        splitCommas: false,
        help:
            'A step, repeatable, in order: thing.action, thing.action=value, '
            'toggle:thing.action, wait:2s, notify:text, set:\$Var=value, '
            'run:ID, or a JSON object for if, together, repeat, try and waitFor.',
      )
      ..addOption('id', help: 'The id to save it under. Defaults from NAME.')
      ..addOption(
        'mode',
        allowed: ['single', 'restart', 'queued', 'parallel'],
        help: 'What a trigger does while a run is still going.',
      )
      ..addFlag(
        'disabled',
        negatable: false,
        help: 'Save it without turning it on.',
      )
      ..addOption('color', help: 'Its colour, as a hex such as #A78BFA.')
      ..addOption('icon', help: 'Its icon: bolt, home, movie, lightbulb, ...')
      ..addFlag(
        'ask-first',
        negatable: false,
        help: 'When a trigger starts it, ask on the phone before it runs.',
      )
      ..addFlag(
        'notify-on-run',
        negatable: false,
        help: 'Notify after each run that completes.',
      )
      ..addFlag(
        'replace',
        negatable: false,
        help: 'Replace the rule that already has this id.',
      );
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Add a rule, or replace one with --replace.';

  @override
  String get invocation =>
      'omni rule add NAME --when ... [--only-if ...] '
      '--then ...';

  @override
  String get apiCommand => 'automation.save';

  @override
  Map<String, Object?> buildArgs() {
    final a = argResults!;
    if (a.rest.length != 1) throw UsageException('needs NAME', usage);
    final when = a.multiOption('when');
    final then = a.multiOption('then');
    // A rule of keep steps alone needs no --when: the engine says when one
    // is missing.
    if (then.isEmpty) throw UsageException('needs at least one --then', usage);
    return {
      'form': 'rule',
      'spec': {
        if (a.option('id') != null) 'id': a.option('id'),
        'name': a.rest.single,
        if (when.isNotEmpty) 'when': [for (final w in when) _item(w)],
        if (a.multiOption('only-if').isNotEmpty)
          'onlyIf': [for (final c in a.multiOption('only-if')) _item(c)],
        'then': [for (final s in then) _item(s)],
        if (a.option('mode') != null) 'mode': a.option('mode'),
        if (a.flag('disabled')) 'enabled': false,
        if (a.option('color') != null) 'color': a.option('color'),
        if (a.option('icon') != null) 'icon': a.option('icon'),
        if (a.flag('ask-first')) 'askFirst': true,
        if (a.flag('notify-on-run')) 'notifyOnRun': true,
      },
      'trusted': true,
      if (a.flag('replace')) 'replace': true,
    };
  }

  /// A JSON object stays an object, so an if or together step can be
  /// written in place. Anything else is shorthand for the engine.
  Object? _item(String text) {
    final t = text.trim();
    if (!t.startsWith('{')) return text;
    try {
      return jsonDecode(t);
    } on FormatException catch (e) {
      throw UsageException('$t is not valid JSON: ${e.message}', usage);
    }
  }
}
