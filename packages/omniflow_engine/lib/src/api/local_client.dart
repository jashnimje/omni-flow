import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'omni_engine.dart';

/// The control socket a running `omni hub` serves in its data directory.
String localSocketPath(Directory home) => '${home.absolute.path}/omni.sock';

/// The hub's second socket, beside [localSocketPath] in the same 0700 home,
/// for phone sessions only: `omni hub attach --phone NAME` connects here and
/// names the phone in its first line, and every command on it is checked
/// against what a phone may do.
String phoneSocketPath(String localSocket) =>
    '${File(localSocket).parent.path}/omni-phone.sock';

/// A request the hub's socket answers at once, outside the command queue,
/// so a client can tell a slow command from a dead link.
const pingCommand = 'ping';

/// How long a client waits for the hub to answer an ordinary command.
const hubRequestTimeout = Duration(seconds: 10);

/// Commands that touch a device and may wait on it (an ADB connect, a phone
/// that has 10 s to act).
const _deviceTimeout = Duration(seconds: 30);

/// Commands that run as long as their work: a whole automation, a pairing
/// that waits for someone at the TV, a file copy, firmware.
const _longTimeout = Duration(minutes: 10);

const _longCommands = {
  'automation.run',
  'flow.run',
  'scene.run',
  'device.pair',
  'android.pair',
  'board.flash',
  'board.setup',
  'board.provision',
  'tv.install',
  'tv.helper.install',
  'tv.files.download',
  'tv.files.upload',
  'tv.files.copy',
  'tv.files.move',
  'tv.app.backup',
  'tv.record.stop',
  'config.import',
};

const _deviceCommands = {
  'device.invoke',
  'device.refresh',
  'room.invoke',
  'thing.configure',
  'sunlight.apply',
  'weather.refresh',
  'scene.capture',
};

/// How long a client waits for [command] before it answers `timeout`. A
/// command that listens for a window (`windowMs`) gets that window on top.
Duration hubRequestDeadline(String command, Map<String, Object?> args) {
  final name = command.startsWith('android.')
      ? 'tv.${command.substring('android.'.length)}'
      : command;
  if (_longCommands.contains(name)) return _longTimeout;
  final window = args['windowMs'];
  final base = _deviceCommands.contains(name) || name.startsWith('tv.')
      ? _deviceTimeout
      : hubRequestTimeout;
  if (window is int && window > 0 && window <= 600000) {
    return base + Duration(milliseconds: window);
  }
  return base;
}

/// The reply a client gives itself when the hub did not answer [command]
/// in time. The link may still be up: only a missed ping drops it.
Map<String, Object?> hubTimeoutReply(String command, Duration after) => {
  'ok': false,
  'error': {
    'type': 'timeout',
    'message':
        'the hub did not answer $command within ${after.inSeconds} s. It '
        'may still be doing it',
  },
};

/// Permission bits, written in octal as chmod takes them.
final groupOrOtherWrite = int.parse('022', radix: 8);
final groupOrOtherAny = int.parse('077', radix: 8);
final permissionBits = int.parse('777', radix: 8);

String octalMode(int mode) => (mode & permissionBits).toRadixString(8);

/// A request line bigger than this is refused rather than buffered by the
/// hub. The hub cannot read the id of a line it cut off, so the client
/// refuses such a request itself instead of waiting for a reply it cannot
/// match.
const maxLocalRequestBytes = 8 << 20;

/// A local control socket that cannot be used safely, or a hub that cannot
/// serve one. [exitCode] is the sysexits code the CLI exits with.
class LocalSocketException implements Exception {
  LocalSocketException(this.message, {this.exitCode = 77});

  final String message;
  final int exitCode;

  @override
  String toString() => 'LocalSocketException: $message';
}

/// The core API as a caller sees it: the engine in this process, or the
/// engine of a running hub reached through its control socket.
abstract interface class EngineConnection {
  /// Runs one core API command. Never throws, like [OmniEngine.handle].
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  );

  /// Engine events from now on, `packet.captured` only when [packets].
  /// Completes once the subscription is live, so nothing after it is lost.
  Future<Stream<Map<String, Object?>>> events({bool packets = false});

  Future<void> close();
}

/// The engine opened in this process.
class InProcessConnection implements EngineConnection {
  InProcessConnection(this.engine);

  final OmniEngine engine;

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) => engine.handle(command, args);

  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) async =>
      packets ? engine.events : engine.events.where(_notPacket);

  @override
  Future<void> close() => engine.close();
}

bool _notPacket(Map<String, Object?> e) => e['event'] != 'packet.captured';

/// A client of a running hub's control socket: newline-delimited JSON,
/// `{"id":N,"command":...,"args":{...}}` answered by `{"id":N,"result":...}`.
class LocalClient implements EngineConnection {
  LocalClient._(this.path, this._socket) {
    _socket.done.catchError((Object _) {});
    _lines(_socket)
        .listen(_onLine, onError: (Object _) => _shutDown(), onDone: _shutDown);
  }

  final String path;
  final Socket _socket;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  var _nextId = 0;
  var _closed = false;

  static const connectTimeout = Duration(seconds: 2);

  /// Connects when a hub serves [path]. Null when there is no socket there
  /// or it does not answer (a stale file), so the caller opens the engine
  /// itself. Throws [LocalSocketException] when the socket or its directory
  /// is open to other users, because a socket planted there could collect
  /// what the CLI sends, secrets included.
  static Future<LocalClient?> connect(String path) async {
    final socket = await _open(path);
    return socket == null ? null : LocalClient._(path, socket);
  }

