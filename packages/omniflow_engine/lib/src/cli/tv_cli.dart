import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../api/local_client.dart';
import 'omni_command_runner.dart';
import 'one_shot.dart';

const _tvUsage = '''
omni tv ID remote KEY [--long] [--repeat N]
omni tv ID keys
omni tv ID text TEXT
omni tv ID volume N
omni tv ID state
omni tv ID apps [list] [--filter user|system|all] [--launchable]
omni tv ID apps open|stop|info|clear-cache|clear-data|disable|enable|uninstall PACKAGE
omni tv ID apps install FILE.apk [--replace]
omni tv ID settings catalog
omni tv ID settings list [system|secure|global]
omni tv ID settings get NAMESPACE KEY
omni tv ID settings set NAMESPACE KEY VALUE
omni tv ID settings delete NAMESPACE KEY
omni tv ID files ls PATH
omni tv ID files stat PATH
omni tv ID files get PATH LOCAL [--overwrite]
omni tv ID files put LOCAL PATH [--overwrite]
omni tv ID files cp|mv FROM TO [--overwrite]
omni tv ID files rm PATH... [-r]
omni tv ID files mkdir PATH
omni tv ID files rename PATH NAME
omni tv ID screenshot [--out FILE.png]
omni tv ID helper status|install APK    (the pointer helper)
omni tv ID pointer show|hide|click
omni tv ID pointer to X Y|by DX DY      (fractions of the screen)
omni tv ID tap X Y                     (fractions of the screen, 0 to 1)
omni tv ID swipe X1 Y1 X2 Y2 [--ms N]
omni tv ID record start [--seconds N] [--bit-rate MBPS]
omni tv ID record stop|status
omni tv ID system
omni tv ID processes
omni tv ID permissions PACKAGE
omni tv ID permission PACKAGE PERMISSION --grant|--revoke
omni tv ID backup PACKAGE --to DIR [--overwrite]
omni tv ID trim-caches [--yes]
omni tv ID power reboot|shutdown [--yes]
omni tv ID shell [COMMAND...]   (no COMMAND: an interactive shell)''';

/// Flags the `omni tv` verbs take, wherever they appear before `shell`.
const _flags = {
  '--long',
  '--launchable',
  '--replace',
  '--overwrite',
  '-r',
  '--grant',
  '--revoke',
  '--yes',
};
const _options = {
  '--repeat',
  '--filter',
  '--timeout-ms',
  '--out',
  '--ms',
  '--to',
  '--seconds',
  '--bit-rate',
};

/// `omni tv ID VERB ...`: the remote, apps, settings, files and shell of an
/// Android TV. Each verb sends one `tv.*` command.
class TvCommand extends Command<int> {
  @override
  String get name => 'tv';

  @override
  List<String> get aliases => const ['android'];

  @override
  String get description =>
      'Control an Android TV: remote, text, volume, state, apps, settings, files, '
      'shell, screen, recording, system, permissions, backup and power.';

  @override
  String get invocation => _tvUsage;

  @override
  final ArgParser argParser = ArgParser.allowAnything();

