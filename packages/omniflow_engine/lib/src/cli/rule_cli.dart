import 'dart:convert';

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
                  '${source == 'link' ? 'omni link' : 'omni flow'} for it',
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
            'run:ID, or a JSON object for if, together and waitFor.',
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
    if (when.isEmpty || then.isEmpty) {
      throw UsageException('needs at least one --when and one --then', usage);
    }
    return {
      'form': 'rule',
      'spec': {
        if (a.option('id') != null) 'id': a.option('id'),
        'name': a.rest.single,
        'when': [for (final w in when) _item(w)],
        if (a.multiOption('only-if').isNotEmpty)
          'onlyIf': [for (final c in a.multiOption('only-if')) _item(c)],
        'then': [for (final s in then) _item(s)],
        if (a.option('mode') != null) 'mode': a.option('mode'),
        if (a.flag('disabled')) 'enabled': false,
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
