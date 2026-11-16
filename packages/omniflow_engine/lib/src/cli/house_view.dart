import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../api/houses.dart' show houseListKeys, houseViewCommands;
import '../api/local_client.dart';
import 'omni_command_runner.dart';

/// Where `omni house use` keeps the CLI's own house, in the CLI's home.
/// It is this CLI's view only: the app and other CLIs keep their own.
File cliHouseFile(Directory home) => File('${home.path}/cli_house.json');

/// The house `omni house use` chose, or null.
String? readCliHouse(Directory home) {
  try {
    final json = jsonDecode(cliHouseFile(home).readAsStringSync());
    final house = json is Map ? json['house'] : null;
    return house is String && house.isNotEmpty ? house : null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

void writeCliHouse(Directory home, String? house) {
  final file = cliHouseFile(home);
  if (house == null) {
    if (file.existsSync()) file.deleteSync();
    return;
  }
  home.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode({'house': house}));
}

/// The engine as the CLI sends to it: a list or create command with no
/// `house` gets the CLI's house, from `--house`, else `omni house use`.
/// With neither, a list lists every house, and a command that makes
/// something goes to the only house, or is refused with the houses to pick
/// from when there are several.
/// [connection] without the house view, to ask what it is underneath.
EngineConnection withoutHouseView(EngineConnection connection) =>
    connection is HouseViewConnection ? connection.inner : connection;

class HouseViewConnection implements EngineConnection {
  HouseViewConnection(this._inner, {this.house});

  final EngineConnection _inner;

  /// The connection under the house view.
  EngineConnection get inner => _inner;

  /// The CLI's house, or null when it has none.
  final String? house;

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) async {
    if (!houseViewCommands.contains(command) || args.containsKey('house')) {
      return _inner.handle(command, args);
    }
    final chosen = house;
    if (chosen != null) {
      return _inner.handle(command, {...args, 'house': chosen});
    }
    if (houseListKeys.contains(command) || !_makes(command)) {
      return _inner.handle(command, args);
    }
    final listed = await _inner.handle('house.list', const {});
    final houses = [
      for (final h in (listed['houses'] as List? ?? const []))
        if (h is Map) h,
    ];
    if (houses.length <= 1) return _inner.handle(command, args);
    return {
      'ok': false,
      'error': {
        'type': 'invalid',
        'message':
            'There are ${houses.length} houses: '
            '${houses.map((h) => '${h['name']} (${h['id']})').join(', ')}. '
            'Say which with --house ID, or pick one for this CLI with '
            'omni house use ID',
      },
    };
  }

  /// The view commands that make or change something in a house.
  static bool _makes(String command) => const {
    'automation.save',
    'flow.save',
    'scene.save',
    'scene.capture',
    'link.create',
    'var.set',
    'timer.start',
    'device.add',
    'thing.add',
    'room.save',
    'zone.save',
    'tag.save',
    'weather.add',
    'home.mode.set',
    'home.location.set',
    'alerts.set',
    'energy.price.set',
    'awaylight.set',
    'sunlight.set',
  }.contains(command);

  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) =>
      _inner.events(packets: packets);

  @override
  Future<void> close() => _inner.close();
}

class _HouseVerb extends Command<int> {
  _HouseVerb(
    this.name,
    this.description,
    this._build, {
    this.usageLine = '',
    bool clearFlag = false,
  }) {
    if (clearFlag) {
      argParser.addFlag(
        'clear',
        negatable: false,
        help: 'Go back to no house of its own.',
      );
    }
  }

  @override
  final String name;
  @override
  final String description;
  final String usageLine;
  final Future<int> Function(OmniCommandRunner omni, List<String> rest) _build;

  @override
  String get invocation =>
      '${super.invocation.replaceFirst(' [arguments]', '')} $usageLine'
          .trimRight();

  @override
  Future<int> run() => _build(runner! as OmniCommandRunner, [
    if (argParser.options.containsKey('clear') && argResults!.flag('clear'))
      '--clear',
    ...argResults!.rest,
  ]);
}

Future<int> _send(
  OmniCommandRunner omni,
  String command,
  Map<String, Object?> args,
) async {
  final engine = await omni.connect();
  try {
    final result = await engine.handle(command, args);
    omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
    return result['ok'] == true ? 0 : 1;
  } finally {
    await engine.close();
  }
}

String _one(List<String> rest, String what) {
  if (rest.length != 1) throw UsageException('needs $what', '');
  return rest.single;
}

/// `omni house`: the houses a home is split into, and which one this CLI
/// works in.
Command<int> houseCommand() => _HouseGroup('house', 'Houses: one per home.', [
  _HouseVerb(
    'list',
    'List the houses, with how many things and automations each has.',
    (omni, _) => _send(omni, 'house.list', const {}),
  ),
  _HouseVerb(
    'add',
    'Add a house: omni house add Bangalore',
    (omni, rest) => _send(omni, 'house.add', {'name': rest.join(' ').trim()}),
    usageLine: 'NAME',
  ),
  _HouseVerb('rename', 'Rename a house: omni house rename home Mumbai', (
    omni,
    rest,
  ) {
    if (rest.length < 2) throw UsageException('needs ID and NAME', '');
    return _send(omni, 'house.rename', {
      'id': rest.first,
      'name': rest.skip(1).join(' '),
    });
  }, usageLine: 'ID NAME'),
  _HouseVerb(
    'remove',
    'Remove an empty house.',
    (omni, rest) => _send(omni, 'house.remove', {'id': _one(rest, 'ID')}),
    usageLine: 'ID',
  ),
  _HouseVerb(
    'use',
    'Work in one house from this CLI: lists show it and new things go in '
        'it. With no ID, says which; with --clear, goes back to none.',
    (omni, rest) async {
      if (rest.isEmpty || (rest.length > 1 && rest.first == '--clear')) {
        if (rest.isNotEmpty) throw UsageException('--clear takes no ID', '');
        final house = readCliHouse(omni.home);
        omni.out.writeln(
          const JsonEncoder.withIndent('  ')
              .convert({'ok': true, 'house': house}),
        );
        return 0;
      }
      if (rest.first == '--clear') {
        writeCliHouse(omni.home, null);
        omni.out.writeln(
          const JsonEncoder.withIndent('  ')
              .convert({'ok': true, 'house': null}),
        );
        return 0;
      }
      final engine = await omni.connect();
      try {
        final listed = await engine.handle('house.list', const {});
        final wanted = _one(rest, 'ID');
        final match = [
          for (final h in (listed['houses'] as List? ?? const []))
            if (h is Map &&
                (h['id'] == wanted ||
                    '${h['name']}'.toLowerCase() == wanted.toLowerCase()))
              h,
        ].firstOrNull;
        if (match == null) {
          omni.out.writeln(
            const JsonEncoder.withIndent('  ').convert({
              'ok': false,
              'error': {
                'type': 'not_found',
                'message': 'There is no house $wanted. See omni house list',
              },
            }),
          );
          return 1;
        }
        writeCliHouse(omni.home, '${match['id']}');
        omni.out.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({'ok': true, 'house': match['id'], 'name': match['name']}),
        );
        return 0;
      } finally {
        await engine.close();
      }
    },
    usageLine: '[ID] [--clear]',
    clearFlag: true,
  ),
]);

class _HouseGroup extends Command<int> {
  _HouseGroup(this.name, this.description, List<Command<int>> verbs) {
    verbs.forEach(addSubcommand);
  }

  @override
  final String name;
  @override
  final String description;
}
