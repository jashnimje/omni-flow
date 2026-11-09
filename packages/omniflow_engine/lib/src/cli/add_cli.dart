import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../api/local_client.dart' show EngineConnection;
import 'omni_command_runner.dart';

/// Opens the engine the command talks to. Tests pass one of their own.
typedef AddConnector = Future<EngineConnection> Function();

/// What `omni add` returns when it stops before setup is done: the device is
/// added and `omni add --resume ID` continues.
const addIncompleteExitCode = 2;

/// `omni add`: finds everything that can be added, adds the one picked, and
/// walks its setup steps (pair, secrets, settings) as the engine reports
/// them in `next`. Secrets are read from stdin, hidden on a terminal, and
/// never taken as arguments. Off a terminal every prompt reads one line of
/// stdin, so a script can feed the answers.
class AddCommand extends Command<int> {
  AddCommand({this._connect, StringSink? out, Stream<List<int>>? input})
    : _outOverride = out,
      _inputOverride = input {
    argParser
      ..addOption(
        'pick',
        valueHelp: 'N',
        help: 'Add candidate N from the list, without asking.',
      )
      ..addOption(
        'driver',
        help: 'Add by address with this driver instead of picking a find.',
      )
      ..addOption('host', help: 'IP address, host name or serial port.')
      ..addOption('port', help: "Overrides the driver's port.")
      ..addOption('id', help: 'Device id. Suggested from the name if left out.')
      ..addOption('name', help: 'Display name.')
      ..addOption('room')
      ..addOption('stable-id', help: 'MAC or device id.')
      ..addMultiOption(
        'set',
        help: 'A plain setting, key=value. Repeatable. Never a secret.',
        splitCommas: false,
      )
      ..addFlag(
        'replace',
        negatable: false,
        help: 'Replace a device that is already added.',
      )
      ..addOption(
        'resume',
        valueHelp: 'ID',
        help: 'Continue the setup of a device added before.',
      )
      ..addOption(
        'window-ms',
        defaultsTo: '3000',
        help: 'How long each discovery method listens.',
      )
      ..addMultiOption(
        'method',
        help: 'Discovery methods to run. Default: all of them.',
        allowed: const [
          'udp_broadcast',
          'mdns',
          'tuya_broadcast',
          'serial',
          'hello',
        ],
      )
      ..addFlag(
        'pair',
        defaultsTo: true,
        help: 'Run a pairing step. With --no-pair the walk stops there.',
      )
      ..addFlag(
        'provision',
        defaultsTo: true,
        help:
            'Send a board its pins as they are set. Use --no-provision '
            'for a board that is not online yet.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Also print every engine reply as JSON.',
      );
  }

  final AddConnector? _connect;
  final StringSink? _outOverride;
  final Stream<List<int>>? _inputOverride;

  @override
  String get name => 'add';

  @override
  String get description =>
      'Find and add a device, then walk its setup: pairing, secrets and '
      'settings.';

  @override
  String get invocation =>
      'omni add [--pick N | --driver D --host H | '
      '--resume ID]';

  OmniCommandRunner get omni => runner! as OmniCommandRunner;

  StringSink get _out => _outOverride ?? omni.out;

  Stream<List<int>> get _input => _inputOverride ?? omni.input;

  late final bool _interactive = identical(_input, stdin) && stdin.hasTerminal;

  late final _Lines _lines = _Lines(_input);

  late final Map<String, Object?> _sets = parseSettings(
    argResults!.multiOption('set'),
  );

  void _say(String line) => _out.writeln(line);

  @override
  Future<int> run() async {
    final a = argResults!;
    if (a.rest.isNotEmpty) {
      throw UsageException('omni add takes no arguments', usage);
    }
    final resume = a.option('resume');
    final explicit = a.option('driver') != null;
    if ([
          resume != null,
          explicit,
          a.option('pick') != null,
        ].where((x) => x).length >
        1) {
      throw UsageException('use one of --pick, --driver and --resume', usage);
    }
    final engine = await (_connect ?? omni.connect)();
    try {
      if (resume != null) {
        final reply = await _call(engine, 'thing.next', {'id': resume});
        if (reply == null) return 1;
        return await _walk(engine, resume, reply);
      }
      final Map<String, Object?> args;
      if (explicit) {
        args = _explicitArgs();
      } else {
        final picked = await _pick(engine);
        if (picked == null) return 0;
        args = {
          'candidate': picked,
          'id': ?a.option('id'),
          'name': ?a.option('name'),
          'room': ?a.option('room'),
          if (_sets.isNotEmpty) 'settings': _addSettings(picked),
          if (a.flag('replace')) 'replace': true,
          if (!a.flag('provision')) 'provision': false,
        };
      }
      final added = await _call(engine, 'thing.add', args);
      if (added == null) return 1;
      final id = added['id'] as String;
      _say('Added $id');
      return await _walk(engine, id, added);
    } finally {
      await engine.close();
      await _lines.cancel();
    }
  }

