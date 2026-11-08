import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mcp_dart/mcp_dart.dart' show StdioServerTransport;

import '../api/omni_engine.dart';
import '../mcp/omni_mcp.dart';
import '../storage/keychain_secret_store.dart';
import '../transports/packet_tap.dart';
import '../version.dart';

typedef EngineFactory = Future<OmniEngine> Function(
  Directory home, {
  PacketTap? tap,
});

/// The default engine for the CLI: data in [home], secrets in the macOS keychain.
Future<OmniEngine> defaultEngine(Directory home, {PacketTap? tap}) {
  if (!Platform.isMacOS) {
    throw UnsupportedError(
      'the omni CLI keeps secrets in the macOS keychain, so it runs on macOS for now',
    );
  }
  return OmniEngine.open(home: home, secrets: KeychainSecretStore(), tap: tap);
}

Directory defaultHome() {
  final env = Platform.environment;
  final explicit = env['OMNIFLOW_HOME'];
  if (explicit != null && explicit.isNotEmpty) return Directory(explicit);
  return Directory('${env['HOME']}/.omniflow');
}

/// The `omni` CLI. Every subcommand sends one core API command, so the CLI
/// can do anything the app can.
class OmniCommandRunner extends CommandRunner<int> {
  OmniCommandRunner({
    StringSink? out,
    Stream<List<int>>? input,
    EngineFactory? engineFactory,
  }) : out = out ?? stdout,
       input = input ?? stdin,
       engineFactory = engineFactory ?? defaultEngine,
       super('omni', 'OmniFlow local-first automation engine.') {
    argParser
      ..addFlag('version', negatable: false, help: 'Print the engine version.')
      ..addOption(
        'home',
        help: 'Data directory. Defaults to \$OMNIFLOW_HOME or ~/.omniflow.',
      );
    addCommand(
      _Group('driver', 'List, validate and register driver manifests.', [
        _ApiCommand(
          'list',
          'List built-in and user drivers.',
          'driver.list',
          (_, _) async => {},
        ),
        _FileCommand(
          'validate',
          'Check a .omni_driver.json file.',
          'driver.validate',
        ),
        _FileCommand(
          'register',
          'Add or replace a user driver from a file.',
          'driver.register',
        ),
      ]),
    );
    addCommand(
      _Group('device', 'Add, inspect and control devices.', [
        _DeviceAdd(),
        _DeviceDiscover(),
        _ApiCommand(
          'list',
          'List devices with their state.',
          'device.list',
          (_, _) async => {},
        ),
        _ApiCommand(
          'get',
          'Show one device.',
          'device.get',
          (rest, _) async => {'id': _one(rest, 'ID')},
          usage: 'ID',
        ),
        _ApiCommand(
          'remove',
          'Remove a device.',
          'device.remove',
          (rest, _) async => {'id': _one(rest, 'ID')},
          usage: 'ID',
        ),
        _ApiCommand(
          'refresh',
          'Poll a device for its state.',
          'device.refresh',
          (rest, _) async => {'id': _one(rest, 'ID')},
          usage: 'ID',
        ),
        _ApiCommand(
          'invoke',
          'Run a capability: omni device invoke desk_lamp brightness value=80',
          'device.invoke',
          (rest, _) async {
            if (rest.length < 2) {
              throw UsageException(
                'needs ID and CAPABILITY',
                'omni device invoke ID CAPABILITY [key=value ...]',
              );
            }
            return {
              'id': rest[0],
              'capability': rest[1],
              'params': parseKeyValues(rest.skip(2)),
            };
          },
          usage: 'ID CAPABILITY [key=value ...]',
        ),
      ]),
    );
    addCommand(
      _Group('board', 'Set up OmniFlow boards and name their pins.', [
        _BoardSetup(),
        _BoardPin(),
        _ApiCommand(
          'pins',
          'Replace all pins: omni board pins desk \'{"relay":{"pin":4,"mode":"out"}}\'',
          'board.pins',
          (rest, _) async {
            if (rest.length != 2) {
              throw UsageException('needs ID and PINS (JSON or a file)', '');
            }
            return {'id': rest[0], 'pins': await _jsonArg(rest[1])};
          },
          usage: 'ID PINS',
        ),
        _ApiCommand(
          'provision',
          'Send the pin setup to a board again.',
          'board.provision',
          (rest, _) async => {'id': _one(rest, 'ID')},
          usage: 'ID',
        ),
      ]),
    );
    addCommand(
      _Group('link', 'Connect one device to another in one line.', [
        _LinkAdd(),
        _ApiCommand('list', 'List links.', 'link.list', (_, _) async => {}),
        _ApiCommand(
          'remove',
          'Remove a link.',
          'link.remove',
          (rest, _) async => {'id': _one(rest, 'ID')},
          usage: 'ID',
        ),
      ]),
    );
    addCommand(_Watch());
    addCommand(_Hub());
    addCommand(_Mcp());
    String id(List<String> rest) => _one(rest, 'ID');
    addCommand(
      _Group('flow', 'Validate, save, run and inspect flows.', [
        _FileCommand(
          'validate',
          'Check a flow file against your devices and zones.',
          'flow.validate',
          key: 'flow',
        ),
        _FileCommand(
          'save',
          'Add or replace a flow from a file.',
          'flow.save',
          key: 'flow',
        ),
        _ApiCommand(
          'list',
          'List flows and whether they are loaded.',
          'flow.list',
          (_, _) async => {},
        ),
        _ApiCommand(
          'get',
          'Show a flow.',
          'flow.get',
          (rest, _) async => {'id': id(rest)},
          usage: 'ID',
        ),
        _ApiCommand(
          'remove',
          'Remove a flow.',
          'flow.remove',
          (rest, _) async => {'id': id(rest)},
          usage: 'ID',
        ),
        _ApiCommand(
          'enable',
          'Enable a flow.',
          'flow.enable',
          (rest, _) async => {'id': id(rest), 'enabled': true},
          usage: 'ID',
        ),
        _ApiCommand(
          'disable',
          'Disable a flow.',
          'flow.enable',
          (rest, _) async => {'id': id(rest), 'enabled': false},
          usage: 'ID',
        ),
        _ApiCommand(
          'approve',
          'Approve a high-risk flow that is waiting.',
          'flow.approve',
          (rest, _) async => {'id': id(rest)},
          usage: 'ID',
        ),
        _ApiCommand(
          'run',
          'Fire a flow\'s manual triggers: omni flow run ID [key=value ...]',
          'flow.run',
          (rest, _) async {
            if (rest.isEmpty) throw UsageException('needs ID', '');
            return {
              'id': rest.first,
              'msg': {'payload': parseKeyValues(rest.skip(1))},
            };
          },
          usage: 'ID [key=value ...]',
        ),
        _FlowDryRun(),
        _ApiCommand(
          'log',
          'Show recent runs, of one flow or all.',
          'flow.log',
          (rest, _) async => {if (rest.isNotEmpty) 'id': rest.first},
          usage: '[ID]',
        ),
      ]),
    );
    addCommand(
      _Group('var', 'Global variables.', [
        _ApiCommand(
          'list',
          'List global variables.',
          'var.list',
          (_, _) async => {},
        ),
        _ApiCommand(
          'set',
          'Set one: omni var set HomeSsids \'["HomeNet"]\'',
          'var.set',
          (rest, _) async {
            if (rest.length != 2) throw UsageException('needs NAME VALUE', '');
            return {
              'name': rest[0],
              'value': parseKeyValues(['v=${rest[1]}'])['v'],
            };
          },
          usage: 'NAME VALUE',
        ),
        _ApiCommand(
          'remove',
          'Remove one.',
          'var.remove',
          (rest, _) async => {'name': _one(rest, 'NAME')},
          usage: 'NAME',
        ),
      ]),
    );
    addCommand(
      _Group('zone', 'Zones for presence.', [
        _FileCommand(
          'save',
          'Add or replace a zone from a file.',
          'zone.save',
          key: 'zone',
        ),
        _ApiCommand(
          'list',
          'List zones and who is inside.',
          'zone.list',
          (_, _) async => {},
        ),
        _ApiCommand(
          'remove',
          'Remove a zone.',
          'zone.remove',
          (rest, _) async => {'id': id(rest)},
          usage: 'ID',
        ),
      ]),
    );
    addCommand(
      _Group('sensor', 'Feed sensor readings by hand, for testing zones.', [
        _ApiCommand(
          'ble',
          'One BLE reading: omni sensor ble OMNI_PICO_DESK -55',
          'sensor.ble',
          (rest, _) async {
            if (rest.length != 2 || num.tryParse(rest[1]) == null) {
              throw UsageException('needs NAME RSSI', '');
            }
            return {'name': rest[0], 'rssi': num.parse(rest[1])};
          },
          usage: 'NAME RSSI',
        ),
        _ApiCommand(
          'wifi',
          'The current Wi-Fi: omni sensor wifi HomeNet',
          'sensor.wifi',
          (rest, _) async => {
            if (rest.isNotEmpty) 'ssid': rest[0],
            if (rest.length > 1) 'bssid': rest[1],
          },
          usage: '[SSID] [BSSID]',
        ),
      ]),
    );
    addCommand(
      _Group('secret', 'Store device secrets in the keychain.', [
        _ApiCommand(
          'set',
          'Store a secret setting, read from stdin: omni secret set plug localKey < key.txt',
          'secret.set',
          (rest, runner) async {
            if (rest.length != 2) {
              throw UsageException(
                'needs DEVICE and KEY',
                'omni secret set DEVICE KEY < value',
              );
            }
            final value = await utf8.decodeStream(runner.input);
            return {
              'deviceId': rest[0],
              'key': rest[1],
              'value': value.replaceFirst(RegExp(r'\r?\n$'), ''),
            };
          },
          usage: 'DEVICE KEY',
        ),
      ]),
    );
  }

