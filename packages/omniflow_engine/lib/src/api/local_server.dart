import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'hub_phone_session.dart';
import 'hub_runtime.dart' show HubClient;
import 'local_client.dart';
import 'omni_engine.dart';
import '../transports/ndjson.dart';
import '../version.dart';

/// The first message a client may send to name itself in `hub.clients`.
const helloCommand = 'hello';

/// Unix domain socket paths are capped by `sun_path`: 104 bytes on macOS,
/// 108 on Linux, each counting the closing NUL. A bind past the cap fails
/// and leaks a handle that keeps the process from exiting.
const _maxSocketPathBytes = 103;

/// How many commands one connection runs at once. More wait their turn.
const _maxInFlight = 8;

/// Makes [home] private before a hub serves its socket there: created at
/// mode 0700 when missing, tightened to 0700 when others can read it, and
/// refused when others can write it, since they could swap the socket.
Future<void> preparePrivateHome(Directory home) async {
  final path = home.absolute.path;
  if (!await home.exists()) await home.create(recursive: true);
  final mode = (await home.stat()).mode;
  if (mode & groupOrOtherWrite != 0) {
    throw LocalSocketException(
      '$path is writable by other users (mode ${octalMode(mode)}), so the hub '
      'will not serve a control socket there. Run chmod 700 $path',
    );
  }
  if (mode & groupOrOtherAny != 0) await _chmod('700', path);
}

Future<void> _chmod(String mode, String absolutePath) async {
  // Android keeps chmod in /system/bin.
  final chmod = File('/bin/chmod').existsSync()
      ? '/bin/chmod'
      : '/system/bin/chmod';
  final result = await Process.run(chmod, [mode, absolutePath]);
  if (result.exitCode != 0) {
    throw LocalSocketException(
      'cannot set mode $mode on $absolutePath: ${result.stderr}'.trim(),
    );
  }
}

/// The hub's local control sockets, Unix domain sockets at mode 0600 in a
/// 0700 directory: no network interface, and no other user, can reach them.
///
/// `omni.sock` is the Mac's own: each connection may send any core API
/// command and subscribe to engine events, so a client can do nothing the
/// CLI cannot. `omni-phone.sock` is for phone sessions only, which come
/// through `omni hub attach --phone NAME`, the forced command of each
/// phone's key. Its first line names the phone, before any line from the
/// phone itself, and every command after it passes a [PhoneGate]: no
/// driver registration, nothing that runs a program or reads a file on the
/// Mac, and the phone, its person, asks and action replies taken from the
/// session. Its events are only the ones for that phone.
class LocalServer {
  LocalServer._(
    this.path,
    this.phonePath,
    this._engine,
    this._server,
    this._phoneServer,
  ) {
    _server.listen((s) => _serve(s, phone: false));
    _phoneServer.listen((s) => _serve(s, phone: true));
    _deviceEvents = _engine.events.listen(_watchPhones);
  }

  final String path;

  /// The phone sessions' socket, beside [path].
  final String phonePath;
  final OmniEngine _engine;
  final ServerSocket _server;
  final ServerSocket _phoneServer;
  final _connections = <_Connection>{};
  late final StreamSubscription<Map<String, Object?>> _deviceEvents;
  var _closed = false;

  /// The phone things on the hub, for what one phone may see of another.
  final _phoneThings = <String>{};
  Future<void>? _phonesLoaded;

  /// Serves [engine] at [path], by default `<home>/omni.sock`, and phone
  /// sessions at `omni-phone.sock` beside it. A socket file left by a hub
  /// that died is replaced; one that still answers is another hub, and is
  /// refused.
  static Future<LocalServer> start(
    OmniEngine engine, {
    required Directory home,
    String? path,
  }) async {
    await preparePrivateHome(home);
    final socketPath = File(path ?? localSocketPath(home)).absolute.path;
    final phoneSocket = phoneSocketPath(socketPath);
    final dir = File(socketPath).parent;
    if (dir.absolute.path != home.absolute.path) {
      final mode = (await dir.stat()).mode;
      if (mode & groupOrOtherWrite != 0) {
        throw LocalSocketException(
          '${dir.path} is writable by other users (mode ${octalMode(mode)}), '
          'so the hub will not serve a control socket there',
        );
      }
    }
    for (final p in [socketPath, phoneSocket]) {
      if (utf8.encode(p).length > _maxSocketPathBytes) {
        throw LocalSocketException(
          'the socket path $p is longer than $_maxSocketPathBytes '
          'bytes, the limit for a Unix socket. Use a shorter --home',
          exitCode: 73,
        );
      }
    }
    await _clearStale(socketPath);
    await _clearStale(phoneSocket);
    final server = await _bind(socketPath);
    final ServerSocket phoneServer;
    try {
      phoneServer = await _bind(phoneSocket);
    } catch (_) {
      await server.close();
      rethrow;
    }
    return LocalServer._(socketPath, phoneSocket, engine, server, phoneServer);
  }