  OmniCommandRunner get omni => runner! as OmniCommandRunner;

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length < 2) throw UsageException('needs ID and a verb', usage);
    final id = rest[0];
    final verb = rest[1];
    if (verb == 'shell') return runTvShell(omni, id, rest.sublist(2));
    final words = <String>[];
    final flags = <String>{};
    final options = <String, String>{};
    for (var i = 2; i < rest.length; i++) {
      final w = rest[i];
      if (_flags.contains(w)) {
        flags.add(w);
      } else if (_options.contains(w)) {
        if (i + 1 >= rest.length) {
          throw UsageException('$w needs a value', usage);
        }
        options[w] = rest[++i];
      } else {
        words.add(w);
      }
    }
    final (command, args) = _request(id, verb, words, flags, options);
    final ask = switch (command) {
      'tv.power' when args['action'] == 'reboot' => 'Restart $id?',
      'tv.power' => 'Shut down $id?',
      'tv.cache.trim' => 'Clear the cache of every app on $id?',
      _ => null,
    };
    if (ask != null && !flags.contains('--yes') && !await _confirm(ask)) {
      omni.out.writeln('Nothing was changed');
      return 1;
    }
    final out = options['--out'];
    if (command == 'tv.screenshot' && out != null) {
      return _screenshotTo(omni, args, File(out).absolute);
    }
    return _send(omni, command, args, progress: _transfers.contains(command));
  }

  Future<bool> _confirm(String question) async {
    omni.out.write('$question [y/N] ');
    try {
      final answer = await const LineSplitter()
          .bind(utf8.decoder.bind(omni.input))
          .first;
      return const {'y', 'yes'}.contains(answer.trim().toLowerCase());
    } on StateError {
      return false;
    }
  }

  static const _transfers = {
    'tv.install',
    'tv.files.download',
    'tv.files.upload',
    'tv.app.backup',
  };

  (String, Map<String, Object?>) _request(
    String id,
    String verb,
    List<String> words,
    Set<String> flags,
    Map<String, String> options,
  ) {
    String one(String what) {
      if (words.length != 1) throw UsageException('needs $what', usage);
      return words.single;
    }

    (String, String) two(String a, String b) {
      if (words.length != 2) throw UsageException('needs $a and $b', usage);
      return (words[0], words[1]);
    }

    final overwrite = {if (flags.contains('--overwrite')) 'overwrite': true};
    switch (verb) {
      case 'remote':
        final repeat = options['--repeat'];
        return (
          'tv.key',
          {
            'id': id,
            'key': one('KEY'),
            if (flags.contains('--long')) 'longPress': true,
            if (repeat != null) 'repeat': int.tryParse(repeat) ?? repeat,
          },
        );
      case 'keys':
        return ('tv.keys', {'id': id});
      case 'text':
        if (words.isEmpty) throw UsageException('needs TEXT', usage);
        return ('tv.text', {'id': id, 'text': words.join(' ')});
      case 'volume':
        final level = one('N');
        return ('tv.volume', {'id': id, 'level': num.tryParse(level) ?? level});
      case 'state':
        return ('tv.state', {'id': id});
      case 'apps':
        return _apps(id, words, flags, options);
      case 'settings':
        return _settings(id, words);
      case 'files':
        if (words.isEmpty) throw UsageException('needs a files verb', usage);
        final sub = words.removeAt(0);
        return switch (sub) {
          'ls' => ('tv.files.list', {'id': id, 'path': one('PATH')}),
          'stat' => ('tv.files.stat', {'id': id, 'path': one('PATH')}),
          'get' => () {
            final (path, to) = two('PATH', 'LOCAL');
            return (
              'tv.files.download',
              {
                'id': id,
                'path': path,
                'to': File(to).absolute.path,
                ...overwrite,
              },
            );
          }(),
          'put' => () {
            final (from, path) = two('LOCAL', 'PATH');
            return (
              'tv.files.upload',
              {
                'id': id,
                'from': File(from).absolute.path,
                'path': path,
                ...overwrite,
              },
            );
          }(),
          'cp' || 'mv' => () {
            final (from, to) = two('FROM', 'TO');
            return (
              sub == 'cp' ? 'tv.files.copy' : 'tv.files.move',
              {'id': id, 'from': from, 'to': to, ...overwrite},
            );
          }(),
          'rm' => () {
            if (words.isEmpty) throw UsageException('needs PATH', usage);
            return (
              'tv.files.delete',
              {
                'id': id,
                'paths': words,
                if (flags.contains('-r')) 'recursive': true,
              },
            );
          }(),
          'mkdir' => ('tv.files.mkdir', {'id': id, 'path': one('PATH')}),
          'rename' => () {
            final (path, name) = two('PATH', 'NAME');
            return ('tv.files.rename', {'id': id, 'path': path, 'name': name});
          }(),
          _ => throw UsageException('unknown files verb $sub', usage),
        };
      case 'helper':
        if (words.isEmpty) {
          throw UsageException('needs status or install', usage);
        }
        final sub = words.removeAt(0);
        return switch (sub) {
          'status' => ('tv.helper.status', {'id': id}),
          'install' => (
            'tv.helper.install',
            {'id': id, 'path': File(one('APK')).absolute.path},
          ),
          _ => throw UsageException('unknown helper verb $sub', usage),
        };
      case 'pointer':
        if (words.isEmpty) throw UsageException('needs a pointer verb', usage);
        final sub = words.removeAt(0);
        return switch (sub) {
          'show' => ('tv.pointer', {'id': id, 'show': true}),
          'hide' => ('tv.pointer', {'id': id, 'hide': true}),
          'click' => ('tv.pointer.click', {'id': id}),
          'to' || 'by' => () {
            final (x, y) = two('X', 'Y');
            return (
              'tv.pointer',
              {
                'id': id,
                sub: [_number(x), _number(y)],
              },
            );
          }(),
          _ => throw UsageException('unknown pointer verb $sub', usage),
        };
      case 'screenshot':
        if (words.isNotEmpty) throw UsageException('takes no words', usage);
        return ('tv.screenshot', {'id': id});
      case 'tap':
        final (x, y) = two('X', 'Y');
        return ('tv.input.tap', {'id': id, 'x': _number(x), 'y': _number(y)});
      case 'swipe':
        if (words.length != 4) {
          throw UsageException('needs X1 Y1 X2 Y2', usage);
        }
        final ms = options['--ms'];
        return (
          'tv.input.swipe',
          {
            'id': id,
            'x1': _number(words[0]),
            'y1': _number(words[1]),
            'x2': _number(words[2]),
            'y2': _number(words[3]),
            if (ms != null) 'ms': _number(ms),
          },
        );
      case 'record':
        final sub = one('start, stop or status');
        if (sub == 'start') {
          final seconds = options['--seconds'];
          final bitRate = options['--bit-rate'];
          return (
            'tv.record.start',
            {
              'id': id,
              if (seconds != null) 'seconds': _number(seconds),
              if (bitRate != null) 'bitRate': _number(bitRate),
            },
          );
        }
        if (sub != 'stop' && sub != 'status') {
          throw UsageException('record is start, stop or status', usage);
        }
        return ('tv.record.$sub', {'id': id});
      case 'system':
        return ('tv.system', {'id': id});
      case 'processes':
        return ('tv.processes', {'id': id});
      case 'permissions':
        return ('tv.app.permissions', {'id': id, 'package': one('PACKAGE')});
      case 'permission':
        final (package, permission) = two('PACKAGE', 'PERMISSION');
        final grant = flags.contains('--grant');
        if (grant == flags.contains('--revoke')) {
          throw UsageException('needs one of --grant or --revoke', usage);
        }
        return (
          'tv.app.permission',
          {
            'id': id,
            'package': package,
            'permission': permission,
            'grant': grant,
          },
        );
      case 'backup':
        final to = options['--to'];
        if (to == null) throw UsageException('needs --to DIR', usage);
        return (
          'tv.app.backup',
          {
            'id': id,
            'package': one('PACKAGE'),
            'to': File(to).absolute.path,
            ...overwrite,
          },
        );
      case 'trim-caches':
        if (words.isNotEmpty) throw UsageException('takes no words', usage);
        return ('tv.cache.trim', {'id': id});
      case 'power':
        final action = one('reboot or shutdown');
        if (action != 'reboot' && action != 'shutdown') {
          throw UsageException('power is reboot or shutdown', usage);
        }
        return ('tv.power', {'id': id, 'action': action});
      default:
        throw UsageException('unknown verb $verb', usage);
    }
  }

  (String, Map<String, Object?>) _apps(
    String id,
    List<String> words,
    Set<String> flags,
    Map<String, String> options,
  ) {
    final sub = words.isEmpty ? 'list' : words.first;
    if (sub == 'list') {
      return (
        'tv.apps',
        {
          'id': id,
          if (options['--filter'] != null) 'filter': options['--filter'],
          if (flags.contains('--launchable')) 'launchableOnly': true,
        },
      );
    }
    if (words.length != 2) throw UsageException('needs PACKAGE', usage);
    if (sub == 'install') {
      return (
        'tv.install',
        {
          'id': id,
          'path': File(words[1]).absolute.path,
          if (flags.contains('--replace')) 'replace': true,
        },
      );
    }
    const actions = {
      'open': 'open',
      'stop': 'stop',
      'info': 'info',
      'clear-cache': 'clear_cache',
      'clear-data': 'clear_data',
      'disable': 'disable',
      'enable': 'enable',
      'uninstall': 'uninstall',
    };
    final action = actions[sub];
    if (action == null) throw UsageException('unknown apps verb $sub', usage);
    return ('tv.app', {'id': id, 'package': words[1], 'action': action});
  }

  (String, Map<String, Object?>) _settings(String id, List<String> words) {
    final sub = words.isEmpty ? 'catalog' : words.first;
    final rest = words.skip(1).toList();
    switch (sub) {
      case 'catalog':
        return ('tv.settings.catalog', {'id': id});
      case 'list':
        return (
          'tv.settings.list',
          {'id': id, if (rest.isNotEmpty) 'namespace': rest.first},
        );
      case 'get' || 'delete':
        if (rest.length != 2) {
          throw UsageException('needs NAMESPACE KEY', usage);
        }
        return (
          sub == 'get' ? 'tv.settings.get' : 'tv.settings.delete',
          {'id': id, 'namespace': rest[0], 'key': rest[1]},
        );
      case 'set':
        if (rest.length < 3) {
          throw UsageException('needs NAMESPACE KEY VALUE', usage);
        }
        return (
          'tv.settings.put',
          {
            'id': id,
            'namespace': rest[0],
            'key': rest[1],
            'value': rest.skip(2).join(' '),
          },
        );
      default:
        throw UsageException('unknown settings verb $sub', usage);
    }
  }
}

