import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'house_cli.dart';
import 'omni_command_runner.dart';
import 'parity_cli.dart' show automationVerbs;

typedef _Build = Map<String, Object?> Function(ArgResults a);

/// One verb that sends one core API command built from its arguments.
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

String _one(ArgResults a, String what) {
  if (a.rest.length != 1) throw UsageException('needs $what', '');
  return a.rest.single;
}

int? _intOption(ArgResults a, String name) {
  final raw = a.option(name);
  if (raw == null) return null;
  return int.tryParse(raw) ??
      (throw UsageException('--$name must be a whole number', ''));
}

/// A JSON object stays an object; anything else is shorthand for the engine.
Object? _item(String text) {
  final t = text.trim();
  if (!t.startsWith('{')) return text;
  try {
    return jsonDecode(t);
  } on FormatException catch (e) {
    throw UsageException('$t is not valid JSON: ${e.message}', '');
  }
}

/// `omni room`: the rooms devices are in, and their order.
Command<int> roomCommand() => _Group('room', 'Rooms and their order.', [
  _Verb(
    'list',
    'List rooms with how many devices each has.',
    'room.list',
    (_) => {},
  ),
  _Verb(
    'save',
    'Add a room, or rename or move one with --id: omni room save Study',
    'room.save',
    (a) => {
      'name': _one(a, 'NAME'),
      'id': ?a.option('id'),
      'order': ?_intOption(a, 'order'),
    },
    usageLine: 'NAME [--id ID] [--order N]',
    options: (p) => p
      ..addOption('id', help: 'The room to rename or move.')
      ..addOption('order', help: 'Its place in the list, lowest first.'),
  ),
  _Verb(
    'remove',
    'Remove a room. Its devices stay, with no room.',
    'room.remove',
    (a) => {'id': _one(a, 'ID')},
    usageLine: 'ID',
  ),
  _Verb(
    'order',
    'Put rooms in this order: omni room order living study',
    'room.order',
    (a) {
      if (a.rest.isEmpty) throw UsageException('needs ID...', '');
      return {'ids': a.rest};
    },
    usageLine: 'ID...',
  ),
  ...roomHelperVerbs(),
]);

/// `omni scene`: named sets of device actions run together.
Command<int> sceneCommand() =>
    _Group('scene', 'Scenes: device actions run together in one tap.', [
      _Verb('list', 'List scenes.', 'scene.list', (_) => {}),
      sceneCaptureVerb(),
      _Verb(
        'save',
        'Save a scene: omni scene save "Movie night" --do lamp.power=false '
            "--do '{\"do\": \"tv.volume\", \"params\": {\"value\": 20}}'",
        'scene.save',
        (a) {
          final actions = a.multiOption('do');
          if (actions.isEmpty) {
            throw UsageException('needs at least one --do', '');
          }
          return {
            'name': _one(a, 'NAME'),
            'id': ?a.option('id'),
            'icon': ?a.option('icon'),
            'actions': [for (final s in actions) _item(s)],
            'trusted': true,
          };
        },
        usageLine: 'NAME --do ACTION [--do ACTION ...] [--id ID] [--icon ICON]',
        options: (p) => p
          ..addMultiOption(
            'do',
            splitCommas: false,
            help:
                'An action, repeatable: thing.action, thing.action=value, or a '
                'JSON object {do, params}.',
          )
          ..addOption('id', help: 'The scene to save over. Defaults from NAME.')
          ..addOption('icon', help: 'A Material Symbols icon name.'),
      ),
      _Verb(
        'run',
        'Run a scene now.',
        'scene.run',
        (a) => {'id': _one(a, 'ID')},
        usageLine: 'ID',
      ),
      _Verb(
        'remove',
        'Remove a scene.',
        'scene.remove',
        (a) => {'id': _one(a, 'ID')},
        usageLine: 'ID',
      ),
    ]);