  static Future<ServerSocket> _bind(String socketPath) async {
    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(address, 0);
    } on SocketException catch (e) {
      throw LocalSocketException(
        'cannot serve $socketPath: ${e.osError?.message ?? e.message}',
        exitCode: 73,
      );
    }
    try {
      await _chmod('600', socketPath);
    } catch (_) {
      await server.close();
      rethrow;
    }
    return server;
  }

  static Future<void> _clearStale(String socketPath) async {
    final type = await FileSystemEntity.type(socketPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.unixDomainSock) {
      throw LocalSocketException(
        '$socketPath exists and is not a socket. Move it away to run the hub',
        exitCode: 73,
      );
    }
    try {
      final live = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      ).timeout(LocalClient.connectTimeout);
      live.destroy();
    } on SocketException {
      await File(socketPath).delete();
      return;
    } on TimeoutException {
      // Falls through: a socket that accepts slowly is still someone's.
    }
    throw LocalSocketException(
      'another omni hub is serving $socketPath',
      exitCode: 75,
    );
  }

  void _watchPhones(Map<String, Object?> event) {
    if (event['event'] != 'device.stateChanged') return;
    final device = event['device'];
    if (device is Map &&
        device['driver'] == 'phone' &&
        device['id'] is String) {
      _phoneThings.add(device['id'] as String);
    }
  }

  Future<void> _loadPhones() => _phonesLoaded ??= () async {
    final listed = await _engine.handle('device.list', const {});
    final devices = listed['devices'];
    if (devices is! List) return;
    for (final d in devices) {
      if (d is Map && d['driver'] == 'phone' && d['id'] is String) {
        _phoneThings.add(d['id'] as String);
      }
    }
  }();

  /// The phone session [header] names, or why there is none.
  Future<(PhoneSession?, String?)> _session(NdjsonLine header) async {
    final json = header.json;
    final phone = json?['phone'];
    if (json == null ||
        json[phoneSessionKey] != phoneSessionValue ||
        phone is! String ||
        !phoneNamePattern.hasMatch(phone)) {
      return (null, 'this socket is for omni hub attach --phone NAME only');
    }
    final got = await _engine.handle('device.get', {'id': phone});
    final device = got['device'];
    if (got['ok'] != true || device is! Map || device['driver'] != 'phone') {
      return (
        null,
        'the hub has no phone $phone. On the Mac, run omni hub allow '
            '$phone again',
      );
    }
    final settings = device['settings'];
    final person = settings is Map ? settings['person'] : null;
    await _loadPhones();
    _phoneThings.add(phone);
    return (
      PhoneSession(
        phone,
        person: person is String && person.isNotEmpty ? person : null,
      ),
      null,
    );
  }

  void _serve(Socket socket, {required bool phone}) {
    if (_closed) {
      socket.destroy();
      return;
    }
    final client = _engine.hubClients.connect();
    late final _Connection connection;
    connection = _Connection(socket, _engine, client, phone ? this : null, () {
      _engine.hubClients.disconnect(client);
      _connections.remove(connection);
    });
    _connections.add(connection);
  }

  /// Stops accepting, lets the commands in flight answer, then drops every
  /// connection and removes the socket files.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    await _phoneServer.close();
    await _deviceEvents.cancel();
    for (final c in _connections.toList()) {
      await c.close();
    }
    for (final p in [path, phonePath]) {
      try {
        if (await FileSystemEntity.type(p, followLinks: false) ==
            FileSystemEntityType.unixDomainSock) {
          await File(p).delete();
        }
      } on FileSystemException {
        // Already gone: ServerSocket.close removes it on most platforms.
      }
    }
  }
}

class _Connection {
  _Connection(
    this._socket,
    this._engine,
    this._client,
    this._phones,
    this._onClosed,
  ) {
    _socket.done.catchError((Object _) {});
    if (_phones == null) _ready = Future.value();
    _lines = _socket
        .cast<List<int>>()
        .transform(const NdjsonDecoder(maxLineLength: maxLocalRequestBytes))
        .listen(_take, onError: (Object _) => close(), onDone: close);
  }

  final Socket _socket;
  final OmniEngine _engine;
  final HubClient _client;

  /// The server, on the phone socket only.
  final LocalServer? _phones;
  final void Function() _onClosed;
  late final StreamSubscription<NdjsonLine> _lines;
  final _subscriptions = <StreamSubscription<Map<String, Object?>>>[];

  /// Completes once the phone session's header was checked: at once on the
  /// Mac's own socket.
  Future<void>? _ready;
  PhoneGate? _gate;
  var _refused = false;

  final _waiting = Queue<NdjsonLine>();
  final _inFlight = <Future<void>>{};
  var _closed = false;