  final StringSink out;
  final Stream<List<int>> input;
  final EngineFactory engineFactory;

  ArgResults? _globals;

  Directory get home {
    final option = _globals?.option('home');
    return option == null ? defaultHome() : Directory(option);
  }

  @override
  Future<int> run(Iterable<String> args) async {
    final results = parse(args);
    _globals = results;
    if (results.flag('version')) {
      out.writeln('omni $omniflowEngineVersion');
      return 0;
    }
    return await runCommand(results) ?? 0;
  }

  static String _one(List<String> rest, String name) {
    if (rest.length != 1) throw UsageException('needs $name', '');
    return rest.single;
  }
}

/// Parses `key=value` pairs. A value that is valid JSON keeps its type
/// (`value=80` is a number, `value=true` a boolean), anything else is text.
Map<String, Object?> parseKeyValues(Iterable<String> pairs) {
  final map = <String, Object?>{};
  for (final pair in pairs) {
    final eq = pair.indexOf('=');
    if (eq <= 0) throw UsageException('expected key=value, got "$pair"', '');
    final raw = pair.substring(eq + 1);
    Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      value = raw;
    }
    map[pair.substring(0, eq)] = value;
  }
  return map;
}

class _Group extends Command<int> {
  _Group(this.name, this.description, List<Command<int>> children) {
    children.forEach(addSubcommand);
  }

