import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'omni_command_runner.dart';
import 'one_shot.dart';

/// The verbs that give the CLI every home helper the app has: energy,
/// weather, sun and away lighting, flashing a board, and the automation
/// verbs the app's editor and list use. Each sends one core API command,
/// as the app does.

typedef _Build = Map<String, Object?> Function(ArgResults a);

class _Verb extends Command<int> {
  _Verb(
    this.name,
    this.description,
    this.apiCommand,
    this._build, {
    this.usageLine = '',
    void Function(ArgParser)? options,
    this.route,
  }) {
    options?.call(argParser);
  }

  /// Picks another command from the words given, or null for [apiCommand].
  final (String, Map<String, Object?>)? Function(ArgResults a)? route;

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

  OmniCommandRunner get omni => runner! as OmniCommandRunner;

  @override
  Future<int> run() async {
    final routed = route?.call(argResults!);
    final args = routed?.$2 ?? _build(argResults!);
    final engine = await omni.connect();
    try {
      final result = await engine.handle(routed?.$1 ?? apiCommand, args);
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return result['ok'] == true ? 0 : 1;
    } finally {
      await closeOneShot(engine);
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

String _one(ArgResults a, String what) {
  if (a.rest.length != 1) throw UsageException('needs $what', '');
  return a.rest.single;
}

int? _int(String? text, String option) {
  if (text == null) return null;
  return int.tryParse(text) ??
      (throw UsageException('--$option takes a whole number', ''));
}

/// `on` or `off` for an `--on` / `--off` pair, or null for neither.
bool? _onOff(ArgResults a) {
  if (a.flag('on') && a.flag('off')) {
    throw UsageException('give --on or --off, not both', '');
  }
  return a.flag('on') ? true : (a.flag('off') ? false : null);
}

void _onOffOptions(ArgParser p, String what) => p
  ..addFlag('on', negatable: false, help: 'Turn $what on.')
  ..addFlag('off', negatable: false, help: 'Turn $what off.');

/// `omni energy`: what the plugs that report power used, and the price.
Command<int> energyCommand() =>
    _Group('energy', 'What the plugs that report power used, and its cost.', [
      _Verb(
        'summary',
        'Watts now, today\'s kWh and the last days\' kWh per plug: '
            'omni energy summary --days 7',
        'energy.summary',
        (a) => {'days': ?_int(a.option('days'), 'days')},
        usageLine: '[--days N]',
        options: (p) => p.addOption('days', help: '1 to 31, 7 by default.'),
      ),
      _Verb(
        'price',
        'Show the price of one kWh, or set it: omni energy price 8.5 Rs. '
            'omni energy price --clear takes it away.',
        'energy.price',
        (a) => const {},
        usageLine: '[PER_KWH [CURRENCY]] [--clear]',
        options: (p) =>
            p.addFlag('clear', negatable: false, help: 'Take the price away.'),
        route: _priceSet,
      ),
    ]);

/// `energy.price` with no words reads the price. With a number, or
/// `--clear`, it is `energy.price.set`.
(String, Map<String, Object?>)? _priceSet(ArgResults a) {
  if (a.flag('clear')) return ('energy.price.set', {'perKwh': null});
  if (a.rest.isEmpty) return null;
  if (a.rest.length > 2) throw UsageException('needs PER_KWH [CURRENCY]', '');
  final perKwh =
      num.tryParse(a.rest.first) ??
      (throw UsageException('${a.rest.first} is not a price', ''));
  return (
    'energy.price.set',
    {'perKwh': perKwh, if (a.rest.length == 2) 'currency': a.rest[1]},
  );
}

/// `omni weather`: the weather at home as a thing.
Command<int> weatherCommand() => _Group('weather', 'The weather at home.', [
  _Verb(
    'add',
    'Add the weather at home as a thing, then read it: omni weather add '
        '--room Garden. Home must be set first with omni home location set.',
    'weather.add',
    (a) => {
      if (a.rest.isNotEmpty) 'name': a.rest.join(' '),
      'room': ?a.option('room'),
    },
    usageLine: '[NAME] [--room ROOM]',
    options: (p) => p.addOption('room', help: 'The room to put it in.'),
  ),
  _Verb(
    'refresh',
    'Ask for the weather now, for one weather thing or all of them.',
    'weather.refresh',
    (a) => {if (a.rest.isNotEmpty) 'id': _one(a, 'ID')},
    usageLine: '[ID]',
  ),
]);

/// `omni sunlight`: lights that follow the sun's colour through the day.
Command<int> sunlightCommand() => _Group(
  'sunlight',
  'Lights that follow the sun: warm in the evening, cool at noon.',
  [
    _Verb(
      'get',
      'Every light or room that follows the sun, which are paused, and '
          'today\'s curve: omni sunlight get [TARGET]',
      'sunlight.get',
      (a) => {if (a.rest.isNotEmpty) 'target': _one(a, 'TARGET')},
      usageLine: '[TARGET]',
    ),
    _Verb(
      'set',
      'Pick the lights or rooms that follow the sun: omni sunlight set desk '
          'living --on --min-k 2400 --max-k 5000',
      'sunlight.set',
      (a) {
        final on = _onOff(a);
        if (a.rest.isEmpty || on == null) {
          throw UsageException('needs TARGET... and --on or --off', '');
        }
        return {
          'targets': a.rest,
          'enabled': on,
          'minK': ?_int(a.option('min-k'), 'min-k'),
          'maxK': ?_int(a.option('max-k'), 'max-k'),
          'minBrightness': ?_int(a.option('min-brightness'), 'min-brightness'),
          'maxBrightness': ?_int(a.option('max-brightness'), 'max-brightness'),
        };
      },
      usageLine: 'TARGET... --on|--off [--min-k K] [--max-k K]',
      options: (p) {
        _onOffOptions(p, 'following the sun');
        p
          ..addOption('min-k', help: 'The warmest white, in kelvin.')
          ..addOption('max-k', help: 'The coolest white, in kelvin.')
          ..addOption('min-brightness', help: 'The dimmest, in %.')
          ..addOption('max-brightness', help: 'The brightest, in %.');
      },
    ),
    _Verb(
      'apply',
      'Bring every followed light that is on to the curve now.',
      'sunlight.apply',
      (a) => const {},
    ),
  ],
);

/// `omni away`: away lighting, which replays last week's lights while
/// everyone is away.
Command<int> awayCommand() => _Group(
  'away',
  'Away lighting: while everyone is away, the picked lights go on and off '
      'as they did a week before.',
  [
    _Verb(
      'get',
      'Whether away lighting is on, its lights, and whether it runs now.',
      'awaylight.get',
      (a) => const {},
    ),
    _Verb(
      'set',
      'Pick the lights and turn it on: omni away set desk hall --on',
      'awaylight.set',
      (a) {
        final on = _onOff(a);
        return {if (a.rest.isNotEmpty) 'lights': a.rest, 'enabled': ?on};
      },
      usageLine: '[LIGHT...] [--on|--off]',
      options: (p) => _onOffOptions(p, 'away lighting'),
    ),
    _Verb(
      'preview',
      'What away lighting would do on a day: omni away preview 2026-11-20',
      'awaylight.preview',
      (a) => {if (a.rest.isNotEmpty) 'date': _one(a, 'DATE')},
      usageLine: '[YYYY-MM-DD]',
    ),
  ],
);

/// `omni board ports` and `omni board flash`.
List<Command<int>> boardFlashVerbs() => [
  _Verb(
    'ports',
    'The serial ports a board can be set up or flashed on.',
    'board.ports',
    (a) => const {},
  ),
  _Verb(
    'flash',
    'Write firmware to a board on this engine\'s USB, then start it: omni '
        'board flash PORT --chip esp32 --file node.bin. Only a phone\'s own USB '
        'can be flashed. On a computer use arduino-cli.',
    'board.flash',
    (a) {
      final chip = a.option('chip');
      final file = a.option('file');
      if (chip == null || file == null) {
        throw UsageException('needs --chip and --file', '');
      }
      return {
        'port': _one(a, 'PORT'),
        'chip': chip,
        'file': file,
        'offset': ?_int(a.option('offset'), 'offset'),
      };
    },
    usageLine: 'PORT --chip esp32|esp8266|uno --file FILE [--offset N]',
    options: (p) => p
      ..addOption(
        'chip',
        allowed: ['esp32', 'esp8266', 'uno'],
        help: 'The board\'s chip.',
      )
      ..addOption('file', help: 'A .bin for ESP chips, an Intel .hex for Uno.')
      ..addOption('offset', help: 'Where an ESP image starts, 0 by default.'),
  ),
];

/// The verbs `omni automation` adds beyond list and templates: everything
/// the app's list and editor do to one automation.
List<Command<int>> automationVerbs() => [
  _Verb(
    'get',
    'Show one automation as it was written, with the flow it runs as.',
    'automation.get',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  _Verb(
    'run',
    'Run it now, as the app\'s Run it now does: its manual trigger, or its '
        'first trigger as if that fired.',
    'automation.run',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  for (final (verb, on) in [('enable', true), ('disable', false)])
    _Verb(
      verb,
      on ? 'Turn an automation on.' : 'Turn an automation off.',
      'automation.enable',
      (a) => {'id': _one(a, 'ID'), 'enabled': on},
      usageLine: 'ID',
    ),
  _Verb(
    'approve',
    'Approve an automation an agent made, or a high-risk one that waits.',
    'automation.approve',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  _Verb(
    'log',
    'Its last runs: omni automation log ID --limit 5',
    'automation.log',
    (a) => {'id': _one(a, 'ID'), 'limit': ?_int(a.option('limit'), 'limit')},
    usageLine: 'ID [--limit N]',
    options: (p) => p.addOption('limit', help: 'How many runs, 20 by default.'),
  ),
  _Verb(
    'remove',
    'Remove an automation. It can be put back for 30 days with unremove.',
    'automation.remove',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  _Verb(
    'removed',
    'Automations removed in the last 30 days.',
    'automation.removed',
    (a) => const {},
  ),
  _Verb(
    'unremove',
    'Put a removed automation back as it was, with its versions.',
    'automation.unremove',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  _Verb(
    'versions',
    'The last saved versions of an automation.',
    'automation.versions',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  _Verb(
    'restore',
    'Go back to a saved version: omni automation restore ID 3',
    'automation.restore',
    (a) {
      final version = a.rest.length == 2 ? int.tryParse(a.rest[1]) : null;
      if (version == null) throw UsageException('needs ID VERSION', '');
      return {'id': a.rest[0], 'version': version, 'trusted': true};
    },
    usageLine: 'ID VERSION',
  ),
  _Verb(
    'why-not',
    'The triggers that fired lately without a run, and why.',
    'automation.skips',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  _Diagram(),
];

/// `omni automation diagram ID [--run last|RUN] [--json]`: the diagram the
/// app draws, as an indented tree, with a run's path marked.
class _Diagram extends Command<int> {
  _Diagram() {
    argParser
      ..addOption(
        'run',
        help: 'Mark the path a run took: last, or a run id from the log.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Print the nodes and edges as JSON instead.',
      );
  }

  @override
  String get name => 'diagram';

  @override
  String get description =>
      'The automation as the app draws it, as an indented tree: omni '
      'automation diagram ID --run last';

  @override
  String get invocation => 'omni automation diagram ID [--run last|RUN]';

  OmniCommandRunner get omni => runner! as OmniCommandRunner;

  @override
  Future<int> run() async {
    final a = argResults!;
    final run = a.option('run');
    final args = {
      'id': _one(a, 'ID'),
      if (run == 'last') 'last': true else 'run': ?run,
    };
    final engine = await omni.connect();
    try {
      final result = await engine.handle('automation.diagram', args);
      if (result['ok'] != true || a.flag('json')) {
        omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
        return result['ok'] == true ? 0 : 1;
      }
      omni.out.write(diagramTree(result));
      return 0;
    } finally {
      await closeOneShot(engine);
    }
  }
}

/// A diagram as an indented tree, one node per line: each edge's label
/// before the node it leads to, a run's mark after it, and a node reached a
/// second time written once more with "(as above)".
String diagramTree(Map<String, Object?> diagram) {
  final nodes = <String, Map>{
    for (final n in (diagram['nodes'] as List? ?? const []).whereType<Map>())
      '${n['id']}': n,
  };
  final out = <String, List<Map>>{};
  final into = <String>{};
  for (final e in (diagram['edges'] as List? ?? const []).whereType<Map>()) {
    out.putIfAbsent('${e['from']}', () => []).add(e);
    into.add('${e['to']}');
  }
  final buffer = StringBuffer();
  final seen = <String>{};
  void write(String id, int depth, String? label) {
    final n = nodes[id];
    if (n == null) return;
    final mark = switch (n['status']) {
      'ran' => '  [ran]',
      'failed' => '  [failed]',
      'skipped' => '  [skipped]',
      final Object s => '  [$s]',
      null => '',
    };
    final edge = label == null ? '' : '$label: ';
    final again = seen.contains(id);
    buffer.writeln(
      '${'  ' * depth}$edge${n['words'] ?? id}$mark${again ? '  (as above)' : ''}',
    );
    if (again) return;
    seen.add(id);
    for (final e in out[id] ?? const <Map>[]) {
      final taken = e['taken'] == true ? ' (taken)' : '';
      final word = e['label'] == null ? null : '${e['label']}$taken';
      write('${e['to']}', depth + 1, word ?? (taken.isEmpty ? null : 'taken'));
    }
  }

  for (final id in nodes.keys.where((id) => !into.contains(id))) {
    write(id, 0, null);
  }
  for (final id in nodes.keys.where((id) => !seen.contains(id))) {
    write(id, 0, null);
  }
  return buffer.toString();
}

/// `omni device move ID HOST [--port N]`: a device found again at a new
/// address keeps its name, room, settings and automations.
Command<int> deviceMoveVerb() => _Verb(
  'move',
  'Point a device at its new address, keeping its name, room and '
      'automations: omni device move lamp 192.168.1.40',
  'device.move',
  (a) {
    if (a.rest.length != 2) throw UsageException('needs ID HOST', '');
    return {
      'id': a.rest[0],
      'host': a.rest[1],
      'port': ?_int(a.option('port'), 'port'),
    };
  },
  usageLine: 'ID HOST [--port N]',
  options: (p) => p.addOption('port', help: 'Its port, when not the default.'),
);