  Map<String, Object?> _explicitArgs() {
    final a = argResults!;
    final port = a.option('port');
    return {
      'driver': a.option('driver'),
      'host': ?a.option('host'),
      if (port != null) 'port': int.tryParse(port) ?? port,
      'id': ?a.option('id'),
      'name': ?a.option('name'),
      'room': ?a.option('room'),
      'stableId': ?a.option('stable-id'),
      if (_sets.isNotEmpty) 'settings': _sets,
      if (a.flag('replace')) 'replace': true,
      if (!a.flag('provision')) 'provision': false,
    };
  }

  /// The `--set` values on top of a candidate's own settings (a Tuya plug's
  /// devId comes from its find).
  Map<String, Object?> _addSettings(Map<String, Object?> picked) {
    final own = (picked['add'] as Map?)?['settings'];
    return {if (own is Map) ...Map<String, Object?>.from(own), ..._sets};
  }

  /// Lists the finds and returns the one picked, or null when none is.
  Future<Map<String, Object?>?> _pick(EngineConnection engine) async {
    final a = argResults!;
    final windowMs = int.tryParse(a.option('window-ms')!);
    if (windowMs == null) {
      throw UsageException('--window-ms must be a whole number', usage);
    }
    _say('Looking for devices...');
    final found = await _call(engine, 'thing.add', {
      'windowMs': windowMs,
      if (a.multiOption('method').isNotEmpty)
        'methods': a.multiOption('method'),
    });
    if (found == null) return null;
    final candidates = <Map<String, Object?>>[];
    for (final group in (found['groups'] as List? ?? const [])) {
      final g = group as Map;
      _say('${g['name']} (${g['driver']}):');
      for (final c in (g['candidates'] as List)) {
        final candidate = Map<String, Object?>.from(c as Map);
        candidates.add(candidate);
        final port = candidate['port'] == null ? '' : ':${candidate['port']}';
        final known = candidate['knownAs'] == null
            ? ''
            : ' [added as ${candidate['knownAs']}]';
        _say(
          '  ${candidates.length}. ${candidate['name']} at '
          '${candidate['host']}$port via ${candidate['method']}$known',
        );
      }
    }
    if (candidates.isEmpty) _say('Nothing found.');
    for (final failure in (found['failures'] as List? ?? const [])) {
      _say('Could not search: $failure');
    }
    final manual = [
      for (final m in (found['manual'] as List? ?? const []))
        if ((m as Map)['virtual'] != true) m['driver'],
    ];
    if (manual.isNotEmpty) {
      _say('Add by address with --driver and --host: ${manual.join(', ')}');
    }
    final raw =
        a.option('pick') ??
        (_interactive && candidates.isNotEmpty
            ? await _ask('Add which? Number, or blank to stop: ')
            : null);
    if (raw == null || raw.isEmpty) return null;
    final n = int.tryParse(raw);
    if (n == null || n < 1 || n > candidates.length) {
      throw UsageException(
        '--pick must be 1 to ${candidates.length}, got $raw',
        usage,
      );
    }
    return candidates[n - 1];
  }