  @override
  final String name;
  @override
  final String description;
}

typedef _ArgsBuilder = Future<Map<String, Object?>> Function(
  List<String> rest,
  OmniCommandRunner runner,
);

class _ApiCommand extends Command<int> {
  _ApiCommand(
    this.name,
    this.description,
    this.apiCommand,
    this.build, {
    this._usage = '',
  });

  @override
  final String name;
  @override
  final String description;
  final String apiCommand;
  final _ArgsBuilder build;
  final String _usage;

  @override
  String get invocation =>
      '${super.invocation.replaceFirst(' [arguments]', '')} $_usage'
          .trimRight();

  OmniCommandRunner get omni => runner! as OmniCommandRunner;

  Future<Map<String, Object?>> buildArgs() => build(argResults!.rest, omni);

  @override
  Future<int> run() async {
    final args = await buildArgs();
    final engine = await omni.engineFactory(omni.home);
    try {
      final result = await engine.handle(apiCommand, args);
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return result['ok'] == true ? 0 : 1;
    } finally {
      await engine.close();
    }
  }
}

class _FileCommand extends _ApiCommand {
  _FileCommand(
    String name,
    String description,
    String apiCommand, {
    String key = 'manifest',
  }) : super(name, description, apiCommand, (rest, _) async {
         if (rest.length != 1) throw UsageException('needs a $key FILE', '');
         final Object? manifest;
         try {
           manifest = jsonDecode(await File(rest.single).readAsString());
         } on FormatException catch (e) {
           throw UsageException(
             '${rest.single} is not valid JSON: ${e.message}',
             '',
           );
         }
         return {key: manifest};
       }, usage: 'FILE');
}

