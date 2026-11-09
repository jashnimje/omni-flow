import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A throwaway self-signed certificate made for one test run.
class TestCertificate {
  TestCertificate(this.certPath, this.keyPath, this.der);

  final String certPath;
  final String keyPath;
  final Uint8List der;

  SecurityContext context() => SecurityContext()
    ..useCertificateChain(certPath)
    ..usePrivateKey(keyPath);

  /// Generates a fresh key and certificate under [dir] with openssl.
  static Future<TestCertificate> generate(Directory dir, String name) async {
    final cert = '${dir.path}/$name.crt';
    final key = '${dir.path}/$name.key';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '1',
      '-subj',
      '/CN=$name',
    ]);
    if (result.exitCode != 0) {
      throw StateError('openssl failed: ${result.stderr}');
    }
    final pem = File(cert).readAsStringSync();
    final body = pem
        .split('\n')
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    return TestCertificate(cert, key, base64.decode(body));
  }
}

abstract class _FakeTv {
  _FakeTv(this.server) {
    server.listen(_onRequest);
  }

  final HttpServer server;
  final requests = <Uri>[];
  final received = <Map<String, Object?>>[];
  final sockets = <WebSocket>[];
  var prompts = 0;
  var rejectPairing = false;

  /// Whether someone at the TV accepts its pairing prompt. When false the
  /// prompt stays up and the TV sends nothing more.
  var answerPrompt = true;

  /// When set, the upgrade is answered with this HTTP status instead.
  int? refuseUpgradeWith;

  /// When set, the upgrade waits for it.
  Completer<void>? holdUpgrade;

  /// WebSockets the client side has closed.
  var closedSockets = 0;

  int get port => server.port;

