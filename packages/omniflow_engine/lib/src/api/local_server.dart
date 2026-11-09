import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_client.dart';
import 'omni_engine.dart';
import '../transports/ndjson.dart';

/// Unix domain socket paths are capped by `sun_path`: 104 bytes on macOS,
/// 108 on Linux, each counting the closing NUL. A bind past the cap fails
/// and leaks a handle that keeps the process from exiting.
const _maxSocketPathBytes = 103;

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
  final result = await Process.run('/bin/chmod', [mode, absolutePath]);
  if (result.exitCode != 0) {
    throw LocalSocketException(
      'cannot set mode $mode on $absolutePath: ${result.stderr}'.trim(),
    );
  }
}

/// The hub's local control socket. Each connection may send core API
/// commands and subscribe to engine events. It only calls
/// [OmniEngine.handle] and [OmniEngine.events], so a client can do nothing
/// the CLI cannot. It is a Unix domain socket at mode 0600 in a 0700
/// directory: no network interface, and no other user, can reach it.
class LocalServer {
  LocalServer._(this.path, this._engine, this._server) {
    _server.listen(_serve);
  }

  final String path;
  final OmniEngine _engine;
  final ServerSocket _server;
  final _connections = <_Connection>{};
  var _closed = false;

  /// Serves [engine] at [path], by default `<home>/omni.sock`. A socket file
  /// left by a hub that died is replaced; one that still answers is
  /// another hub, and is refused.
  static Future<LocalServer> start(
    OmniEngine engine, {
    required Directory home,
    String? path,
  }) async {
    await preparePrivateHome(home);
    final socketPath = File(path ?? localSocketPath(home)).absolute.path;
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
    if (utf8.encode(socketPath).length > _maxSocketPathBytes) {
      throw LocalSocketException(
        'the socket path $socketPath is longer than $_maxSocketPathBytes '
        'bytes, the limit for a Unix socket. Use a shorter --home',
        exitCode: 73,
      );
    }
    await _clearStale(socketPath);
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
    return LocalServer._(socketPath, engine, server);
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

  void _serve(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    late final _Connection connection;
    connection = _Connection(socket, _engine, () {
      _connections.remove(connection);
    });
    _connections.add(connection);
  }

  /// Stops accepting, lets the commands in flight answer, then drops every
  /// connection and removes the socket file.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    for (final c in _connections.toList()) {
      await c.close();
    }
    try {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.unixDomainSock) {
        await File(path).delete();
      }
    } on FileSystemException {
      // Already gone: ServerSocket.close removes it on most platforms.
    }
  }
}

class _Connection {
  _Connection(this._socket, this._engine, this._onClosed) {
    _socket.done.catchError((Object _) {});
    _lines = _socket
        .cast<List<int>>()
        .transform(const NdjsonDecoder(maxLineLength: maxLocalRequestBytes))
        .listen(
          (line) {
            if (_closing != null) return;
            _queue = _queue
                .then((_) => _answer(line))
                .catchError((Object _) {});
          },
          onError: (Object _) => close(),
          onDone: close,
        );
  }

  final Socket _socket;
  final OmniEngine _engine;
  final void Function() _onClosed;
  late final StreamSubscription<NdjsonLine> _lines;
  final _subscriptions = <StreamSubscription<Map<String, Object?>>>[];

  // Requests on one connection are answered in order, one at a time.
  Future<void> _queue = Future.value();
  var _closed = false;

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
    final result = await _engine.handle(
      command,
      Map<String, Object?>.from(args),
    );
    _send({'id': id, 'result': result});
  }

  void _subscribe(int id, Map<String, Object?> json) {
    if (json['subscribe'] != 'events') {
      _send({'id': id, 'result': _invalid('only "events" can be subscribed')});
      return;
    }
    final packets = json['packets'] == true;
    _subscriptions.add(
      _engine.events
          .where((e) => packets || e['event'] != 'packet.captured')
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
    await _queue;
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