class _DeviceAdd extends _ApiCommand {
  _DeviceAdd()
    : super(
        'add',
        'Add a device: omni device add desk_lamp --driver philips_wiz_udp --host 192.168.1.40',
        'device.add',
        (_, _) async => {},
        usage: 'ID',
      ) {
    argParser
      ..addOption(
        'driver',
        mandatory: true,
        help: 'Driver id (omni driver list).',
      )
      ..addOption(
        'host',
        mandatory: true,
        help: 'IP address, host name, or local.',
      )
      ..addOption('port', help: "Overrides the driver's port.")
      ..addOption('name', help: 'Display name.')
      ..addOption('room')
      ..addOption(
        'stable-id',
        help: 'MAC or device id, used to find the device after an IP change.',
      )
      ..addMultiOption(
        'set',
        help: 'A non-secret setting, key=value. Repeatable.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    final id = OmniCommandRunner._one(a.rest, 'ID');
    final port = a.option('port');
    return {
      'id': id,
      'driver': a.option('driver'),
      'host': a.option('host'),
      if (port != null) 'port': int.tryParse(port) ?? port,
      if (a.option('name') != null) 'name': a.option('name'),
      if (a.option('room') != null) 'room': a.option('room'),
      if (a.option('stable-id') != null) 'stableId': a.option('stable-id'),
      // Objects (a board's pins) stay structured; scalars stay text, so a
      // user name like 1234 is not turned into a number.
      'settings': parseKeyValues(a.multiOption('set')).map(
        (k, v) => MapEntry(
          k,
          v is Map || v is List || v is String ? v : jsonEncode(v),
        ),
      ),
    };
  }
}

class _DeviceDiscover extends _ApiCommand {
  _DeviceDiscover()
    : super(
        'discover',
        'Find devices of a driver on the LAN: omni device discover --driver philips_wiz_udp',
        'device.discover',
        (_, _) async => {},
      ) {
    argParser
      ..addOption(
        'driver',
        mandatory: true,
        help: 'Driver id (omni driver list).',
      )
      ..addOption(
        'window-ms',
        defaultsTo: '2000',
        help: 'How long to listen for replies.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async => {
    'driver': argResults!.option('driver'),
    'windowMs': int.tryParse(argResults!.option('window-ms')!) ?? 2000,
  };
}

/// Prints engine events as JSON lines until stopped: live WiZ state, devices
/// changing, and with --packets every packet sent or received.
class _Watch extends Command<int> {
  _Watch() {
    argParser
      ..addOption(
        'seconds',
        help: 'Stop after this many seconds. Default: until Ctrl-C.',
      )
      ..addFlag('packets', negatable: false, help: 'Also print every packet.')
      ..addOption(
        'wiz-port',
        defaultsTo: '38900',
        help: 'Port to receive WiZ pushes on.',
      );
  }

  @override
  String get name => 'watch';

  @override
  String get description => 'Print live device state and events as JSON lines.';

  @override
  Future<int> run() async {
    final omni = runner! as OmniCommandRunner;
    final a = argResults!;
    final tap = a.flag('packets') ? PacketTap() : null;
    final engine = await omni.engineFactory(omni.home, tap: tap);
    final subscription = engine.events.listen(
      (e) => omni.out.writeln(jsonEncode(e)),
    );
    try {
      final count = await engine.startWizPush(
        listenPort: int.parse(a.option('wiz-port')!),
      );
      omni.out.writeln(
        jsonEncode({'event': 'watch.started', 'wizBulbs': count}),
      );
      final seconds = a.option('seconds');
      if (seconds != null) {
        await Future<void>.delayed(
          Duration(milliseconds: (double.parse(seconds) * 1000).round()),
        );
      } else {
        await ProcessSignal.sigint.watch().first;
      }
      return 0;
    } finally {
      await subscription.cancel();
      await engine.close();
    }
  }
}

class _FlowDryRun extends _ApiCommand {
  _FlowDryRun()
    : super(
        'dry-run',
        'Run a flow without sending anything: omni flow dry-run ID [--at 2026-11-06T19:00] [key=value ...]',
        'flow.dryRun',
        (_, _) async => {},
        usage: 'ID [key=value ...]',
      ) {
    argParser
      ..addOption('at', help: 'Local time to pretend it is (ISO 8601).')
      ..addOption(
        'trigger',
        help: 'Which trigger node to fire. Default: the first.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    if (a.rest.isEmpty) throw UsageException('needs ID', '');
    return {
      'id': a.rest.first,
      if (a.option('at') != null) 'at': a.option('at'),
      if (a.option('trigger') != null) 'trigger': a.option('trigger'),
      'msg': {'payload': parseKeyValues(a.rest.skip(1))},
    };
  }
}

/// Runs everything on its own until stopped: flows from their triggers, WiZ
/// pushes, timers, zone ticks and device polls. Prints events as JSON lines.
class _Hub extends Command<int> {
  _Hub() {
    argParser
      ..addOption(
        'seconds',
        help: 'Stop after this many seconds. Default: until Ctrl-C.',
      )
      ..addOption(
        'wiz-port',
        defaultsTo: '38900',
        help: 'Port to receive WiZ pushes on.',
      );
  }

