import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../api/local_client.dart';
import '../storage/keychain_secret_store.dart';
import '../storage/secret_store.dart';
import 'hub_templates.g.dart';
import 'omni_command_runner.dart';
import 'one_shot.dart';

/// The launchd label of the hub, and of its daily backup.
const hubLaunchLabel = 'com.jashnm.omniflow.hub';
const backupLaunchLabel = 'com.jashnm.omniflow.backup';

/// Where `omni hub install` tells the user to put the sshd snippet.
const sshdSnippetPath = '/etc/ssh/sshd_config.d/omniflow.conf';

/// How many daily backups `omni hub backup` keeps by default.
const defaultBackupKeep = 30;

/// Runs a program with no shell, as `Process.run` does. Tests pass a fake
/// so nothing reaches launchctl.
typedef HubProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> _runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

/// What the hub commands touch on this Mac: the user's home, the SSH host
/// keys, launchctl and the keychain. Tests pass a temp home, temp host key
/// files and a fake runner.
class HubEnvironment {
  HubEnvironment({
    String? userHome,
    this._hostKeyFiles,
    HubProcessRunner? run,
    this._secrets,
    DateTime Function()? now,
  }) : userHome = userHome ?? Platform.environment['HOME'] ?? '',
       run = run ?? _runProcess,
       now = now ?? DateTime.now;

  final String userHome;
  final List<String>? _hostKeyFiles;
  final HubProcessRunner run;
  final DateTime Function() now;
  SecretStore? _secrets;

  /// Where the hub's host key pins live: the keychain on the Mac.
  SecretStore get secrets => _secrets ??= KeychainSecretStore();

  String get installedBinary => '$userHome/.local/bin/omni';
  String get launchAgents => '$userHome/Library/LaunchAgents';
  String get logDir => '$userHome/Library/Logs/OmniFlow';
  String get backupDir => '$userHome/OmniFlow/backups';
  String get sshDir => '$userHome/.ssh';
  String get authorizedKeys => '$sshDir/authorized_keys';

  /// This Mac's SSH host public keys, as macOS Remote Login keeps them.
  List<String> get hostKeyFiles {
    if (_hostKeyFiles case final files?) return files;
    final dir = Directory('/etc/ssh');
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync().whereType<File>())
        if (RegExp(r'/ssh_host_[a-z0-9]+_key\.pub$').hasMatch(f.path)) f.path,
    ]..sort();
  }

  /// The user's numeric id, for `launchctl ... gui/<uid>`.
  Future<int> uid() async {
    final r = await run('/usr/bin/id', ['-u']);
    final uid = int.tryParse('${r.stdout}'.trim());
    if (r.exitCode != 0 || uid == null) {
      throw const FileSystemException('cannot read the user id with id -u');
    }
    return uid;
  }
}

/// A path that goes into a launchd plist or an `authorized_keys` command
/// as is: absolute, with no quotes, spaces or shell characters.
final _plainPath = RegExp(r'^/[A-Za-z0-9._/@+-]+$');

String _checkedPath(String path, String what) {
  if (!_plainPath.hasMatch(path) || path.contains('/../')) {
    throw UsageException(
      '$what must be an absolute path of letters, digits and . _ - / @ +',
      '',
    );
  }
  return path;
}

/// `omni hub ...`: run the hub, and set it up as the home's one engine.
class HubCommand extends Command<int> {
  HubCommand(
    Command<int> run, {
    required void Function(Command<int>) addOptions,
  }) {
    addOptions(this);
    for (final c in [
      run,
      _HubAttach(),
      _HubInstall(),
      _HubBackup(),
      _HubAllow(),
      _HubRevoke(),
      _HubPhones(),
      _HubFingerprint(),
      _HubUpdate(),
      _HubStatus(),
      _HubApi('clients', 'Who is connected to the hub now.', 'hub.clients'),
      _HubDiscover(),
    ]) {
      addSubcommand(c);
    }
  }

  @override
  String get name => 'hub';

  @override
  String get description =>
      'Run flows headless on this machine (the always-on hub), and set the '
      'hub up: omni hub on its own runs it.';
}