  /// The raw socket of a hub serving [path], after the same checks as
  /// [connect], for `omni hub attach` to copy bytes through. Null when no
  /// hub answers there.
  static Future<Socket?> openSocket(String path) => _open(path);

  static Future<Socket?> _open(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.unixDomainSock) return null;
    final dir = File(path).parent;
    final dirMode = (await dir.stat()).mode;
    if (dirMode & groupOrOtherWrite != 0) {
      throw LocalSocketException(
        '${dir.path} is writable by other users, so its omni.sock is not '
        'trusted. Run chmod 700 ${dir.path}',
      );
    }
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ).timeout(connectTimeout);
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
    // Others cannot write the directory, so the file cannot be swapped
    // after this check. With no group or other bits on it, only its owner
    // (or root) could connect, which proves the hub runs as this user.
    // A hub binds the socket and then sets it to 0600, so a client that
    // connects in between sees the umask's bits for a moment. It looks
    // again briefly before refusing.
    var socketMode = (await FileStat.stat(path)).mode;
    for (var i = 0; i < 10 && socketMode & groupOrOtherAny != 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socketMode = (await FileStat.stat(path)).mode;
    }
    if (socketMode & groupOrOtherAny != 0) {
      socket.destroy();
      throw LocalSocketException(
        '$path is open to other users (mode ${octalMode(socketMode)}), '
        'so it is not trusted',
      );
    }
    return socket;
  }

  static Stream<String> _lines(Socket socket) => socket
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  void _onLine(String line) {
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (json is! Map) return;
    final id = json['id'];
    final result = json['result'];
    if (id is int && result is Map) {
      _pending.remove(id)?.complete(Map<String, Object?>.from(result));
    }
  }

  void _shutDown() {
    _closed = true;
    for (final c in _pending.values) {
      c.complete(_unavailable('the omni hub stopped before it replied'));
    }
    _pending.clear();
    _socket.destroy();
  }

  static Map<String, Object?> _unavailable(String message) => {
    'ok': false,
    'error': {'type': 'unavailable', 'message': message},
  };

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> args,
  ) {
    if (_closed) {
      return Future.value(_unavailable('the omni hub at $path stopped'));
    }
    final List<int> request;
    final id = ++_nextId;
    try {
      request = utf8.encode(
        '${jsonEncode({'id': id, 'command': command, 'args': args})}\n',
      );
    } on JsonUnsupportedObjectError catch (e) {
      return Future.value({
        'ok': false,
        'error': {'type': 'invalid', 'message': 'args are not JSON: $e'},
      });
    }
    if (request.length - 1 > maxLocalRequestBytes) {
      return Future.value({
        'ok': false,
        'error': {
          'type': 'invalid',
          'message':
              'the $command request is ${request.length} bytes, over the '
              'omni hub limit of $maxLocalRequestBytes',
        },
      });
    }
    final reply = _pending[id] = Completer<Map<String, Object?>>();
    _socket.add(request);
    final deadline = hubRequestDeadline(command, args);
    return reply.future.timeout(
      deadline,
      onTimeout: () {
        _pending.remove(id);
        return hubTimeoutReply(command, deadline);
      },
    );
  }

  /// Each subscription has its own connection, so cancelling it ends the
  /// subscription and nothing on the server keeps streaming.
  @override
  Future<Stream<Map<String, Object?>>> events({bool packets = false}) async {
    final socket = await _open(path);
    if (socket == null) {
      throw LocalSocketException('the omni hub at $path stopped', exitCode: 69);
    }
    socket.done.catchError((Object _) {});
    final subscribed = Completer<void>();
    final out = StreamController<Map<String, Object?>>();
    late final StreamSubscription<String> lines;
    lines = _lines(socket).listen(
      (line) {
        final Object? json;
        try {
          json = jsonDecode(line);
        } on FormatException {
          return;
        }
        if (json is! Map || json['id'] != 1) return;
        final event = json['event'];
        final result = json['result'];
        if (event is Map) {
          out.add(Map<String, Object?>.from(event));
        } else if (result is Map && !subscribed.isCompleted) {
          if (result['ok'] == true) {
            subscribed.complete();
          } else {
            subscribed.completeError(
              LocalSocketException('the hub refused the subscription: $result'),
            );
          }
        }
      },
      onError: (Object _) {},
      onDone: () {
        if (!subscribed.isCompleted) {
          subscribed.completeError(
            LocalSocketException('the omni hub at $path stopped', exitCode: 69),
          );
        }
        socket.destroy();
        out.close();
      },
    );
    out.onCancel = () async {
      await lines.cancel();
      socket.destroy();
    };
    socket.add(
      utf8.encode(
        '${jsonEncode({'id': 1, 'subscribe': 'events', 'packets': packets})}\n',
      ),
    );
    try {
      await subscribed.future.timeout(connectTimeout);
    } catch (e) {
      await lines.cancel();
      socket.destroy();
      if (e is LocalSocketException) rethrow;
      throw LocalSocketException(
        'the omni hub at $path did not answer the subscription',
        exitCode: 69,
      );
    }
    return out.stream;
  }

  @override
  Future<void> close() async {
    if (!_closed) _shutDown();
  }
}
