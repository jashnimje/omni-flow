import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mcp_dart/mcp_dart.dart' show StdioServerTransport;

import '../api/adb_phone_connection.dart';
import '../api/local_client.dart';
import '../api/local_server.dart';
import '../api/omni_engine.dart';
import '../api/phone_actions.dart' show phoneReadingVerbs;
import '../devices/board.dart' show boardPeriphTypes, isSerialHost;
import '../devices/nfc/ndef.dart' show tagUriPrefix, uriRecord;
import '../mcp/omni_mcp.dart';
import '../storage/database.dart' show DatabaseInUseException;
import '../storage/keychain_secret_store.dart';
import '../transports/packet_tap.dart';
import '../version.dart';
import '../api/ssh_hub_client.dart';
import 'add_cli.dart';
import 'hub_cli.dart';
import 'one_shot.dart';
import 'house_cli.dart';
import 'house_view.dart';
import 'organize_cli.dart';
import 'parity_cli.dart';
import 'rule_cli.dart';
import 'tv_cli.dart';

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
/// can do anything the app can. While `omni hub` runs, commands go to the
/// hub through its control socket, `<home>/omni.sock` unless [socketPath]
/// says otherwise; with no hub they open the engine through [engineFactory].
class OmniCommandRunner extends CommandRunner<int> {
  OmniCommandRunner({
    StringSink? out,
    Stream<List<int>>? input,
    EngineFactory? engineFactory,
    this._socketPath,
    HubEnvironment? hubEnvironment,
  }) : out = out ?? stdout,
       input = input ?? stdin,
       engineFactory = engineFactory ?? defaultEngine,
       hubEnvironment = hubEnvironment ?? HubEnvironment(),
       super('omni', 'OmniFlow local-first automation engine.') {
    argParser
      ..addFlag('version', negatable: false, help: 'Print the engine version.')
      ..addOption(
        'home',
        help: 'Data directory. Defaults to \$OMNIFLOW_HOME or ~/.omniflow.',
      )
      ..addOption(
        'phone',
        help:
            'Use the engine of the OmniFlow app on a phone, through adb. '
            'Takes the adb serial, or "usb" for the only phone attached.',
      )
      ..addOption(
        'hub',
        valueHelp: 'user@host[:port]',
        help: 'Drive the OmniFlow hub on another Mac over SSH.',
      )
      ..addOption(
        'hub-key',
        valueHelp: 'FILE',
        help:
            'The SSH private key for --hub, allowed there with omni hub allow.',
      )
      ..addOption(
        'house',
        valueHelp: 'ID',
        help:
            'The house to list and add in. Defaults to omni house use, '
            'else the only house; with several and none chosen, lists show '
            'every house.',
      );
    addCommand(
      _Group('agent', 'What AI agents may do through MCP.', [
        _ApiCommand(
          'access',
          'Show what agents may do, and the commands each level opens.',
          'agent.access',
          (rest, _) async => const {},
        ),
        _ApiCommand(
          'allow',
          'Set what agents may do: read (the default) or setup.',
          'agent.access.set',
          (rest, _) async => {'access': _one(rest, 'read or setup')},
          usage: 'read|setup',
        ),
        _ApiCommand(
          'describe',
          'Everything set up, as an agent sees it.',
          'agent.describe',
          (rest, _) async => const {},
        ),
        _ApiCommand(
          'call',
          'Send a command as an agent would, under the access level.',
          'agent.call',
          (rest, _) async {
            if (rest.isEmpty || rest.length > 2) {
              throw UsageException('needs COMMAND and optional JSON args', '');
            }
            return {
              'command': rest.first,
              if (rest.length == 2) 'args': await _jsonArg(rest[1]),
            };
          },
          usage: 'COMMAND [JSON]',
        ),
      ]),
    );
    addCommand(
      _Group(
        'driver',
        'List, validate, register and approve driver manifests.',
        [
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
          _ApiCommand(
            'approve',
            'Approve a driver an agent registered, so what it drives runs '
                'without waiting for you.',
            'driver.approve',
            (rest, _) async => {'id': _one(rest, 'ID')},
            usage: 'ID',
          ),
        ],
      ),
    );
    addCommand(
      _Group('device', 'Add, inspect and control devices.', [
        _DeviceAdd(),
        _DeviceDiscover(),
        deviceMoveVerb(),
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
        _DevicePair(),
        _DeviceHostKey(),
        DeviceShellCommand(),
        deviceOrganizeCommand(),
        deviceHistoryCommand(),
      ]),
    );
    addCommand(
      _Group('board', 'Set up OmniFlow boards and name their pins.', [
        ...boardFlashVerbs(),
        _BoardSetup(),
        _BoardPeriph(),
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
          'describe',
          'Show the pins a board offers, its IR and RF outputs, and the pins set now.',
          'board.describe',
          (rest, _) async => {'id': _one(rest, 'ID')},
          usage: 'ID',
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
    addCommand(
      HubCommand(_Hub(), addOptions: (c) => _Hub.addOptions(c.argParser)),
    );
    addCommand(_Mcp());
    addCommand(RuleCommand());
    addCommand(AddCommand());
    addCommand(TvCommand());
    addCommand(roomCommand());
    addCommand(sceneCommand());
    addCommand(modeCommand());
    addCommand(timerCommand());
    addCommand(alertsCommand());
    addCommand(automationCommand());
    addCommand(presenceCommand());
    addCommand(energyCommand());
    addCommand(weatherCommand());
    addCommand(sunlightCommand());
    addCommand(awayCommand());
    addCommand(houseCommand());
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
          extra: const {'trusted': true},
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
        _FlowApprove(),
        _FlowRun(),
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
      _Group(
        'sensor',
        'The earlier name of omni phone wifi and omni phone ble.',
        [
          _BleReading(
            'One BLE reading: omni sensor ble OMNI_PICO_DESK -55',
            'sensor.ble',
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
        ],
      ),
    );
    addCommand(
      _Group('phone', 'Feed the phone thing by hand, as the app does.', [
        _ApiCommand(
          'wifi',
          'The current Wi-Fi, none when left out: omni phone wifi HomeNet',
          'phone.wifi',
          (rest, _) async {
            if (rest.length > 2) {
              throw UsageException('needs [SSID] [BSSID]', '');
            }
            return {
              if (rest.isNotEmpty) 'ssid': rest[0],
              if (rest.length > 1) 'bssid': rest[1],
            };
          },
          usage: '[SSID] [BSSID]',
        ),
        _BleReading(
          'One BLE reading: omni phone ble OMNI_PICO_DESK -55',
          'phone.ble',
        ),
        _ApiCommand(
          'battery',
          'The battery level, and whether it charges: omni phone battery 80 charging',
          'phone.battery',
          (rest, _) async {
            final level = rest.isEmpty ? null : num.tryParse(rest[0]);
            if (rest.isEmpty ||
                rest.length > 2 ||
                level == null ||
                (rest.length == 2 &&
                    !const {'charging', 'unplugged'}.contains(rest[1]))) {
              throw UsageException('needs LEVEL [charging|unplugged]', '');
            }
            return {
              'level': level,
              if (rest.length == 2) 'charging': rest[1] == 'charging',
            };
          },
          usage: 'LEVEL [charging|unplugged]',
        ),
        _ApiCommand(
          'app',
          'An app opened or closed: omni phone app com.netflix.mediaclient opened',
          'phone.app',
          (rest, _) async {
            if (rest.length < 2 ||
                rest.length > 3 ||
                !const {'opened', 'closed'}.contains(rest[1])) {
              throw UsageException('needs PACKAGE opened|closed [LABEL]', '');
            }
            return {
              'package': rest[0],
              'event': rest[1],
              if (rest.length == 3) 'label': rest[2],
            };
          },
          usage: 'PACKAGE opened|closed [LABEL]',
        ),
        _ApiCommand(
          'notification',
          'A notification arrived: omni phone notification com.whatsapp [TITLE] [TEXT]',
          'phone.notification',
          (rest, _) async {
            if (rest.isEmpty || rest.length > 3) {
              throw UsageException('needs PACKAGE [TITLE] [TEXT]', '');
            }
            return {
              'package': rest[0],
              if (rest.length > 1) 'title': rest[1],
              if (rest.length > 2) 'text': rest[2],
            };
          },
          usage: 'PACKAGE [TITLE] [TEXT]',
        ),
        _ApiCommand(
          'bluetooth',
          'A Bluetooth device connected or left: omni phone bluetooth "My car" connected',
          'phone.bluetooth',
          (rest, _) async {
            if (rest.length < 2 ||
                rest.length > 3 ||
                !const {'connected', 'disconnected'}.contains(rest[1])) {
              throw UsageException(
                'needs NAME connected|disconnected [ADDRESS]',
                '',
              );
            }
            return {
              'name': rest[0],
              'connected': rest[1] == 'connected',
              if (rest.length == 3) 'address': rest[2],
            };
          },
          usage: 'NAME connected|disconnected [ADDRESS]',
        ),
        for (final (verb, command, what) in const [
          ('screen', 'phone.screen', 'The screen turned on or off'),
          ('dnd', 'phone.dnd', 'Do Not Disturb turned on or off'),
        ])
          _ApiCommand(verb, '$what: omni phone $verb on', command, (
            rest,
            _,
          ) async {
            if (rest.length != 1 || !const {'on', 'off'}.contains(rest[0])) {
              throw UsageException('needs on|off', '');
            }
            return {'on': rest[0] == 'on'};
          }, usage: 'on|off'),
        for (final v in phoneReadingVerbs)
          _ApiCommand(
            v.verb,
            v.help,
            v.command,
            (rest, _) async =>
                v.args(rest) ??
                (throw UsageException(
                  v.usage.isEmpty ? 'takes no words' : 'needs ${v.usage}',
                  '',
                )),
            usage: v.usage,
          ),
        _ApiCommand(
          'nfc',
          'An NFC scan, as omni tag scan UID: omni phone nfc 04:A2:2B:1C [TAG_ID]',
          'nfc.scanned',
          (rest, _) async {
            if (rest.isEmpty || rest.length > 2) {
              throw UsageException('needs UID [TAG_ID]', '');
            }
            return {
              'uid': rest[0],
              'source': 'phone',
              if (rest.length == 2)
                'ndef': [uriRecord('$tagUriPrefix${rest[1]}')],
            };
          },
          usage: 'UID [TAG_ID]',
        ),
      ]),
    );
    addCommand(
      _Group('ask', 'Questions automations are waiting on you to answer.', [
        _ApiCommand(
          'pending',
          'The questions waiting for an answer.',
          'ask.pending',
          (_, _) async => {},
        ),
        _ApiCommand(
          'answer',
          'Answer one: omni ask answer ASK_ID Run',
          'ask.answer',
          (rest, _) async {
            if (rest.length != 2) {
              throw UsageException('needs ASK_ID ANSWER', '');
            }
            return {'askId': rest[0], 'answer': rest[1]};
          },
          usage: 'ASK_ID ANSWER',
        ),
      ]),
    );
    addCommand(
      _Group(
        'tag',
        'NFC tags: name them, write them, and feed scans by hand.',
        [
          _TagAdd(),
          _ApiCommand('list', 'List the tags.', 'tag.list', (_, _) async => {}),
          _ApiCommand(
            'remove',
            'Remove a tag. The flows that name it are disabled.',
            'tag.remove',
            (rest, _) async => {'id': _one(rest, 'ID')},
            usage: 'ID',
          ),
          _ApiCommand(
            'payload',
            'The NDEF records the phone writes on a tag for it.',
            'tag.write_payload',
            (rest, _) async => {'id': _one(rest, 'ID')},
            usage: 'ID',
          ),
          _TagScan(),
        ],
      ),
    );
    addCommand(
      _Group('config', 'Back the home up to one file, and restore it.', [
        _ConfigExport(),
        _ConfigImport(),
        _ApiCommand(
          'auto',
          'The daily automatic backup: on or off, its folder, the last one.',
          'backup.auto.get',
          (_, _) async => const {},
        ),
        _ApiCommand(
          'auto-set',
          'Turn the daily backup on or off, or write one now.',
          'backup.auto.set',
          (rest, _) async => switch (rest) {
            ['on'] => const {'on': true},
            ['off'] => const {'on': false},
            ['now'] => const {'now': true},
            _ => throw UsageException('needs on, off or now', ''),
          },
          usage: 'on|off|now',
        ),
      ]),
    );
    addCommand(
      _Group('home', 'Where home is, and what your home did this week.', [
        _ApiCommand(
          'stats',
          'Runs, taps saved, your streak and achievements: omni home stats [DAYS]',
          'home.stats',
          (rest, _) async {
            if (rest.length > 1) throw UsageException('takes at most DAYS', '');
            return {
              if (rest.isNotEmpty)
                'days': int.tryParse(rest.single) ?? rest.single,
            };
          },
          usage: '[DAYS]',
        ),
        _Group('location', 'Show or set where home is.', [
          _ApiCommand(
            'show',
            'Show where home is, with today\'s sunrise and sunset.',
            'home.location',
            (_, _) async => const {},
          ),
          _HomeLocationSet(),
        ]),
      ]),
    );
    addCommand(
      _Group('secret', 'Store device and web secrets in the keychain.', [
        _ApiCommand(
          'set',
          'Store a secret setting, read from stdin: omni secret set plug localKey < key.txt. '
              'A third name copies that device\'s instead: omni secret set lamp signingKey kitchen',
          'secret.set',
          (rest, runner) async {
            if (rest.length == 3) {
              return {'deviceId': rest[0], 'key': rest[1], 'from': rest[2]};
            }
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
          usage: 'DEVICE KEY [FROM_DEVICE]',
        ),
        _ApiCommand(
          'set-web',
          'Store a web request header secret, read from stdin: '
              'omni secret set-web ha_token < token.txt',
          'web.secret.set',
          (rest, runner) async {
            if (rest.length != 1) {
              throw UsageException(
                'needs NAME',
                'omni secret set-web NAME < value',
              );
            }
            final value = await utf8.decodeStream(runner.input);
            return {
              'name': rest.single,
              'value': value.replaceFirst(RegExp(r'\r?\n$'), ''),
            };
          },
          usage: 'NAME',
        ),
      ]),
    );
  }

  final StringSink out;
  final Stream<List<int>> input;
  final EngineFactory engineFactory;
  final String? _socketPath;

  /// The home, launchd, SSH keys and keychain the hub commands use.
  final HubEnvironment hubEnvironment;

  ArgResults? _globals;

  Directory get home {
    final option = _globals?.option('home');
    return option == null ? defaultHome() : Directory(option);
  }

  String get socketPath => _socketPath ?? localSocketPath(home);

  /// The --home given on the command line, or null for the default.
  String? get homeOption => _globals?.option('home');

  /// The running hub when one answers on [socketPath], else the engine
  /// opened here (with [tap], for commands that show packets).
  Future<EngineConnection> connect({PacketTap? tap}) async =>
      HouseViewConnection(
        await _connect(tap: tap),
        house: _globals?.option('house') ?? readCliHouse(home),
      );

  Future<EngineConnection> _connect({PacketTap? tap}) async {
    if (_globals?['phone'] case final String phone) {
      return AdbPhoneConnection(serial: phone == 'usb' ? null : phone);
    }
    if (await _remoteHub() case final hub?) return hub;
    return await LocalClient.connect(socketPath) ??
        InProcessConnection(await engineFactory(home, tap: tap));
  }

  /// The hub on another Mac that `--hub` and `--hub-key` name, or null.
  Future<EngineConnection?> _remoteHub() async {
    final target = _globals?.option('hub');
    final keyFile = _globals?.option('hub-key');
    if (target == null && keyFile == null) return null;
    if (target == null || keyFile == null) {
      throw UsageException('--hub and --hub-key go together', usage);
    }
    final SshHubTarget hub;
    try {
      hub = SshHubTarget.parse(target);
    } on FormatException catch (e) {
      throw UsageException(e.message, usage);
    }
    return connectSshHub(
      target: hub,
      privateKeyPem: await File(keyFile).readAsString(),
      secrets: hubEnvironment.secrets,
    );
  }

  /// The running hub, here or with `--hub` on another Mac. Throws when no
  /// hub runs, rather than opening the engine.
  Future<EngineConnection> connectToHub() async {
    if (await _remoteHub() case final hub?) return hub;
    return await LocalClient.connect(socketPath) ??
        (throw LocalSocketException('no omni hub is running', exitCode: 69));
  }

  /// `omni hub` with no subcommand runs the hub, as before it had any.
  List<String> _hubRunsByDefault(List<String> args) {
    final results = parse(args);
    final hub = results.command;
    if (hub?.name != 'hub' || hub!.command != null || hub.rest.isNotEmpty) {
      return args;
    }
    if (hub.options.contains('help') && hub.flag('help')) return args;
    final at = args.length - hub.arguments.length;
    return [...args.take(at), 'run', ...args.skip(at)];
  }

  @override
  Future<int> run(Iterable<String> args) async {
    final results = parse(_hubRunsByDefault(args.toList()));
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

/// Runs the CLI as `bin/omni.dart` does: a failure the user can cause
/// prints one line on [err] and returns a sysexits code, never a stack
/// trace.
Future<int> runOmni(
  List<String> args, {
  OmniCommandRunner? runner,
  StringSink? err,
}) async {
  final errors = err ?? stderr;
  try {
    return await (runner ?? OmniCommandRunner()).run(args);
  } on UsageException catch (e) {
    errors.writeln(e);
    return 64;
  } on DatabaseInUseException {
    errors.writeln(
      'omni: the database is in use by another omni process: an omni mcp '
      'started by an MCP client such as Claude Desktop, omni watch, or '
      'another command. Start omni hub first so the others go through it, '
      'or stop that process',
    );
    return 75;
  } on LocalSocketException catch (e) {
    errors.writeln('omni: ${e.message}');
    return e.exitCode;
  } on HubLinkException catch (e) {
    errors.writeln('omni: ${e.message}');
    return e.type == 'host_key' ? 77 : 69;
  } on FileSystemException catch (e) {
    final path = e.path == null ? '' : '${e.path}: ';
    errors.writeln('omni: $path${e.osError?.message ?? e.message}');
    return 66;
  } on FormatException catch (e) {
    errors.writeln('omni: ${e.message}');
    return 64;
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

/// Parses `key=value` device settings. A JSON object or list stays
/// structured (a board's pins), anything else stays the text as typed, so
/// a UID like 12E45678 or an id like 0042 is never read as a number.
Map<String, Object?> parseSettings(Iterable<String> pairs) {
  final map = <String, Object?>{};
  for (final pair in pairs) {
    final eq = pair.indexOf('=');
    if (eq <= 0) throw UsageException('expected key=value, got "$pair"', '');
    map[pair.substring(0, eq)] = settingValue(pair.substring(eq + 1));
  }
  return map;
}

/// One setting value, as [parseSettings] reads it.
Object? settingValue(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map || decoded is List) return decoded;
  } on FormatException {
    // Plain text.
  }
  return raw;
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
    final engine = await omni.connect();
    try {
      final result = await engine.handle(apiCommand, args);
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return result['ok'] == true ? 0 : 1;
    } finally {
      await closeOneShot(engine);
    }
  }
}

class _FileCommand extends _ApiCommand {
  _FileCommand(
    String name,
    String description,
    String apiCommand, {
    String key = 'manifest',
    Map<String, Object?> extra = const {},
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
         return {key: manifest, ...extra};
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
        help:
            'IP address, host name, or local. Not needed for a virtual '
            'thing (phone, person, place, nfc_tag).',
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
        splitCommas: false,
      )
      ..addFlag(
        'replace',
        negatable: false,
        help: 'Replace a device that already has this id.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    final id = OmniCommandRunner._one(a.rest, 'ID');
    final port = a.option('port');
    return {
      'id': id,
      if (a.flag('replace')) 'replace': true,
      'driver': a.option('driver'),
      if (a.option('host') != null) 'host': a.option('host'),
      if (port != null) 'port': int.tryParse(port) ?? port,
      if (a.option('name') != null) 'name': a.option('name'),
      if (a.option('room') != null) 'room': a.option('room'),
      if (a.option('stable-id') != null) 'stableId': a.option('stable-id'),
      'settings': parseSettings(a.multiOption('set')),
    };
  }
}

/// `omni config export [--out FILE]`: the backup alone, so the file is
/// what `omni config import` reads.
class _ConfigExport extends _ApiCommand {
  _ConfigExport()
    : super(
        'export',
        'Write the whole home, without secrets, as one JSON backup.',
        'config.export',
        (_, _) async => const {},
      ) {
    argParser.addOption('out', help: 'Write to FILE instead of stdout.');
  }

  @override
  Future<int> run() async {
    final engine = await omni.connect();
    try {
      final result = await engine.handle(apiCommand, const {});
      const pretty = JsonEncoder.withIndent('  ');
      if (result['ok'] != true) {
        omni.out.writeln(pretty.convert(result));
        return 1;
      }
      final text = pretty.convert(result['backup']);
      final out = argResults!.option('out');
      if (out == null) {
        omni.out.writeln(text);
      } else {
        await File(out).writeAsString('$text\n', flush: true);
        omni.out.writeln(
          pretty.convert({
            'ok': true,
            'out': out,
            'skipped': ?result['skipped'],
          }),
        );
      }
      return 0;
    } finally {
      await engine.close();
    }
  }
}

/// `omni config import FILE [--replace] [--dry-run]`.
class _ConfigImport extends _ApiCommand {
  _ConfigImport()
    : super(
        'import',
        'Restore a backup: merge it in, or with --replace make the home '
            'exactly the backup.',
        'config.import',
        (_, _) async => const {},
        usage: 'FILE',
      ) {
    argParser
      ..addFlag(
        'replace',
        negatable: false,
        help: 'Remove what the backup does not have.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Check the backup and say what would change, changing nothing.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    final file = OmniCommandRunner._one(a.rest, 'FILE');
    final Object? backup;
    try {
      backup = jsonDecode(await File(file).readAsString());
    } on FormatException catch (e) {
      throw UsageException('$file is not valid JSON: ${e.message}', '');
    }
    return {
      'backup': backup,
      'mode': a.flag('replace') ? 'replace' : 'merge',
      if (a.flag('dry-run')) 'dryRun': true,
    };
  }
}

/// `omni home location set --latitude 51.5 --longitude -0.13`. Options, so
/// a negative number is not read as a flag.
class _HomeLocationSet extends _ApiCommand {
  _HomeLocationSet()
    : super(
        'set',
        'Say where home is: omni home location set --latitude 19.08 '
            '--longitude 72.88 (south and west are negative).',
        'home.location.set',
        (_, _) async => const {},
      ) {
    argParser
      ..addOption('latitude', mandatory: true, help: 'Degrees north.')
      ..addOption('longitude', mandatory: true, help: 'Degrees east.')
      ..addOption(
        'name',
        help: 'The place as you say it, such as "Bengaluru".',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    num parse(String key) =>
        num.tryParse(a.option(key)!) ??
        (throw UsageException('$key must be a number', ''));
    return {
      'latitude': parse('latitude'),
      'longitude': parse('longitude'),
      'name': ?a.option('name'),
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

/// `omni device pair ID`: prints what the user must do, then runs the
/// pairing and waits for it (up to a minute while a TV shows its prompt).
class _DevicePair extends _ApiCommand {
  _DevicePair()
    : super(
        'pair',
        'Pair a TV, a Hue bridge or another device that needs it: omni device pair living_tv',
        'device.pair',
        (_, _) async => {},
        usage: 'ID',
      ) {
    argParser.addOption(
      'app-name',
      help: 'The name a Hue bridge lists this pairing under.',
    );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async => {
    'id': OmniCommandRunner._one(argResults!.rest, 'ID'),
    'appName': ?argResults!.option('app-name'),
  };

  @override
  Future<int> run() async {
    final args = await buildArgs();
    final engine = await omni.connect();
    try {
      final got = await engine.handle('device.get', {'id': args['id']});
      final pairing = got['ok'] == true
          ? (got['device'] as Map)['pairing'] as Map?
          : null;
      if (pairing != null) {
        omni.out.writeln(jsonEncode({'event': 'pairing.started', ...pairing}));
      }
      final events = await engine.events();
      final prompts = events
          .where(
            (e) =>
                e['event'] == 'device.pairingPrompt' &&
                e['deviceId'] == args['id'],
          )
          .listen((e) => omni.out.writeln(jsonEncode(e)));
      try {
        final result = await engine.handle(apiCommand, args);
        omni.out.writeln(const JsonEncoder.withIndent('  ').convert(result));
        return result['ok'] == true ? 0 : 1;
      } finally {
        await prompts.cancel();
      }
    } finally {
      await engine.close();
    }
  }
}

/// `omni device hostkey ID` shows the pinned and offered SSH host keys.
/// `--accept FINGERPRINT` pins the offered key only when it is the one the
/// user read, and `--clear` drops the pin.
class _DeviceHostKey extends _ApiCommand {
  _DeviceHostKey()
    : super(
        'hostkey',
        'Show, accept or clear the SSH host key pinned for a host device.',
        'device.hostkey',
        (_, _) async => {},
        usage: 'ID',
      ) {
    argParser
      ..addOption(
        'accept',
        valueHelp: 'FINGERPRINT',
        help: 'Pin the key the host offers, when it is this one (from show).',
      )
      ..addFlag(
        'clear',
        negatable: false,
        help: 'Forget the pin. The next connection pins what it meets.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    final id = OmniCommandRunner._one(a.rest, 'ID');
    final accept = a.option('accept');
    if (accept != null && a.flag('clear')) {
      throw UsageException('use --accept or --clear, not both', usage);
    }
    return {
      'id': id,
      if (accept != null) ...{'action': 'accept', 'fingerprint': accept},
      if (a.flag('clear')) 'action': 'clear',
    };
  }
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
  String get description =>
      'Print live device state and events as JSON lines. While omni hub runs, '
      'they come from the hub and --wiz-port is not used.';

  @override
  Future<int> run() async {
    final omni = runner! as OmniCommandRunner;
    final a = argResults!;
    final wizPort = _port(a, 'wiz-port', usage);
    final seconds = _seconds(a, usage);
    final packets = a.flag('packets');
    final connection = withoutHouseView(
      await omni.connect(tap: packets ? PacketTap() : null),
    );
    if (connection is! InProcessConnection) {
      return _watchHub(omni, connection, packets, seconds);
    }
    final engine = connection.engine;
    final subscription = engine.events.listen(
      (e) => omni.out.writeln(jsonEncode(e)),
    );
    try {
      final count = await engine.startWizPush(listenPort: wizPort);
      omni.out.writeln(
        jsonEncode({'event': 'watch.started', 'wizBulbs': count}),
      );
      await _untilStopped(seconds);
      return 0;
    } finally {
      await subscription.cancel();
      await engine.close();
    }
  }

  /// The hub already listens for WiZ pushes, so this only prints its events,
  /// until stopped or until the hub stops.
  Future<int> _watchHub(
    OmniCommandRunner omni,
    EngineConnection hub,
    bool packets,
    Duration? seconds,
  ) async {
    try {
      final hubStopped = Completer<void>();
      final subscription = (await hub.events(packets: packets)).listen(
        (e) => omni.out.writeln(jsonEncode(e)),
        onDone: hubStopped.complete,
      );
      omni.out.writeln(jsonEncode({'event': 'watch.started', 'hub': true}));
      await _untilStopped(seconds, orWhen: hubStopped.future);
      await subscription.cancel();
      return 0;
    } finally {
      await hub.close();
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
      )
      ..addOption('msg', help: _msgHelp);
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    if (a.rest.isEmpty) throw UsageException('needs ID', '');
    return {
      'id': a.rest.first,
      if (a.option('at') != null) 'at': a.option('at'),
      if (a.option('trigger') != null) 'trigger': a.option('trigger'),
      'msg': _triggerMsg(a, usage),
    };
  }
}

const _msgHelp =
    'The trigger message as a JSON object, for flows that read msg.value '
    'and the like: --msg \'{"value": true}\'. key=value pairs go in msg.payload.';

/// key=value pairs as `msg.payload`, with --msg merged on top.
Map<String, Object?> _triggerMsg(ArgResults a, String usage) {
  final raw = a.option('msg');
  Object? extra;
  if (raw != null) {
    try {
      extra = jsonDecode(raw);
    } on FormatException catch (e) {
      throw UsageException('--msg is not valid JSON: ${e.message}', usage);
    }
    if (extra is! Map) throw UsageException('--msg must be an object', usage);
  }
  return {
    'payload': parseKeyValues(a.rest.skip(1)),
    ...?(extra as Map?)?.cast<String, Object?>(),
  };
}

/// `omni flow run ID [key=value ...] [--msg JSON] [--trigger NODE]`.
class _FlowRun extends _ApiCommand {
  _FlowRun()
    : super(
        'run',
        'Run it now: its manual triggers, or its first trigger as if that '
            'fired, as the app\'s Run it now does: omni flow run ID [key=value ...]',
        'automation.run',
        (_, _) async => {},
        usage: 'ID [key=value ...]',
      ) {
    argParser
      ..addOption(
        'trigger',
        help: 'Fire this trigger node instead of the manual ones.',
      )
      ..addOption('msg', help: _msgHelp);
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    if (a.rest.isEmpty) throw UsageException('needs ID', usage);
    return {
      'id': a.rest.first,
      if (a.option('trigger') != null) 'trigger': a.option('trigger'),
      'msg': _triggerMsg(a, usage),
    };
  }
}

/// `omni flow approve ID [--revision R]`. Approves the revision that
/// `omni flow get` showed, or the current one when none is given.
class _FlowApprove extends _ApiCommand {
  _FlowApprove()
    : super(
        'approve',
        'Approve a high-risk flow that is waiting.',
        'flow.approve',
        (_, _) async => {},
        usage: 'ID',
      ) {
    argParser.addOption(
      'revision',
      help: 'The revision from omni flow get. Refused if the flow changed.',
    );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    final id = OmniCommandRunner._one(a.rest, 'ID');
    var revision = a.option('revision');
    if (revision == null) {
      final engine = await omni.connect();
      try {
        final got = await engine.handle('flow.get', {'id': id});
        if (got['ok'] != true) throw UsageException('no flow $id', usage);
        revision = got['revision'] as String;
      } finally {
        await engine.close();
      }
    }
    return {'id': id, 'revision': revision};
  }
}

int _port(ArgResults a, String option, String usage) {
  final port = int.tryParse(a.option(option)!);
  if (port == null || port < 0 || port > 65535) {
    throw UsageException('--$option needs a port number', usage);
  }
  return port;
}

Duration? _seconds(ArgResults a, String usage) {
  final raw = a.option('seconds');
  if (raw == null) return null;
  final seconds = double.tryParse(raw);
  if (seconds == null || seconds < 0) {
    throw UsageException('--seconds needs a number', usage);
  }
  return Duration(milliseconds: (seconds * 1000).round());
}

/// Waits [duration], or until Ctrl-C or a SIGTERM (launchd, kill), so the
/// caller's finally still closes the engine and its pending writes land.
/// [orWhen] ends the wait early.
Future<void> _untilStopped(Duration? duration, {Future<void>? orWhen}) async {
  final stopped = Completer<void>();
  void stop([Object? _]) {
    if (!stopped.isCompleted) stopped.complete();
  }

  final timer = duration == null ? null : Timer(duration, stop);
  final subscriptions = [
    if (duration == null) ProcessSignal.sigint.watch().listen(stop),
    if (duration == null && !Platform.isWindows)
      ProcessSignal.sigterm.watch().listen(stop),
  ];
  orWhen?.whenComplete(stop).ignore();
  await stopped.future;
  timer?.cancel();
  for (final s in subscriptions) {
    await s.cancel();
  }
}

/// Runs everything on its own until stopped: flows from their triggers, WiZ
/// pushes, timers, zone ticks and device polls. Prints events as JSON lines,
/// and serves its control socket so other `omni` commands and `omni mcp`
/// work while it runs.
class _Hub extends Command<int> {
  _Hub() {
    addOptions(argParser);
  }

  /// The hub's options, on `omni hub run` and on `omni hub` itself, which
  /// runs it.
  static void addOptions(ArgParser parser) {
    parser
      ..addFlag(
        'quiet',
        negatable: false,
        help: 'Print only that the hub started, not every event (for its log).',
      )
      ..addOption(
        'seconds',
        help: 'Stop after this many seconds. Default: until Ctrl-C.',
      )
      ..addOption(
        'wiz-port',
        defaultsTo: '38900',
        help: 'Port to receive WiZ pushes on.',
      )
      ..addOption(
        'hello-port',
        defaultsTo: '38951',
        help: 'Port to receive board hellos on, or 0 for none.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Run flows headless on this machine (the always-on hub). The same as '
      'omni hub on its own.';

  @override
  Future<int> run() async {
    final omni = runner! as OmniCommandRunner;
    final a = argResults!;
    final wizPort = _port(a, 'wiz-port', usage);
    final helloPort = _port(a, 'hello-port', usage);
    final seconds = _seconds(a, usage);
    await preparePrivateHome(omni.home);
    // The tap is for socket clients (omni watch --packets, the MCP packet
    // sniffer). The hub's own output leaves packets out.
    final engine = await omni.engineFactory(omni.home, tap: PacketTap());
    final quiet = a.flag('quiet');
    final subscription = engine.events
        .where((e) => !quiet && e['event'] != 'packet.captured')
        .listen((e) => omni.out.writeln(jsonEncode(e)));
    LocalServer? server;
    try {
      server = await LocalServer.start(
        engine,
        home: omni.home,
        path: omni.socketPath,
      );
      final started = await engine.handle('hub.start', {
        'wizPort': wizPort,
        'helloPort': helloPort,
      });
      if (started['ok'] != true) {
        omni.out.writeln(jsonEncode(started));
        return 1;
      }
      omni.out.writeln(
        jsonEncode({
          'event': 'hub.started',
          'flows': started['flows'],
          'socket': server.path,
        }),
      );
      await _untilStopped(seconds);
      return 0;
    } finally {
      await subscription.cancel();
      await server?.close();
      await engine.close();
    }
  }
}

/// Serves the MCP tools over stdin and stdout, for Claude Code or Claude
/// Desktop to start as a subprocess. Nothing else may write to stdout.
/// While `omni hub` runs, the tools drive the hub through its socket.
class _Mcp extends Command<int> {
  @override
  String get name => 'mcp';

  @override
  String get description => 'Serve the OmniFlow MCP tools over stdio.';

  @override
  Future<int> run() async {
    final omni = runner! as OmniCommandRunner;
    final engine = await omni.connect(tap: PacketTap());
    final closed = Completer<void>();
    final transport = StdioServerTransport();
    try {
      await createOmniMcpServerFor(engine).connect(transport);
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

/// `omni board periph /dev/cu.usbserial-0001 nfc_rc522 --pin ss=5 --pin
/// rst=27` binds a reader to pins over USB; `--clear` takes it off.
class _BoardPeriph extends _ApiCommand {
  _BoardPeriph()
    : super(
        'periph',
        'Bind a peripheral to pins over USB: omni board periph PORT nfc_rc522 --pin ss=5 '
            '(types: ${boardPeriphTypes.join(', ')}). The board is a USB port, or the id of a '
            'board on USB.',
        'board.periph',
        (_, _) async => {},
        usage: 'PORT|ID TYPE',
      ) {
    argParser
      ..addMultiOption(
        'pin',
        valueHelp: 'NAME=GPIO',
        help: 'One pin: tx for ir and rf, ss and rst for nfc_rc522.',
      )
      ..addFlag('clear', negatable: false, help: 'Take the peripheral off.');
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    if (a.rest.length != 2) {
      throw UsageException('needs PORT|ID and TYPE', usage);
    }
    final pins = <String, Object?>{};
    for (final p in a.multiOption('pin')) {
      final at = p.indexOf('=');
      final gpio = at < 1 ? null : int.tryParse(p.substring(at + 1));
      if (gpio == null) {
        throw UsageException('--pin is NAME=GPIO, like ss=5', usage);
      }
      pins[p.substring(0, at)] = gpio;
    }
    final target = a.rest[0];
    return {
      if (isSerialHost(target)) 'port': target else 'id': target,
      'type': a.rest[1],
      if (pins.isNotEmpty) 'pins': pins,
      if (a.flag('clear')) 'clear': true,
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
      )
      ..addFlag(
        'active-low',
        defaultsTo: null,
        help:
            'out: the load switches on at LOW (most relay modules). '
            '--no-active-low on in_pullup reads true when high. Kept from '
            'the current pin when not given.',
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
    final engine = await omni.connect();
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
      final before = current[rest[1]];
      // Rewriting the pin without its invert would drive an active-low
      // relay to the level that switches it on while its state reads off.
      final invert = a.wasParsed('active-low')
          ? a.flag('active-low')
          : before is Map && before['mode'] == rest[3]
          ? before['invert']
          : null;
      current[rest[1]] = {
        'pin': pin,
        'mode': rest[3],
        'invert': ?invert,
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
      ..addOption('set', help: '...set TO to this value (true, 80, "warm").')
      ..addFlag(
        'replace',
        negatable: false,
        help: 'Save the link again when the same link exists.',
      );
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
      'trusted': true,
      if (a.flag('replace')) 'replace': true,
      'mode': modes.single,
      'above': ?number('above'),
      'below': ?number('below'),
      if (set != null) 'set': parseKeyValues(['v=$set'])['v'],
    };
  }
}

/// `omni tag add front_door "Front door" --uid 04:A2:2B:1C` adds a tag or
/// renames it and sets its UID.
class _TagAdd extends _ApiCommand {
  _TagAdd()
    : super(
        'add',
        'Add a tag, or rename it: omni tag add front_door "Front door" --uid 04:A2:2B:1C',
        'tag.save',
        (_, _) async => {},
        usage: 'ID NAME',
      ) {
    argParser.addOption('uid', valueHelp: 'HEX', help: 'The tag UID.');
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    if (a.rest.length != 2) throw UsageException('needs ID and NAME', usage);
    return {'id': a.rest[0], 'name': a.rest[1], 'uid': ?a.option('uid')};
  }
}

/// `omni tag scan 04A22B1C --source desk --uri omniflow://tag/front_door`
/// feeds `nfc.scanned` as a reader would, the phone unless `--source` names
/// a board.
class _TagScan extends _ApiCommand {
  _TagScan()
    : super(
        'scan',
        'A scan, as a reader sends it: omni tag scan 04A22B1C [--source BOARD] [--uri omniflow://tag/ID]',
        'nfc.scanned',
        (_, _) async => {},
        usage: 'UID',
      ) {
    argParser
      ..addOption(
        'source',
        defaultsTo: 'phone',
        valueHelp: 'phone|BOARD',
        help: 'The reader: the phone, or the id of a board.',
      )
      ..addOption(
        'uri',
        valueHelp: 'URI',
        help: 'A URI record the tag carries.',
      );
  }

  @override
  Future<Map<String, Object?>> buildArgs() async {
    final a = argResults!;
    if (a.rest.length != 1) throw UsageException('needs UID', usage);
    final uri = a.option('uri');
    return {
      'uid': a.rest.single,
      'source': a.option('source'),
      if (uri != null) 'ndef': [uriRecord(uri)],
    };
  }
}

/// One BLE reading. Options end at the first argument, so a negative RSSI
/// such as -55 is not read as an option.
class _BleReading extends _ApiCommand {
  _BleReading(String description, String apiCommand)
    : super('ble', description, apiCommand, (rest, _) async {
        if (rest.length != 2 || num.tryParse(rest[1]) == null) {
          throw UsageException('needs NAME RSSI', '');
        }
        return {'name': rest[0], 'rssi': num.parse(rest[1])};
      }, usage: 'NAME RSSI');

  @override
  final argParser = ArgParser(allowTrailingOptions: false);
}