abstract class _HubSub extends Command<int> {
  OmniCommandRunner get omni => runner! as OmniCommandRunner;
  HubEnvironment get env => omni.hubEnvironment;

  void reply(Object? json) =>
      omni.out.writeln(const JsonEncoder.withIndent('  ').convert(json));
}

/// `omni hub attach`: copies stdin lines to the running hub's socket and
/// its replies to stdout, nothing else, so it can be an SSH forced command.
class _HubAttach extends _HubSub {
  @override
  String get name => 'attach';

  @override
  String get description =>
      'Connect stdin and stdout to the running hub, for a phone over SSH.';

  @override
  Future<int> run() async {
    final socket = await LocalClient.openSocket(omni.socketPath);
    if (socket == null) {
      throw LocalSocketException('no omni hub is running', exitCode: 69);
    }
    return attachStreams(socket, omni.input, omni.out);
  }
}

/// The message `omni hub attach` writes in place of a line it dropped.
Map<String, Object?> _droppedLine() => {
  'id': null,
  'result': {
    'ok': false,
    'error': {
      'type': 'invalid',
      'message': 'a request line over $maxLocalRequestBytes bytes was dropped',
    },
  },
};

/// Copies whole lines from [input] to [socket], dropping any line over
/// [maxLocalRequestBytes], and everything [socket] sends to [out]. Ends
/// when either side ends: input first half-closes the socket and waits for
/// the replies still owed.
Future<int> attachStreams(
  Socket socket,
  Stream<List<int>> input,
  StringSink out,
) async {
  socket.done.catchError((Object _) {});
  final decoder = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(_SinkWriter(out));
  final hubDone = Completer<void>();
  final fromHub = socket.listen(
    (bytes) {
      if (out is IOSink) {
        out.add(bytes);
      } else {
        decoder.add(bytes);
      }
    },
    onError: (Object _) {},
    onDone: () {
      if (!hubDone.isCompleted) hubDone.complete();
    },
  );
  final pending = BytesBuilder(copy: false);
  var dropping = false;
  void write(List<int> bytes) {
    try {
      socket.add(bytes);
    } on StateError {
      // The hub went away; its done ends the copy.
    }
  }

  final inputDone = Completer<void>();
  final toHub = input.listen(
    (chunk) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0A) continue;
        final part = chunk.sublist(start, i + 1);
        start = i + 1;
        if (dropping ||
            pending.length + part.length - 1 > maxLocalRequestBytes) {
          pending.clear();
          dropping = false;
          out.writeln(jsonEncode(_droppedLine()));
          continue;
        }
        pending.add(part);
        write(pending.takeBytes());
      }
      if (start < chunk.length && !dropping) {
        final rest = chunk.sublist(start);
        if (pending.length + rest.length > maxLocalRequestBytes) {
          pending.clear();
          dropping = true;
        } else {
          pending.add(rest);
        }
      }
    },
    onError: (Object _) {
      if (!inputDone.isCompleted) inputDone.complete();
    },
    onDone: () {
      if (!inputDone.isCompleted) inputDone.complete();
    },
  );
  await Future.any([inputDone.future, hubDone.future]);
  if (!hubDone.isCompleted) {
    if (pending.length > 0 && !dropping) write(pending.takeBytes());
    try {
      await socket.flush();
      await socket.close();
    } catch (_) {
      // Already closed by the hub.
    }
    await hubDone.future;
  }
  await toHub.cancel();
  await fromHub.cancel();
  decoder.close();
  socket.destroy();
  if (out is IOSink) await out.flush();
  return 0;
}

class _SinkWriter implements Sink<String> {
  _SinkWriter(this._out);

  final StringSink _out;

  @override
  void add(String data) => _out.write(data);

  @override
  void close() {}
}

/// Fills `{{name}}` in a template.
String renderHubTemplate(String name, Map<String, String> values) {
  final template = hubTemplates[name];
  if (template == null) throw StateError('no hub template $name');
  return template.replaceAllMapped(RegExp(r'\{\{(\w+)\}\}'), (m) {
    final value = values[m[1]];
    if (value == null) throw StateError('$name needs {{${m[1]}}}');
    return value;
  });
}

