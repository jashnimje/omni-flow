import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A small MQTT 3.1.1 broker on loopback for tests: CONNECT with optional
/// credentials, PUBLISH at QoS 0 and 1, retained messages, SUBSCRIBE with
/// `+` and `#`, UNSUBSCRIBE, PINGREQ and DISCONNECT.
class MiniBroker {
  MiniBroker._(this._server, this.username, this.password) {
    _server.listen(_accept);
  }

  static Future<MiniBroker> start({
    String? username,
    String? password,
    int port = 0,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    return MiniBroker._(server, username, password);
  }

  final ServerSocket _server;
  final String? username;
  final String? password;
  final _clients = <_Client>[];
  final _retained = <String, Uint8List>{};
  final _published = StreamController<(String, String)>.broadcast();

  int get port => _server.port;

  /// Every message a client published, as (topic, payload text).
  Stream<(String, String)> get published => _published.stream;

  void _accept(Socket socket) {
    final client = _Client(socket);
    _clients.add(client);
    final buffer = BytesBuilder();
    socket.listen(
      (data) {
        buffer.add(data);
        var bytes = buffer.takeBytes();
        while (true) {
          final packet = _readPacket(bytes);
          if (packet == null) break;
          _handle(client, packet.$1, packet.$2, packet.$3);
          bytes = bytes.sublist(packet.$4);
        }
        buffer.add(bytes);
      },
      onDone: () => _drop(client),
      onError: (_) => _drop(client),
    );
  }

  /// (type, flags, body, total length) of the first whole packet, or null.
  static (int, int, Uint8List, int)? _readPacket(Uint8List b) {
    if (b.length < 2) return null;
    var length = 0;
    var multiplier = 1;
    var i = 1;
    while (true) {
      if (i >= b.length) return null;
      final byte = b[i++];
      length += (byte & 0x7F) * multiplier;
      if (byte & 0x80 == 0) break;
      multiplier *= 128;
    }
    if (b.length < i + length) return null;
    return (b[0] >> 4, b[0] & 0x0F, b.sublist(i, i + length), i + length);
  }

  void _handle(_Client c, int type, int flags, Uint8List body) {
    final r = _Reader(body);
    switch (type) {
      case 1: // CONNECT
        r.string(); // protocol name
        r.byte(); // level
        final connectFlags = r.byte();
        r.u16(); // keep alive
        r.string(); // client id
        if (connectFlags & 0x04 != 0) {
          r.string();
          r.binary();
        }
        final user = connectFlags & 0x80 != 0 ? r.string() : null;
        final pass = connectFlags & 0x40 != 0 ? utf8.decode(r.binary()) : null;
        final allowed =
            username == null || (user == username && pass == password);
        c.send(_packet(0x20, [0, allowed ? 0 : 5]));
        if (!allowed) c.socket.destroy();
      case 3: // PUBLISH
        final qos = (flags >> 1) & 3;
        final retain = flags & 1 != 0;
        final topic = r.string();
        if (qos > 0) {
          final id = r.u16();
          c.send(_packet(0x40, [id >> 8, id & 0xFF]));
        }
        final payload = r.rest();
        if (retain) {
          if (payload.isEmpty) {
            _retained.remove(topic);
          } else {
            _retained[topic] = payload;
          }
        }
        _published.add((topic, utf8.decode(payload, allowMalformed: true)));
        for (final other in _clients) {
          if (other.filters.any((f) => topicMatches(f, topic))) {
            other.send(_publish(topic, payload, retain: false));
          }
        }
      case 8: // SUBSCRIBE
        final id = r.u16();
        final granted = <int>[];
        while (r.hasMore) {
          final filter = r.string();
          r.byte();
          c.filters.add(filter);
          granted.add(0);
          for (final e in _retained.entries) {
            if (topicMatches(filter, e.key)) {
              c.send(_publish(e.key, e.value, retain: true));
            }
          }
        }
        c.send(_packet(0x90, [id >> 8, id & 0xFF, ...granted]));
      case 10: // UNSUBSCRIBE
        final id = r.u16();
        while (r.hasMore) {
          c.filters.remove(r.string());
        }
        c.send(_packet(0xB0, [id >> 8, id & 0xFF]));
      case 12: // PINGREQ
        c.send(_packet(0xD0, const []));
      case 14: // DISCONNECT
        c.socket.destroy();
    }
  }

  static Uint8List _publish(
    String topic,
    Uint8List payload, {
    required bool retain,
  }) {
    final t = utf8.encode(topic);
    return _packet(retain ? 0x31 : 0x30, [
      t.length >> 8,
      t.length & 0xFF,
      ...t,
      ...payload,
    ]);
  }

  static Uint8List _packet(int header, List<int> body) {
    final out = BytesBuilder()..addByte(header);
    var length = body.length;
    do {
      var byte = length % 128;
      length ~/= 128;
      if (length > 0) byte |= 0x80;
      out.addByte(byte);
    } while (length > 0);
    out.add(body);
    return out.takeBytes();
  }

  void _drop(_Client c) => _clients.remove(c);

  /// Publishes from the broker itself, as a device on the network would.
  void inject(String topic, String payload, {bool retain = false}) {
    final bytes = Uint8List.fromList(utf8.encode(payload));
    if (retain) _retained[topic] = bytes;
    for (final c in _clients) {
      if (c.filters.any((f) => topicMatches(f, topic))) {
        c.send(_publish(topic, bytes, retain: false));
      }
    }
  }

  Future<void> close() async {
    for (final c in [..._clients]) {
      c.socket.destroy();
    }
    await _server.close();
    await _published.close();
  }
}

bool topicMatches(String filter, String topic) {
  final f = filter.split('/');
  final t = topic.split('/');
  for (var i = 0; i < f.length; i++) {
    if (f[i] == '#') return true;
    if (i >= t.length) return false;
    if (f[i] != '+' && f[i] != t[i]) return false;
  }
  return f.length == t.length;
}

class _Client {
  _Client(this.socket);

  final Socket socket;
  final filters = <String>{};

  void send(List<int> bytes) {
    try {
      socket.add(bytes);
    } catch (_) {
      // The client went away.
    }
  }
}

class _Reader {
  _Reader(this._b);

  final Uint8List _b;
  var _i = 0;

  bool get hasMore => _i < _b.length;
  int byte() => _b[_i++];
  int u16() => (byte() << 8) | byte();
  Uint8List binary() {
    final n = u16();
    final out = _b.sublist(_i, _i + n);
    _i += n;
    return out;
  }

  String string() => utf8.decode(binary());
  Uint8List rest() {
    final out = _b.sublist(_i);
    _i = _b.length;
    return out;
  }
}
