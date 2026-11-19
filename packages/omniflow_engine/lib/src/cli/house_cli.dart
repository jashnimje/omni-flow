import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'omni_command_runner.dart';

typedef _Build = Map<String, Object?> Function(ArgResults a);

class _Verb extends Command<int> {
  _Verb(
    this.name,
    this.description,
    this.apiCommand,
    this._build, {
    this.usageLine = '',
    void Function(ArgParser)? options,
  }) {
    options?.call(argParser);
  }

  @override
  final String name;
  @override
  final String description;
  final String apiCommand;
  final _Build _build;
  final String usageLine;

  @override
  String get invocation =>
      '${super.invocation.replaceFirst(' [arguments]', '')} $usageLine'
          .trimRight();

  @override
  Future<int> run() async {
    final args = _build(argResults!);
    final omni = runner! as OmniCommandRunner;
    final engine = await omni.connect();
    try {
      final result = await engine.handle(apiCommand, args);
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return result['ok'] == true ? 0 : 1;
    } finally {
      await engine.close();
    }
  }
}

class _Group extends Command<int> {
  _Group(this.name, this.description, List<Command<int>> verbs) {
    verbs.forEach(addSubcommand);
  }

  @override
  final String name;
  @override
  final String description;
}

String _name(ArgResults a) {
  if (a.rest.isEmpty) throw UsageException('needs NAME', '');
  return a.rest.join(' ');
}

/// `20m`, `90s`, `1h` or plain milliseconds.
int _duration(String text) {
  final m = RegExp(r'^(\d+)\s*(ms|s|m|min|h)?$').firstMatch(text.trim());
  if (m == null) {
    throw UsageException('$text is not a time like 20m, 90s or 1h', '');
  }
  final n = int.parse(m[1]!);
  return switch (m[2]) {
    's' => n * 1000,
    'm' || 'min' => n * 60000,
    'h' => n * 3600000,
    _ => n,
  };
}

bool? _onOff(String? text, String name) => switch (text) {
  null => null,
  'on' => true,
  'off' => false,
  _ => throw UsageException('--$name takes on or off', ''),
};

/// `omni mode`: the house mode.
Command<int> modeCommand() => _Group('mode', 'The house mode.', [
  _Verb('show', 'Show the mode and every mode.', 'home.mode', (_) => {}),
  _Verb(
    'set',
    'Set the mode: omni mode set night',
    'home.mode.set',
    (a) => {'mode': _name(a)},
    usageLine: 'MODE',
  ),
  _Verb(
    'modes',
    'Set your own modes beside the four built in: omni mode modes Guests '
        '"Movie night"',
    'home.mode.set',
    (a) => {'modes': a.rest},
    usageLine: 'NAME...',
  ),
  _Verb(
    'follow',
    'Whether the mode follows who is home: omni mode follow on',
    'home.mode.set',
    (a) => {'followPresence': _onOff(a.rest.firstOrNull, 'follow') ?? true},
    usageLine: 'on|off',
  ),
]);

/// `omni timer`: named timers.
Command<int> timerCommand() => _Group('timer', 'Named timers.', [
  _Verb('list', 'List running and paused timers.', 'timer.list', (_) => {}),
  _Verb(
    'start',
    'Start a timer: omni timer start Pasta --for 20m',
    'timer.start',
    (a) {
      final length = a.option('for');
      if (length == null) throw UsageException('needs --for', '');
      return {'name': _name(a), 'ms': _duration(length)};
    },
    usageLine: 'NAME --for TIME',
    options: (p) => p.addOption('for', help: 'How long: 20m, 90s, 1h.'),
  ),
  for (final (verb, what) in [
    ('cancel', 'Cancel'),
    ('pause', 'Pause'),
    ('resume', 'Resume'),
  ])
    _Verb(
      verb,
      '$what a timer.',
      'timer.$verb',
      (a) => {'name': _name(a)},
      usageLine: 'NAME',
    ),
]);

/// `omni alerts`: the built-in offline and low-battery alerts.
Command<int> alertsCommand() =>
    _Group('alerts', 'Offline and low-battery alerts.', [
      _Verb('show', 'Show which alerts are on.', 'alerts.get', (_) => {}),
      _Verb(
        'set',
        'Turn alerts on or off: omni alerts set --offline on',
        'alerts.set',
        (a) => {
          'offline': ?_onOff(a.option('offline'), 'offline'),
          'battery': ?_onOff(a.option('battery'), 'battery'),
        },
        usageLine: '[--offline on|off] [--battery on|off]',
        options: (p) => p
          ..addOption('offline', help: 'A device offline for 10 minutes.')
          ..addOption('battery', help: 'A battery under 15%.'),
      ),
    ]);

/// `omni room invoke` and `omni room state`.
List<Command<int>> roomHelperVerbs() => [
  _Verb(
    'invoke',
    'Send one capability to every device in a room: omni room invoke '
        'Living power \'{"value": false}\' --lights',
    'room.invoke',
    (a) {
      if (a.rest.length < 2 || a.rest.length > 3) {
        throw UsageException('needs ROOM CAPABILITY [PARAMS]', '');
      }
      Object? params;
      if (a.rest.length == 3) {
        try {
          params = jsonDecode(a.rest[2]);
        } on FormatException catch (e) {
          throw UsageException('PARAMS is not valid JSON: ${e.message}', '');
        }
      }
      return {
        'room': a.rest[0],
        'capability': a.rest[1],
        'params': ?params,
        if (a.flag('lights')) 'only': 'lights',
      };
    },
    usageLine: 'ROOM CAPABILITY [PARAMS] [--lights]',
    options: (p) => p.addFlag('lights', help: 'Only the lights in the room.'),
  ),
  _Verb(
    'state',
    'How a room\'s lights are: omni room state Living',
    'room.state',
    (a) => {'room': _name(a)},
    usageLine: 'ROOM',
  ),
];

/// `omni scene capture`.
Command<int> sceneCaptureVerb() => _Verb(
  'capture',
  'Save how things are now as a scene: omni scene capture Evening '
      '--room Living, or --device lamp --device tv',
  'scene.capture',
  (a) {
    final devices = a.multiOption('device');
    final room = a.option('room');
    return {
      'name': _name(a),
      if (devices.isNotEmpty) 'devices': devices,
      'room': ?room,
    };
  },
  usageLine: 'NAME (--room ROOM | --device ID...)',
  options: (p) => p
    ..addOption('room', help: 'Every device in this room.')
    ..addMultiOption('device', help: 'A device to include.'),
);