String _xml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _plistArguments(List<String> args) =>
    args.map((a) => '    <string>${_xml(a)}</string>').join('\n');

/// The argv that starts `omni`, with `--home` when the hub uses another.
List<String> _omniArgv(OmniCommandRunner omni, String binary) => [
  binary,
  if (omni.homeOption != null) ...[
    '--home',
    _checkedPath(Directory(omni.homeOption!).absolute.path, '--home'),
  ],
];

/// `omni hub install [--binary PATH] [--dry-run]`.
class _HubInstall extends _HubSub {
  _HubInstall() {
    argParser
      ..addOption(
        'binary',
        help: 'The installed omni. Default: ~/.local/bin/omni.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print what would be written and run, changing nothing.',
      );
  }

  @override
  String get name => 'install';

  @override
  String get description =>
      'Keep the hub running with launchd, back it up daily, and print the '
      'sshd settings to add by hand.';

  @override
  Future<int> run() async {
    final a = argResults!;
    if (a.rest.isNotEmpty) throw UsageException('takes no arguments', usage);
    final dryRun = a.flag('dry-run');
    final binary = _checkedPath(
      a.option('binary') ?? env.installedBinary,
      '--binary',
    );
    final omniArgv = _omniArgv(omni, binary);
    final hubPlist = '${env.launchAgents}/$hubLaunchLabel.plist';
    final backupPlist = '${env.launchAgents}/$backupLaunchLabel.plist';
    final files = {
      hubPlist: renderHubTemplate('$hubLaunchLabel.plist', {
        'label': hubLaunchLabel,
        'arguments': _plistArguments([...omniArgv, 'hub', '--quiet']),
        'log': _xml('${env.logDir}/hub.log'),
      }),
      backupPlist: renderHubTemplate('$backupLaunchLabel.plist', {
        'label': backupLaunchLabel,
        'keep': '$defaultBackupKeep',
        'arguments': _plistArguments([
          ...omniArgv,
          'hub',
          'backup',
          '--dir',
          env.backupDir,
          '--keep',
          '$defaultBackupKeep',
        ]),
        'log': _xml('${env.logDir}/backup.log'),
      }),
    };
    final sshd = renderHubTemplate('omniflow.sshd.conf', const {});
    final out = omni.out;
    if (!dryRun && !File(binary).existsSync()) {
      throw UsageException(
        'there is no omni at $binary. Copy it there first, or pass --binary',
        usage,
      );
    }
    final uid = dryRun ? null : await env.uid();
    final target = 'gui/${uid ?? '<uid>'}';
    final commands = [
      for (final (label, plist) in [
        (hubLaunchLabel, hubPlist),
        (backupLaunchLabel, backupPlist),
      ]) ...[
        ['/bin/launchctl', 'bootout', '$target/$label'],
        ['/bin/launchctl', 'bootstrap', target, plist],
      ],
    ];
    if (dryRun) {
      for (final MapEntry(:key, :value) in files.entries) {
        out
          ..writeln('Would write $key:')
          ..writeln(value);
      }
      out.writeln('Would make ${env.logDir} and ${env.backupDir}, then run:');
      for (final c in commands) {
        out.writeln('  ${c.join(' ')}');
      }
    } else {
      for (final dir in [env.launchAgents, env.logDir, env.backupDir]) {
        await Directory(dir).create(recursive: true);
      }
      for (final MapEntry(:key, :value) in files.entries) {
        await File(key).writeAsString(value, flush: true);
      }
      for (final c in commands) {
        final r = await env.run(c.first, c.sublist(1));
        // bootout fails when nothing is loaded yet, which is fine.
        if (r.exitCode != 0 && c[1] == 'bootstrap') {
          throw FileSystemException(
            'launchctl bootstrap failed: ${'${r.stderr}'.trim()}',
            c.last,
          );
        }
      }
      for (final key in files.keys) {
        out.writeln('Wrote $key');
      }
      out.writeln('The hub runs now, and starts again at login.');
    }
    out
      ..writeln()
      ..writeln(
        'Put this in $sshdSnippetPath (it needs sudo, so omni does not '
        'write it):',
      )
      ..write(sshd);
    return 0;
  }
}