  @override
  String get name => 'hub';

  @override
  String get description =>
      'Run flows headless on this machine (the optional always-on hub).';

  @override
  Future<int> run() async {
    final omni = runner! as OmniCommandRunner;
    final a = argResults!;
    final engine = await omni.engineFactory(omni.home);
    final subscription = engine.events.listen(
      (e) => omni.out.writeln(jsonEncode(e)),
    );
    try {
      await engine.startHub(wizListenPort: int.parse(a.option('wiz-port')!));
      omni.out.writeln(
        jsonEncode({
          'event': 'hub.started',
          'flows': engine.flows.loadedFlows.toList(),
        }),
      );
      final seconds = a.option('seconds');
      if (seconds != null) {
        await Future<void>.delayed(
          Duration(milliseconds: (double.parse(seconds) * 1000).round()),
        );
      } else {
        await ProcessSignal.sigint.watch().first;
      }
      return 0;
    } finally {
      await subscription.cancel();
      await engine.close();
    }
  }
}

/// Serves the MCP tools over stdin and stdout, for Claude Code or Claude
/// Desktop to start as a subprocess. Nothing else may write to stdout.
class _Mcp extends Command<int> {
  @override
  String get name => 'mcp';

  @override
  String get description => 'Serve the OmniFlow MCP tools over stdio.';