/// `omni device organize`: a device's name, room, favourite mark and order.
Command<int> deviceOrganizeCommand() => _Verb(
  'organize',
  'Rename a device, move it to a room or another house, star it or place '
      'it: omni device organize desk_lamp --room Study --favourite',
  'device.organize',
  (a) {
    final args = <String, Object?>{'id': _one(a, 'ID')};
    if (a.option('name') != null) args['name'] = a.option('name');
    if (a.option('move-to') != null) args['moveTo'] = a.option('move-to');
    if (a.flag('no-room')) {
      args['room'] = null;
    } else if (a.option('room') != null) {
      args['room'] = a.option('room');
    }
    if (a.wasParsed('favourite')) args['favourite'] = a.flag('favourite');
    if (a.flag('no-order')) {
      args['order'] = null;
    } else if (a.option('order') != null) {
      args['order'] = _intOption(a, 'order');
    }
    if (args.length == 1) {
      throw UsageException('needs something to change', '');
    }
    return args;
  },
  usageLine: 'ID',
  options: (p) => p
    ..addOption('name')
    ..addOption(
      'move-to',
      help:
          'Move it to another house. Automations in its old house that use '
          'it are turned off.',
    )
    ..addOption('room', help: 'A room id or name. A new name adds the room.')
    ..addFlag('no-room', negatable: false, help: 'Take it out of its room.')
    ..addFlag('favourite', help: 'Star it on the home screen, or not.')
    ..addOption('order', help: 'Its place in its room, lowest first.')
    ..addFlag('no-order', negatable: false, help: 'Clear its place.'),
);

/// `omni device history`: a device's recent state changes.
Command<int> deviceHistoryCommand() => _Verb(
  'history',
  'Show recent state changes, newest first: omni device history lamp --key dimming',
  'device.history',
  (a) => {
    'id': _one(a, 'ID'),
    'key': ?a.option('key'),
    'limit': ?_intOption(a, 'limit'),
    'since': ?a.option('since'),
    'before': ?a.option('before'),
  },
  usageLine: 'ID [--key KEY] [--limit N] [--since TIME] [--before TIME]',
  options: (p) => p
    ..addOption('key', help: 'Only this state key.')
    ..addOption('limit', help: 'How many, 1 to 500. Defaults to 100.')
    ..addOption('since', help: 'Only changes after this ISO 8601 time.')
    ..addOption('before', help: 'Only changes before this ISO 8601 time.'),
);

/// `omni automation`: every automation as the app lists it, and templates.
Command<int> automationCommand() =>
    _Group('automation', 'Every rule, link, scene and flow, as sentences.', [
      _Verb(
        'list',
        'List automations: omni automation list --device lamp --needs-you',
        'automation.list',
        (a) => {
          'source': ?a.option('source'),
          'device': ?a.option('device'),
          'tag': ?a.option('tag'),
          if (a.flag('needs-you')) 'needsYou': true,
        },
        options: (p) => p
          ..addOption(
            'source',
            allowed: ['rule', 'link', 'graph', 'scene'],
            help: 'Only automations written as this.',
          )
          ..addOption('device', help: 'Only those that read or drive it.')
          ..addOption('tag', help: 'Only those an NFC tag starts.')
          ..addFlag(
            'needs-you',
            negatable: false,
            help: 'Only those waiting for approval or failing.',
          ),
      ),
      _Verb(
        'templates',
        'List rule templates, or fill one: omni automation templates bedtime '
            "things='[\"lamp.power\"]' time=22:30",
        'automation.templates',
        (a) => {
          if (a.rest.isNotEmpty) 'id': a.rest.first,
          if (a.rest.length > 1) 'values': parseKeyValues(a.rest.skip(1)),
        },
        usageLine: '[ID [key=value ...]]',
      ),
      ...automationVerbs(),
    ]);

/// `omni presence home|away`: say whether you are home.
Command<int> presenceCommand() => _Verb(
  'presence',
  'Say whether you are home: omni presence home. The next reading decides again.',
  'presence.set',
  (a) {
    if (a.rest.length != 1 || !const {'home', 'away'}.contains(a.rest[0])) {
      throw UsageException('needs home or away', '');
    }
    return {'home': a.rest[0] == 'home', 'person': ?a.option('person')};
  },
  usageLine: 'home|away [--person ID]',
  options: (p) =>
      p.addOption('person', help: 'Defaults to the household person.'),
);