/// `omni hub backup [--dir DIR] [--keep N]`: one dated backup of the hub's
/// home, as `omni config export` writes it, keeping the newest N.
class _HubBackup extends _HubSub {
  _HubBackup() {
    argParser
      ..addOption('dir', help: 'Where backups go. Default: ~/OmniFlow/backups.')
      ..addOption(
        'keep',
        defaultsTo: '$defaultBackupKeep',
        help: 'How many backups to keep.',
      );
  }

  @override
  String get name => 'backup';

  @override
  String get description =>
      'Write omniflow-<date>.json and keep the newest ones (the daily job).';

  @override
  Future<int> run() async {
    final a = argResults!;
    final keep = int.tryParse(a.option('keep')!);
    if (keep == null || keep < 1 || keep > 3650) {
      throw UsageException('--keep is 1 to 3650', usage);
    }
    final dir = Directory(a.option('dir') ?? env.backupDir);
    final engine = await omni.connect();
    final Map<String, Object?> result;
    try {
      result = await engine.handle('config.export', const {});
    } finally {
      await engine.close();
    }
    if (result['ok'] != true) {
      reply(result);
      return 1;
    }
    await dir.create(recursive: true);
    final date = env.now().toIso8601String().substring(0, 10);
    final file = File('${dir.path}/omniflow-$date.json');
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(result['backup'])}\n',
      flush: true,
    );
    final backups = [
      for (final f in dir.listSync().whereType<File>())
        if (RegExp(r'/omniflow-\d{4}-\d{2}-\d{2}\.json$').hasMatch(f.path)) f,
    ]..sort((x, y) => y.path.compareTo(x.path));
    final removed = <String>[];
    for (final old in backups.skip(keep)) {
      await old.delete();
      removed.add(old.path);
    }
    reply({'ok': true, 'out': file.path, 'removed': removed});
    return 0;
  }
}

/// The public key types a phone may use.
const hubKeyTypes = {'ssh-ed25519', 'ecdsa-sha2-nistp256'};

/// A phone's name is also the id of its phone thing on the hub, so it
/// follows the thing id rule.
final _phoneName = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// The comment that marks a phone's `authorized_keys` line as OmniFlow's.
String phoneKeyComment(String name) => 'omniflow-$name';

/// One public key, checked.
class HubPublicKey {
  const HubPublicKey(this.type, this.base64);

  final String type;
  final String base64;

  /// `SHA256:<base64>`, as ssh-keygen -l prints it.
  String get fingerprint => sshFingerprint(base64Decode(base64));

  /// Parses one `ssh-ed25519 AAAA... [comment]` or
  /// `ecdsa-sha2-nistp256 AAAA... [comment]` line, with no options and no
  /// newline. Throws [FormatException] with a plain reason.
  static HubPublicKey parse(String line) {
    if (line.contains('\n') || line.contains('\r')) {
      throw const FormatException('the key is one line');
    }
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || !hubKeyTypes.contains(parts.first)) {
      throw FormatException(
        'the key is one public key line starting ${hubKeyTypes.join(' or ')}, '
        'with no options',
      );
    }
    final List<int> blob;
    try {
      blob = base64Decode(parts[1]);
    } on FormatException {
      throw const FormatException('the key is not valid base64');
    }
    final type = _sshString(blob, 0);
    if (type == null ||
        utf8.decode(type.$1, allowMalformed: true) != parts[0]) {
      throw const FormatException('the key does not match its type');
    }
    final expected = parts[0] == 'ssh-ed25519' ? 51 : 104;
    if (blob.length != expected) {
      throw const FormatException('the key is the wrong length for its type');
    }
    return HubPublicKey(parts[0], parts[1]);
  }
}

/// One SSH wire string at [at] in [blob]: its bytes and where the next one
/// starts, or null when it runs past the end.
(List<int>, int)? _sshString(List<int> blob, int at) {
  if (at + 4 > blob.length) return null;
  final length =
      (blob[at] << 24) |
      (blob[at + 1] << 16) |
      (blob[at + 2] << 8) |
      blob[at + 3];
  final end = at + 4 + length;
  if (length < 0 || end > blob.length) return null;
  return (blob.sublist(at + 4, end), end);
}