  /// Follows `next` until the device is done or a step cannot be answered.
  Future<int> _walk(
    EngineConnection engine,
    String id,
    Map<String, Object?> reply,
  ) async {
    String? previous;
    for (;;) {
      final next = Map<String, Object?>.from(reply['next'] as Map? ?? {});
      final step = next['step'];
      final signature = jsonEncode(next);
      if (signature == previous) {
        _say(
          'The $step step did not move on. Continue with: '
          'omni add --resume $id',
        );
        return addIncompleteExitCode;
      }
      previous = signature;
      final keys = [
        for (final k in (next['keys'] as List? ?? const []))
          Map<String, Object?>.from(k as Map),
      ];
      Map<String, Object?>? after;
      switch (step) {
        case 'done':
          _say('Done. ${next['instruction']}');
          for (final o in (next['optional'] as List? ?? const [])) {
            final k = o as Map;
            _say(
              'Optional: ${k['label'] ?? k['step']} '
              '(${k['step']}${k['key'] == null ? '' : ' ${k['key']}'})',
            );
          }
          return 0;
        case 'pair':
          _say('Pair: ${next['instruction']}');
          if (!argResults!.flag('pair')) return _stop(id);
          if (_interactive &&
              await _ask('Press Enter when ready, or type skip: ') == 'skip') {
            return _stop(id);
          }
          final paired = await _call(engine, 'device.pair', {'id': id});
          if (paired == null) return 1;
          _say('${paired['message']}');
          after = await _call(engine, 'thing.next', {'id': id, 'paired': true});
        case 'secret':
          _say('Secrets: ${next['instruction']}');
          for (final k in keys) {
            final optional = k['optional'] == true;
            final value = await _secret(
              '${k['label']}${optional ? ' (optional, blank to skip)' : ''}: ',
            );
            if (value == null || value.isEmpty) {
              if (optional) continue;
              return _stop(id);
            }
            final stored = await _call(engine, 'secret.set', {
              'deviceId': id,
              'key': k['key'],
              'value': value,
            }, quiet: true);
            if (stored == null) return 1;
            _say('Stored ${k['key']}');
          }
          after = await _call(engine, 'thing.next', {'id': id});
        case 'configure':
          _say('Settings: ${next['instruction']}');
          final settings = <String, Object?>{};
          for (final k in keys) {
            final key = k['key'] as String;
            final optional = k['optional'] == true;
            final given = _sets[key];
            final raw = given == null
                ? await _ask(
                    '${k['label']}${optional ? ' (optional, blank to skip)' : ''}: ',
                  )
                : null;
            if (given == null && (raw == null || raw.isEmpty)) {
              if (optional) continue;
              return _stop(id);
            }
            settings[key] = given ?? settingValue(raw!);
          }
          if (settings.isEmpty) return _stop(id);
          after = await _call(engine, 'thing.configure', {
            'id': id,
            'settings': settings,
            if (!argResults!.flag('provision')) 'provision': false,
          });
        default:
          _say('Unknown setup step $step');
          return 1;
      }
      if (after == null) return 1;
      reply = after;
    }
  }

  int _stop(String id) {
    _say('Stopped. Continue with: omni add --resume $id');
    return addIncompleteExitCode;
  }

  /// Sends one command. Prints the error and returns null when it fails.
  /// [quiet] keeps the reply out of `--json` output.
  Future<Map<String, Object?>?> _call(
    EngineConnection engine,
    String command,
    Map<String, Object?> args, {
    bool quiet = false,
  }) async {
    final result = await engine.handle(command, args);
    if (argResults!.flag('json') && !quiet) {
      _say(jsonEncode(result));
    }
    if (result['ok'] == true) return result;
    final error = result['error'];
    _say('Failed: ${error is Map ? error['message'] : error}');
    return null;
  }

  Future<String?> _ask(String prompt) async {
    _out.write(prompt);
    final line = await _lines.next();
    if (!_interactive) _out.writeln();
    return line?.trim();
  }

  /// Reads a secret with the terminal echo off, so it is never shown.
  Future<String?> _secret(String prompt) async {
    _out.write(prompt);
    final hide = _interactive;
    if (hide) stdin.echoMode = false;
    try {
      return (await _lines.next())?.replaceFirst(RegExp(r'\r$'), '');
    } finally {
      if (hide) stdin.echoMode = true;
      _out.writeln();
    }
  }
}

/// The lines of the CLI's input, read one at a time across prompts.
class _Lines {
  _Lines(Stream<List<int>> input) : _source = input;

  final Stream<List<int>> _source;
  StreamIterator<String>? _lines;

  Future<String?> next() async {
    final lines = _lines ??= StreamIterator(
      _source.transform(utf8.decoder).transform(const LineSplitter()),
    );
    return await lines.moveNext() ? lines.current : null;
  }

  Future<void> cancel() async => _lines?.cancel();
}