/// A number as typed, or the text itself, so the engine says what is wrong
/// with it.
Object _number(String word) => num.tryParse(word) ?? word;

/// Saves the screenshot to [file] and prints the result without the image.
Future<int> _screenshotTo(
  OmniCommandRunner omni,
  Map<String, Object?> args,
  File file,
) async {
  final engine = await omni.connect();
  try {
    final result = await engine.handle('tv.screenshot', args);
    if (result['ok'] != true) {
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return 1;
    }
    await file.writeAsBytes(base64Decode(result['png'] as String));
    omni.out.writeln(
      const JsonEncoder.withIndent('  ').convert({
        for (final e in result.entries)
          if (e.key != 'png') e.key: e.value,
        'out': file.path,
      }),
    );
    return 0;
  } finally {
    await engine.close();
  }
}

/// `omni device shell ID [COMMAND...]`, the same as `omni tv ID shell`.
class DeviceShellCommand extends Command<int> {
  @override
  String get name => 'shell';

  @override
  String get description =>
      'Run a shell command on an Android TV, or with no command an '
      'interactive shell: omni device shell tv ls /sdcard';

  @override
  String get invocation => 'omni device shell ID [COMMAND...]';

  @override
  final ArgParser argParser = ArgParser.allowAnything();

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw UsageException('needs ID', usage);
    return runTvShell(
      runner! as OmniCommandRunner,
      rest.first,
      rest.sublist(1),
    );
  }
}