/// `SHA256:<base64 without padding>` of a key blob, as OpenSSH prints it.
String sshFingerprint(List<int> blob) {
  final digest = SHA256Digest().process(Uint8List.fromList(blob));
  return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
}

/// One phone's line in `authorized_keys`.
class PhoneKeyLine {
  const PhoneKeyLine(this.name, this.key, this.from, this.line);

  final String name;
  final HubPublicKey key;
  final String? from;
  final String line;

  Map<String, Object?> toJson() => {
    'name': name,
    'type': key.type,
    'fingerprint': key.fingerprint,
    'from': ?from,
  };

  static final _shape = RegExp(
    r'^restrict,(?:from="([^"]*)",)?command="[^"]*" (\S+) (\S+) omniflow-([A-Za-z0-9_-]{1,32})$',
  );

  /// The phone line [line] is, or null for any other line.
  static PhoneKeyLine? parse(String line) {
    final m = _shape.firstMatch(line.trimRight());
    if (m == null) return null;
    try {
      return PhoneKeyLine(
        m[4]!,
        HubPublicKey.parse('${m[2]} ${m[3]}'),
        m[1],
        line,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Checks `--from`: comma separated addresses or CIDR ranges.
String _checkedFrom(String from) {
  final parts = from.split(',');
  for (final p in parts) {
    final slash = p.indexOf('/');
    final address = InternetAddress.tryParse(
      slash < 0 ? p : p.substring(0, slash),
    );
    final bits = slash < 0 ? null : int.tryParse(p.substring(slash + 1));
    final max = address?.type == InternetAddressType.IPv6 ? 128 : 32;
    if (address == null ||
        (slash >= 0 && (bits == null || bits < 0 || bits > max))) {
      throw UsageException(
        '--from is addresses or ranges like 192.168.1.0/24,100.64.0.0/10',
        '',
      );
    }
  }
  return from;
}

/// The authorized_keys file: read with every line kept as it is, and
/// written whole through a 0600 file renamed into place in a 0700 ~/.ssh.
class _AuthorizedKeys {
  _AuthorizedKeys(this.env);

  final HubEnvironment env;

  File get _file => File(env.authorizedKeys);

  Future<List<String>> read() async {
    if (!await _file.exists()) return [];
    return const LineSplitter().convert(await _file.readAsString());
  }

  Future<void> _privateSshDir() async {
    final dir = Directory(env.sshDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _chmod('700', dir.path);
      return;
    }
    final mode = (await dir.stat()).mode;
    if (mode & groupOrOtherWrite != 0) {
      throw LocalSocketException(
        '${dir.path} is writable by other users, and sshd ignores keys there. '
        'Run chmod 700 ${dir.path}',
      );
    }
  }

  Future<void> write(List<String> lines) async {
    await _privateSshDir();
    final temp = File('${env.authorizedKeys}.omniflow-$pid');
    await temp.writeAsString('');
    await _chmod('600', temp.path);
    await temp.writeAsString(
      lines.isEmpty ? '' : '${lines.join('\n')}\n',
      flush: true,
    );
    await temp.rename(env.authorizedKeys);
  }

  static Future<void> _chmod(String mode, String path) async {
    final r = await Process.run('/bin/chmod', [mode, path]);
    if (r.exitCode != 0) {
      throw FileSystemException('cannot set mode $mode', path);
    }
  }
}

String _checkedName(List<String> rest, String usage) {
  if (rest.isEmpty) throw UsageException('needs NAME', usage);
  final name = rest.first;
  if (!_phoneName.hasMatch(name)) {
    throw UsageException(
      'NAME is 1 to 32 lower-case letters, digits and _, starting with a letter',
      usage,
    );
  }
  return name;
}

/// `omni hub allow NAME KEY [--from CIDRS] [--binary PATH]`.
/// `omni hub allow NAME KEY [--person PERSON] [--from CIDRS] [--binary PATH]`.
/// NAME is also the phone thing the phone's readings name, so the hub
/// makes it when it is missing.
class _HubAllow extends _HubSub {
  _HubAllow() {
    argParser
      ..addOption(
        'person',
        help: 'The person this phone belongs to, a person thing on the hub.',
      )
      ..addOption(
        'from',
        help: 'Only from these addresses, like 192.168.1.0/24,100.64.0.0/10.',
      )
      ..addOption(
        'binary',
        help: 'The omni the key may run. Default: ~/.local/bin/omni.',
      );
  }

  @override
  String get name => 'allow';

  @override
  String get description =>
      'Let a phone in: adds its key to ~/.ssh/authorized_keys, able to run '
      'only omni hub attach, and makes its phone thing on the hub.';

  @override
  String get invocation => 'omni hub allow NAME KEY';

  @override
  Future<int> run() async {
    final a = argResults!;
    final name = _checkedName(a.rest, usage);
    if (a.rest.length < 2) throw UsageException('needs NAME and KEY', usage);
    final HubPublicKey key;
    try {
      key = HubPublicKey.parse(a.rest.skip(1).join(' '));
    } on FormatException catch (e) {
      throw UsageException(e.message, usage);
    }
    final person = a.option('person');
    if (person != null && !_thingId.hasMatch(person)) {
      throw UsageException('--person is the id of a person thing', usage);
    }
    final from = a.option('from') == null
        ? null
        : _checkedFrom(a.option('from')!);
    final binary = _checkedPath(
      a.option('binary') ?? env.installedBinary,
      '--binary',
    );
    final command = [..._omniArgv(omni, binary), 'hub', 'attach'].join(' ');
    final line =
        'restrict,${from == null ? '' : 'from="$from",'}command="$command" '
        '${key.type} ${key.base64} ${phoneKeyComment(name)}';
    final keys = _AuthorizedKeys(env);
    final lines = await keys.read();
    var present = false;
    for (final existing in lines) {
      final phone = PhoneKeyLine.parse(existing);
      if (phone == null) continue;
      if (phone.name == name && existing == line) {
        present = true;
      } else if (phone.name == name) {
        reply(
          _conflict('$name already has a key. Run omni hub revoke $name first'),
        );
        return 1;
      } else if (phone.key.base64 == key.base64) {
        reply(_conflict('that key is already allowed as ${phone.name}'));
        return 1;
      }
    }
    final thing = await _ensurePhoneThing(name, person);
    if (thing['ok'] != true) {
      reply(thing);
      return 1;
    }
    if (!present) await keys.write([...lines, line]);
    reply({
      'ok': true,
      'name': name,
      'changed': !present,
      'fingerprint': key.fingerprint,
      'phone': thing['phone'],
    });
    return 0;
  }

  /// Makes the phone thing [name] on the hub, or checks the one there, with
  /// [person] as its person when given. Through the running hub when one
  /// runs, else the engine opened here.
  Future<Map<String, Object?>> _ensurePhoneThing(
    String name,
    String? person,
  ) async {
    final engine = await omni.connect();
    try {
      if (person != null) {
        final got = await engine.handle('device.get', {'id': person});
        final driver = (got['device'] as Map?)?['driver'];
        if (got['ok'] != true || driver != 'person') {
          return {
            'ok': false,
            'error': {
              'type': 'not_found',
              'message':
                  'there is no person $person on the hub. Add one with '
                  'omni device add $person --driver person',
            },
          };
        }
      }
      final existing = await engine.handle('device.get', {'id': name});
      if (existing['ok'] != true) {
        final added = await engine.handle('device.add', {
          'id': name,
          'driver': 'phone',
          'name': name,
          'settings': {'person': ?person},
        });
        if (added['ok'] != true) return added;
        return {
          'ok': true,
          'phone': {'id': name, 'created': true, 'person': ?person},
        };
      }
      final device = Map<String, Object?>.from(existing['device'] as Map);
      if (device['driver'] != 'phone') {
        return _conflict(
          '$name is already a thing on the hub that is not a phone. Pick '
          'another name',
        );
      }
      final settings = device['settings'];
      final current = settings is Map ? settings['person'] : null;
      if (person != null && current != person) {
        final set = await engine.handle('thing.configure', {
          'id': name,
          'settings': {'person': person},
        });
        if (set['ok'] != true) return set;
      }
      return {
        'ok': true,
        'phone': {'id': name, 'created': false, 'person': person ?? current},
      };
    } finally {
      await closeOneShot(engine);
    }
  }
}

final _thingId = RegExp(r'^[a-z][a-z0-9_]*$');

Map<String, Object?> _conflict(String message) => {
  'ok': false,
  'error': {'type': 'conflict', 'message': message},
};

/// `omni hub revoke NAME`: removes that phone's line and nothing else.
class _HubRevoke extends _HubSub {
  @override
  String get name => 'revoke';

  @override
  String get description =>
      'Shut a phone out: removes its authorized_keys line. Its phone thing '
      'stays.';

  @override
  String get invocation => 'omni hub revoke NAME';

  @override
  Future<int> run() async {
    final name = _checkedName(argResults!.rest, usage);
    if (argResults!.rest.length != 1) throw UsageException('needs NAME', usage);
    final keys = _AuthorizedKeys(env);
    final lines = await keys.read();
    final kept = [
      for (final l in lines)
        if (PhoneKeyLine.parse(l)?.name != name) l,
    ];
    if (kept.length == lines.length) {
      reply({
        'ok': false,
        'error': {'type': 'not_found', 'message': 'no phone $name is allowed'},
      });
      return 1;
    }
    await keys.write(kept);
    reply({
      'ok': true,
      'name': name,
      'removed': true,
      'note':
          'the phone thing $name stays on the hub with its history. Remove it '
          'with omni device remove $name',
    });
    return 0;
  }
}

/// `omni hub phones`: the phones allowed in.
class _HubPhones extends _HubSub {
  @override
  String get name => 'phones';

  @override
  String get description => 'List the phones allowed to reach the hub.';

  @override
  Future<int> run() async {
    final lines = await _AuthorizedKeys(env).read();
    reply({
      'ok': true,
      'phones': [
        for (final l in lines)
          if (PhoneKeyLine.parse(l) case final p?) p.toJson(),
      ],
    });
    return 0;
  }
}

/// The size in bits of a host key, as ssh-keygen -l prints it.
int? _keyBits(String type, List<int> blob) {
  if (type == 'ssh-ed25519') return 256;
  final ecdsa = RegExp(r'^ecdsa-sha2-nistp(\d+)$').firstMatch(type);
  if (ecdsa != null) return int.parse(ecdsa[1]!);
  if (type == 'ssh-rsa') {
    final name = _sshString(blob, 0);
    final e = name == null ? null : _sshString(blob, name.$2);
    final n = e == null ? null : _sshString(blob, e.$2);
    if (n == null) return null;
    var bytes = n.$1;
    while (bytes.isNotEmpty && bytes.first == 0) {
      bytes = bytes.sublist(1);
    }
    if (bytes.isEmpty) return 0;
    return (bytes.length - 1) * 8 + bytes.first.bitLength;
  }
  return null;
}

/// `omni hub fingerprint`: this Mac's SSH host keys, to match on a phone.
class _HubFingerprint extends _HubSub {
  @override
  String get name => 'fingerprint';

  @override
  String get description =>
      "This Mac's SSH host key fingerprints, to check on the phone.";

  @override
  Future<int> run() async {
    final keys = <Map<String, Object?>>[];
    for (final path in env.hostKeyFiles) {
      final parts = (await File(
        path,
      ).readAsString()).trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final List<int> blob;
      try {
        blob = base64Decode(parts[1]);
      } on FormatException {
        continue;
      }
      final fingerprint = sshFingerprint(blob);
      keys.add({
        'type': parts[0],
        'fingerprint': fingerprint,
        'bits': ?_keyBits(parts[0], blob),
        'file': path,
      });
    }
    if (keys.isEmpty) {
      reply({
        'ok': false,
        'error': {
          'type': 'not_found',
          'message':
              'no SSH host keys in /etc/ssh. Turn on Remote Login in System '
              'Settings, General, Sharing',
        },
      });
      return 1;
    }
    reply({'ok': true, 'keys': keys});
    return 0;
  }
}

/// `omni hub update BINARY [--binary PATH]`: puts a new omni in place and
/// restarts the hub with it.
class _HubUpdate extends _HubSub {
  _HubUpdate() {
    argParser.addOption(
      'binary',
      help: 'The installed omni to replace. Default: ~/.local/bin/omni.',
    );
  }

  @override
  String get name => 'update';

  @override
  String get description =>
      'Replace the installed omni with BINARY and restart the hub.';

  @override
  String get invocation => 'omni hub update BINARY';

  @override
  Future<int> run() async {
    final a = argResults!;
    if (a.rest.length != 1) throw UsageException('needs BINARY', usage);
    final source = File(a.rest.single);
    if (!await source.exists()) {
      throw FileSystemException('no such file', source.path);
    }
    final installed = _checkedPath(
      a.option('binary') ?? env.installedBinary,
      '--binary',
    );
    if (source.absolute.path == File(installed).absolute.path) {
      throw UsageException('BINARY is already the installed omni', usage);
    }
    await Directory(File(installed).parent.path).create(recursive: true);
    final temp = '$installed.new-$pid';
    await source.copy(temp);
    final chmod = await Process.run('/bin/chmod', ['755', temp]);
    if (chmod.exitCode != 0) {
      await File(temp).delete();
      throw FileSystemException('cannot make it executable', temp);
    }
    await File(temp).rename(installed);
    final uid = await env.uid();
    final restart = await env.run('/bin/launchctl', [
      'kickstart',
      '-k',
      'gui/$uid/$hubLaunchLabel',
    ]);
    reply({
      'ok': restart.exitCode == 0,
      'installed': installed,
      'restarted': restart.exitCode == 0,
      if (restart.exitCode != 0)
        'error': {
          'type': 'unavailable',
          'message':
              'the binary is in place, but launchctl kickstart failed: '
              '${'${restart.stderr}'.trim()}. Run omni hub install',
        },
    });
    return restart.exitCode == 0 ? 0 : 1;
  }
}

/// `omni hub status`: uptime, version, who is connected, the last run and
/// load issues, from the running hub only.
class _HubStatus extends _HubSub {
  @override
  String get name => 'status';

  @override
  String get description =>
      'Uptime, version, connected phones, the last run and load issues.';

  @override
  Future<int> run() async {
    final hub = await omni.connectToHub();
    try {
      final status = await hub.handle('engine.status', const {});
      if (status['ok'] != true) {
        reply(status);
        return 1;
      }
      final clients = await hub.handle('hub.clients', const {});
      final log = await hub.handle('flow.log', const {'limit': 1});
      final runs = log['runs'];
      reply({
        'ok': true,
        'version': status['version'],
        'startedAt': status['startedAt'],
        'uptimeSeconds': status['uptimeSeconds'],
        'hubRunning': status['hubRunning'],
        'clients': clients['clients'] ?? const [],
        'lastRun': runs is List && runs.isNotEmpty ? runs.first : null,
        'loadIssues': status['loadIssues'],
      });
      return 0;
    } finally {
      await hub.close();
    }
  }
}

/// A hub command that sends one core API command to the running hub.
class _HubApi extends _HubSub {
  _HubApi(this.name, this.description, this.command);

  @override
  final String name;
  @override
  final String description;
  final String command;

  Map<String, Object?> args() => const {};

  @override
  Future<int> run() async {
    final hub = await omni.connectToHub();
    try {
      final result = await hub.handle(command, args());
      reply(result);
      return result['ok'] == true ? 0 : 1;
    } finally {
      await hub.close();
    }
  }
}

/// `omni hub discover [--window-ms MS]`: Macs offering Remote Login.
class _HubDiscover extends _HubSub {
  _HubDiscover() {
    argParser.addOption(
      'window-ms',
      defaultsTo: '3000',
      help: 'How long to listen.',
    );
  }

  @override
  String get name => 'discover';

  @override
  String get description =>
      'Find Macs on this network that offer Remote Login (SSH), over mDNS.';

  @override
  Future<int> run() async {
    final ms = int.tryParse(argResults!.option('window-ms')!);
    if (ms == null) throw UsageException('--window-ms needs a number', usage);
    final engine = await omni.connect();
    try {
      final result = await engine.handle('hub.discover', {'windowMs': ms});
      reply(result);
      return result['ok'] == true ? 0 : 1;
    } finally {
      await engine.close();
    }
  }
}