  Future<void> _onRequest(HttpRequest request) async {
    requests.add(request.uri);
    final refuse = refuseUpgradeWith;
    if (refuse != null || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = refuse ?? HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    await holdUpgrade?.future;
    final ws = await WebSocketTransformer.upgrade(request);
    sockets.add(ws);
    ws.listen((data) {
      final message = Map<String, Object?>.from(
        jsonDecode(data as String) as Map,
      );
      received.add(message);
      onMessage(ws, message);
    }, onDone: () => closedSockets++);
    onOpen(ws, request.uri);
  }

  /// Waits until [check] holds, for up to two seconds.
  Future<void> until(bool Function() check) async {
    for (var i = 0; i < 200 && !check(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Waits until the TV has received [count] messages.
  Future<void> receivedCount(int count) async {
    for (var i = 0; i < 200 && received.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void onOpen(WebSocket ws, Uri uri) {}

  void onMessage(WebSocket ws, Map<String, Object?> message);

  void sendJson(WebSocket ws, Object message) => ws.add(jsonEncode(message));

  Future<void> close() async {
    for (final s in sockets) {
      await s.close();
    }
    await server.close(force: true);
  }
}

/// A loopback LG webOS TV speaking SSAP.
class FakeWebOsTv extends _FakeTv {
  FakeWebOsTv._(super.server);

  static Future<FakeWebOsTv> start({SecurityContext? tls}) async =>
      FakeWebOsTv._(
        tls == null
            ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
            : await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls),
      );

  final knownKeys = <String>{};
  var _issued = 0;
  var volume = 10;
  var muted = false;

  /// Answers getVolume the way webOS 5 and later do, under volumeStatus.
  var nestedVolume = true;

  /// Sends a reply for another id and an unrelated event before each reply.
  var noiseFirst = false;

  /// Holds replies until two requests are in, then answers them newest first.
  var answerInReverse = false;
  final _held = <Map<String, Object?>>[];

  Iterable<Map<String, Object?>> get registrations =>
      received.where((m) => m['type'] == 'register');

  @override
  void onMessage(WebSocket ws, Map<String, Object?> message) {
    final id = message['id'];
    if (message['type'] == 'register') {
      final payload = message['payload'] as Map;
      final key = payload['client-key'];
      if (key is String && knownKeys.contains(key)) {
        sendJson(ws, {
          'type': 'registered',
          'id': id,
          'payload': {'client-key': key},
        });
        return;
      }
      prompts++;
      sendJson(ws, {
        'type': 'response',
        'id': id,
        'payload': {'pairingType': 'PROMPT', 'returnValue': true},
      });
      if (!answerPrompt) return;
      if (rejectPairing) {
        sendJson(ws, {
          'type': 'error',
          'id': id,
          'error': '403 User denied access',
          'payload': {},
        });
        return;
      }
      final issued = 'fake-client-key-${++_issued}';
      knownKeys.add(issued);
      sendJson(ws, {
        'type': 'registered',
        'id': id,
        'payload': {'client-key': issued},
      });
      return;
    }
    final reply = _answer(message);
    if (answerInReverse) {
      _held.add(reply);
      if (_held.length == 2) {
        for (final r in _held.reversed) {
          sendJson(ws, r);
        }
        _held.clear();
      }
      return;
    }
    if (noiseFirst) {
      sendJson(ws, {
        'type': 'response',
        'id': 9999,
        'payload': {'returnValue': true, 'volume': 99},
      });
      sendJson(ws, {
        'type': 'response',
        'id': 'subscription_x',
        'payload': {'returnValue': true},
      });
    }
    sendJson(ws, reply);
  }

  Map<String, Object?> _answer(Map<String, Object?> message) {
    final id = message['id'];
    final payload = (message['payload'] as Map?) ?? const {};
    switch (message['uri']) {
      case 'ssap://audio/setVolume':
        volume = payload['volume'] as int;
        return _ok(id, {});
      case 'ssap://audio/setMute':
        muted = payload['mute'] as bool;
        return _ok(id, {});
      case 'ssap://audio/getVolume':
        return _ok(
          id,
          nestedVolume
              ? {
                  'volumeStatus': {'volume': volume, 'muteStatus': muted},
                }
              : {'volume': volume, 'muted': muted},
        );
      case 'ssap://system/turnOff':
      case 'ssap://system.launcher/launch':
      case 'ssap://system.notifications/createToast':
        return _ok(id, {});
      case 'ssap://audio/refuse':
        return {
          'type': 'response',
          'id': id,
          'payload': {'returnValue': false, 'errorText': 'not now'},
        };
      default:
        return {
          'type': 'error',
          'id': id,
          'error': '404 no such service or method',
          'payload': {},
        };
    }
  }

  Map<String, Object?> _ok(Object? id, Map<String, Object?> payload) => {
    'type': 'response',
    'id': id,
    'payload': {'returnValue': true, ...payload},
  };
}

/// A loopback Samsung Tizen TV on its secure remote-control channel.
class FakeTizenTv extends _FakeTv {
  FakeTizenTv._(super.server);

  static Future<FakeTizenTv> start(SecurityContext tls) async => FakeTizenTv._(
    await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls),
  );

  final knownTokens = <String>{};
  var _issued = 0;

  @override
  void onOpen(WebSocket ws, Uri uri) {
    final token = uri.queryParameters['token'];
    if (token != null && knownTokens.contains(token)) {
      sendJson(ws, {
        'event': 'ms.channel.connect',
        'data': {'id': 'client', 'token': token},
      });
      return;
    }
    prompts++;
    sendJson(ws, {'event': 'ms.channel.ready', 'data': {}});
    if (!answerPrompt) return;
    if (rejectPairing) {
      sendJson(ws, {'event': 'ms.channel.unauthorized'});
      ws.close();
      return;
    }
    final issued = '${10000000 + ++_issued}';
    knownTokens.add(issued);
    sendJson(ws, {
      'event': 'ms.channel.connect',
      'data': {'id': 'client', 'token': issued},
    });
  }

  @override
  void onMessage(WebSocket ws, Map<String, Object?> message) {}
}