  @override
  Future<int> run() async {
    final omni = runner! as OmniCommandRunner;
    final engine = await omni.engineFactory(omni.home, tap: PacketTap());
    final closed = Completer<void>();
    final transport = StdioServerTransport();
    try {
      await createOmniMcpServer(engine).connect(transport);
      // connect() installs the server's own close handler, so chain onto it.
      final serverOnClose = transport.onclose;
      transport.onclose = () {
        serverOnClose?.call();
        if (!closed.isCompleted) closed.complete();
      };
      await closed.future;
      return 0;
    } finally {
      await engine.close();
    }
  }
}

/// Inline JSON, or the path of a JSON file.
Future<Object?> _jsonArg(String value) async {
  final text =
      value.trimLeft().startsWith('{') || value.trimLeft().startsWith('[')
      ? value
      : await File(value).readAsString();
  try {
    return jsonDecode(text);
  } on FormatException catch (e) {
    throw UsageException('not valid JSON: ${e.message}', '');
  }
}

/// `omni board setup /dev/cu.usbmodem1101 --ssid Home --name desk_board`.
/// The Wi-Fi password is read from stdin (hidden when it is a terminal),
/// never from the command line, where other processes could see it.
class _BoardSetup extends _ApiCommand {
  _BoardSetup()
    : super(
        'setup',
        'Set up a board on USB: Wi-Fi, name and IR pin, kept in its flash.',
        'board.setup',
        (_, _) async => {},
        usage: 'PORT',
      ) {
    argParser
      ..addOption('ssid', help: 'Wi-Fi network to join (2.4 GHz).')
      ..addOption('name', help: 'Board name, lower snake case.')
      ..addOption('ir-pin', help: 'GPIO of the IR LED, or -1 for none.');
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    final ssid = a.option('ssid');
    String? password;
    if (ssid != null) {
      final terminal = identical(omni.input, stdin) && stdin.hasTerminal;
      if (terminal) {
        stderr.write('Wi-Fi password for $ssid (empty for an open network): ');
        stdin.echoMode = false;
      }
      try {
        password = await omni.input
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .catchError((Object _) => '');
      } finally {
        if (terminal) {
          stdin.echoMode = true;
          stderr.writeln();
        }
      }
    }
    final irPin = a.option('ir-pin');
    return {
      'port': OmniCommandRunner._one(a.rest, 'PORT'),
      'ssid': ?ssid,
      'password': ?password,
      if (a.option('name') != null) 'name': a.option('name'),
      if (irPin != null) 'irPin': int.tryParse(irPin) ?? irPin,
    };
  }
}

/// `omni board pin desk relay 4 out` names one pin and sets it up;
/// `omni board pin desk relay --remove` forgets it.
class _BoardPin extends _ApiCommand {
  _BoardPin()
    : super(
        'pin',
        'Name one pin: omni board pin desk relay 4 out (modes: in, in_pullup, out, pwm, servo, adc)',
        'board.pins',
        (_, _) async => {},
        usage: 'ID NAME [PIN MODE]',
      ) {
    argParser
      ..addFlag('remove', negatable: false, help: 'Forget this pin.')
      ..addOption('watch-ms', help: 'How often an input is checked.')
      ..addOption('delta', help: 'Ignore analog changes this small.')
      ..addFlag(
        'no-watch',
        negatable: false,
        help: 'Do not report input changes.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    final rest = a.rest;
    final remove = a.flag('remove');
    if (rest.length != (remove ? 2 : 4)) {
      throw UsageException(
        remove ? 'needs ID and NAME' : 'needs ID, NAME, PIN and MODE',
        usage,
      );
    }
    final engine = await omni.engineFactory(omni.home);
    final Map<String, Object?> current;
    try {
      final got = await engine.handle('device.get', {'id': rest[0]});
      if (got['ok'] != true) {
        throw UsageException('no device ${rest[0]}', '');
      }
      final settings = (got['device'] as Map)['settings'] as Map;
      current = Map<String, Object?>.from(settings['pins'] as Map? ?? const {});
    } finally {
      await engine.close();
    }
    if (remove) {
      current.remove(rest[1]);
    } else {
      final pin = int.tryParse(rest[2]);
      if (pin == null) throw UsageException('PIN is a GPIO number', usage);
      final watchMs = a.option('watch-ms');
      final delta = a.option('delta');
      current[rest[1]] = {
        'pin': pin,
        'mode': rest[3],
        if (a.flag('no-watch'))
          'watch': false
        else if (watchMs != null || delta != null)
          'watch': {
            if (watchMs != null) 'ms': int.tryParse(watchMs) ?? watchMs,
            if (delta != null) 'delta': int.tryParse(delta) ?? delta,
          },
      };
    }
    return {'id': rest[0], 'pins': current};
  }
}

/// `omni link add desk_board.button lamp.power --toggle`,
/// `omni link add desk_board.knob lamp.brightness --follow`,
/// `omni link add desk_board.light hall_plug.power --below 30 --set true`.
class _LinkAdd extends _ApiCommand {
  _LinkAdd()
    : super(
        'add',
        'Link FROM (device.state) to TO (device.capability).',
        'link.create',
        (_, _) async => {},
        usage: 'FROM TO',
      ) {
    argParser
      ..addFlag(
        'toggle',
        negatable: false,
        help: 'Each press of FROM flips TO.',
      )
      ..addFlag('follow', negatable: false, help: 'TO copies FROM, scaled.')
      ..addOption('above', help: 'When FROM goes above this number...')
      ..addOption('below', help: 'When FROM goes below this number...')
      ..addOption('set', help: '...set TO to this value (true, 80, "warm").');
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    if (a.rest.length != 2) throw UsageException('needs FROM and TO', usage);
    final threshold = a.option('above') != null || a.option('below') != null;
    final modes = [
      if (a.flag('toggle')) 'toggle',
      if (a.flag('follow')) 'follow',
      if (threshold) 'threshold',
    ];
    if (modes.length != 1) {
      throw UsageException(
        'pick one of --toggle, --follow, or --above/--below with --set',
        usage,
      );
    }
    num? number(String key) {
      final v = a.option(key);
      if (v == null) return null;
      return num.tryParse(v) ??
          (throw UsageException('--$key needs a number', usage));
    }

    final set = a.option('set');
    return {
      'from': a.rest[0],
      'to': a.rest[1],
      'mode': modes.single,
      'above': ?number('above'),
      'below': ?number('below'),
      if (set != null) 'set': parseKeyValues(['v=$set'])['v'],
    };
  }
}
