import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';

import '../api/engine_client.dart';

/// The app's private control socket in hub mode, where there is no local
/// engine for `LocalServer` to serve. Widgets, tiles, the share sheet and
/// the answers to asks (`EngineSocket.kt`) send their command here, and it
/// goes on to the hub through [EngineClient]. Same contract as the engine's
/// socket: newline JSON, mode 0600 in the app's own 0700 folder, no network
/// interface.
class HubBridge {
  HubBridge._(this.path, this._client, this._server) {
    _server.listen(_serve);
  }

  final String path;
  final EngineClient _client;
  final ServerSocket _server;
  final _sockets = <Socket>{};

  static Future<HubBridge> start(
    EngineClient client, {
    required Directory home,
  }) async {
    await preparePrivateHome(home);
    final socketPath = localSocketPath(home);
    final type = await FileSystemEntity.type(socketPath, followLinks: false);
    if (type == FileSystemEntityType.unixDomainSock) {
      // The engine of the phone mode this replaced is closed by now (the
      // engine owner waited for it), so the file is stale.
      await File(socketPath).delete();
    } else if (type != FileSystemEntityType.notFound) {
      throw LocalSocketException('$socketPath exists and is not a socket');
    }
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final chmod = File('/bin/chmod').existsSync()
        ? '/bin/chmod'
        : '/system/bin/chmod';
    final result = await Process.run(chmod, ['600', socketPath]);
    if (result.exitCode != 0) {
      await server.close();
      throw LocalSocketException('cannot make $socketPath private');
    }
    return HubBridge._(socketPath, client, server);
  }

  void _serve(Socket socket) {
    _sockets.add(socket);
    socket.done
        .catchError((Object _) {})
        .whenComplete(() => _sockets.remove(socket));
    final subscriptions = <StreamSubscription<Object?>>[];
    void send(Map<String, Object?> message) {
      try {
        socket.add(utf8.encode('${jsonEncode(message)}\n'));
      } on Object {
        return;
      }
    }

    var queue = Future<void>.value();
    socket
        .cast<List<int>>()
        .transform(const NdjsonDecoder(maxLineLength: 8 << 20))
        .listen(
          (line) {
            queue = queue
                .then((_) async {
                  final json = line.json;
                  final id = json?['id'];
                  if (json == null || id is! int) {
                    send({
                      'id': null,
                      'result': _invalid('one JSON object a line'),
                    });
                    return;
                  }
                  if (json['subscribe'] == 'events') {
                    subscriptions.add(
                      _client.events.listen(
                        (e) => send({'id': id, 'event': e}),
                      ),
                    );
                    send({
                      'id': id,
                      'result': {'ok': true, 'subscribed': 'events'},
                    });
                    return;
                  }
                  final command = json['command'];
                  final args = json['args'] ?? const <String, Object?>{};
                  if (command is! String || args is! Map) {
                    send({'id': id, 'result': _invalid('a command and args')});
                    return;
                  }
                  final result = await _client.call(
                    command,
                    Map<String, Object?>.from(args),
                  );
                  send({'id': id, 'result': result});
                })
                .catchError((Object _) {});
          },
          onError: (Object _) => socket.destroy(),
          onDone: () {
            for (final s in subscriptions) {
              unawaited(s.cancel());
            }
            unawaited(queue.whenComplete(socket.destroy));
          },
        );
  }

  static Map<String, Object?> _invalid(String message) => {
    'ok': false,
    'error': {'type': 'invalid', 'message': message},
  };

  Future<void> close() async {
    await _server.close();
    for (final s in _sockets.toList()) {
      s.destroy();
    }
    try {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.unixDomainSock) {
        await File(path).delete();
      }
    } on FileSystemException {
      return;
    }
  }
}