  void _take(NdjsonLine line) {
    if (_closing != null) return;
    if (_ready == null) {
      _ready = _open(line);
      return;
    }
    final json = line.json;
    if (json?['command'] == pingCommand && json?['id'] is int) {
      _send({
        'id': json!['id'],
        'result': {'ok': true, 'pong': true},
      });
      return;
    }
    _waiting.add(line);
    _pump();
  }

  void _pump() {
    while (_inFlight.length < _maxInFlight && _waiting.isNotEmpty) {
      final line = _waiting.removeFirst();
      late final Future<void> work;
      work = _answerReady(line).catchError((Object _) {}).whenComplete(() {
        _inFlight.remove(work);
        _pump();
      });
      _inFlight.add(work);
    }
  }

  Future<void> _open(NdjsonLine header) async {
    final (session, problem) = await _phones!._session(header);
    if (session == null) {
      _refused = true;
      _send({
        'id': null,
        'result': {
          'ok': false,
          'error': {'type': 'not_allowed', 'message': problem},
        },
      });
      unawaited(close());
      return;
    }
    _client
      ..phone = session.phone
      ..phoneSession = true;
    _gate = PhoneGate(session, _engine.handle);
  }

  Future<void> _answerReady(NdjsonLine line) async {
    await _ready;
    if (_refused) return;
    await _answer(line);
  }

  Future<void> _answer(NdjsonLine line) async {
    final json = line.json;
    final id = json?['id'];
    if (json == null || id is! int) {
      _send({
        'id': id is int ? id : null,
        'result': _invalid('each line is one JSON object with an integer id'),
      });
      return;
    }
    if (json.containsKey('subscribe')) {
      _subscribe(id, json);
      return;
    }
    final command = json['command'];
    final args = json['args'] ?? const <String, Object?>{};
    if (command is! String || args is! Map) {
      _send({
        'id': id,
        'result': _invalid('a request has a command string and an args object'),
      });
      return;
    }
    if (command == helloCommand) {
      _send({'id': id, 'result': _hello(Map<String, Object?>.from(args))});
      return;
    }
    _client.lastCommandAt = DateTime.now();
    var sent = Map<String, Object?>.from(args);
    if (_gate case final gate?) {
      final admitted = await gate.admit(command, sent);
      if (admitted.refusal case final why?) {
        _send({
          'id': id,
          'result': {
            'ok': false,
            'error': {'type': 'not_allowed', 'message': why},
          },
        });
        return;
      }
      sent = admitted.args;
    }
    final result = await _engine.handle(command, sent);
    _send({'id': id, 'result': result});
  }

  /// `hello {client, phone?}` names this connection in `hub.clients`. It is
  /// the socket's own, not an engine command, and answers with the engine
  /// version so a client can check it before anything else. A phone
  /// session's phone is its key's, so `phone` here is ignored, and the
  /// answer says which phone and person the hub took it for.
  Map<String, Object?> _hello(Map<String, Object?> args) {
    final session = _gate?.session;
    try {
      _engine.hubClients.hello(_client, args, sessionPhone: session?.phone);
    } on ApiError catch (e) {
      return {'ok': false, 'error': e.toJson()};
    }
    return {
      'ok': true,
      'version': omniflowEngineVersion,
      'id': _client.id,
      if (session != null) ...{
        'phone': session.phone,
        'person': ?session.person,
      },
    };
  }

  void _subscribe(int id, Map<String, Object?> json) {
    if (json['subscribe'] != 'events') {
      _send({'id': id, 'result': _invalid('only "events" can be subscribed')});
      return;
    }
    final gate = _gate;
    final phones = _phones;
    final filter = gate == null || phones == null
        ? null
        : PhoneEventFilter(gate.session, phones._phoneThings.contains);
    final packets = filter == null && json['packets'] == true;
    _client.subscribed = true;
    _subscriptions.add(
      _engine.events
          .where((e) => packets || e['event'] != 'packet.captured')
          .where((e) => filter?.allows(e) ?? true)
          .listen((e) => _send({'id': id, 'event': e})),
    );
    _send({
      'id': id,
      'result': {'ok': true, 'subscribed': 'events'},
    });
  }

  static Map<String, Object?> _invalid(String message) => {
    'ok': false,
    'error': {'type': 'invalid', 'message': message},
  };

  void _send(Map<String, Object?> message) {
    if (_closed) return;
    final String text;
    try {
      text = jsonEncode(message);
    } on JsonUnsupportedObjectError {
      return;
    }
    _socket.add(utf8.encode('$text\n'));
  }

  Future<void>? _closing;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _waiting.clear();
    await Future.wait(_inFlight.toList());
    _closed = true;
    try {
      await _socket.flush().timeout(const Duration(seconds: 1));
    } catch (_) {
      // The client may have gone first.
    }
    _socket.destroy();
    // Not awaited: the line decoder is an async* generator parked on the
    // socket, and its cancel would wait for a line that never comes.
    _lines.cancel().ignore();
    _onClosed();
  }
}