Future<int> _send(
  OmniCommandRunner omni,
  String command,
  Map<String, Object?> args, {
  bool progress = false,
}) async {
  final engine = await omni.connect();
  StreamSubscription<Map<String, Object?>>? sub;
  try {
    if (progress) {
      sub = (await engine.events()).listen((e) {
        if (e['event'] == 'tv.progress' && e['id'] == args['id']) {
          final total = e['total'];
          stderr.write(
            '\r${e['op']}: ${e['done']}${total == null ? '' : ' of $total'} bytes',
          );
          if (e['done'] == total) stderr.writeln();
        }
      });
    }
    final result = await engine.handle(command, args);
    omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
    return result['ok'] == true ? 0 : 1;
  } finally {
    await sub?.cancel();
    await closeOneShot(engine);
  }
}

/// Runs one shell command, or, with none, reads lines from the CLI input
/// and runs each, keeping the folder a `cd` moved to. `exit` or the end of
/// input ends it.
Future<int> runTvShell(
  OmniCommandRunner omni,
  String id,
  List<String> command,
) async {
  final engine = await omni.connect();
  try {
    if (command.isNotEmpty) {
      final result = await engine.handle('tv.shell', {
        'id': id,
        'command': command.join(' '),
      });
      return _printShell(omni, result);
    }
    return await _interactive(omni, engine, id);
  } finally {
    await engine.close();
  }
}

int _printShell(OmniCommandRunner omni, Map<String, Object?> result) {
  if (result['ok'] != true) {
    omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
    return 1;
  }
  final output = result['output'] as String;
  omni.out.write(output);
  if (output.isNotEmpty && !output.endsWith('\n')) omni.out.writeln();
  final code = result['exitCode'];
  return code is int ? code.clamp(0, 255) : 0;
}

Future<int> _interactive(
  OmniCommandRunner omni,
  EngineConnection engine,
  String id,
) async {
  String? cwd;
  var last = 0;
  void prompt() => omni.out.write('$id:${cwd ?? '/'} \$ ');
  final first = await engine.handle('tv.shell', {'id': id, 'command': 'true'});
  if (first['ok'] != true) return _printShell(omni, first);
  cwd = first['cwd'] as String?;
  prompt();
  await for (final line in const LineSplitter().bind(
    utf8.decoder.bind(omni.input),
  )) {
    final text = line.trim();
    if (text == 'exit' || text == 'logout') break;
    if (text.isNotEmpty) {
      final result = await engine.handle('tv.shell', {
        'id': id,
        'command': text,
        'cwd': ?cwd,
      });
      last = _printShell(omni, result);
      if (result['ok'] == true && result['cwd'] is String) {
        cwd = result['cwd'] as String;
      }
    }
    prompt();
  }
  omni.out.writeln();
  return last;
}
