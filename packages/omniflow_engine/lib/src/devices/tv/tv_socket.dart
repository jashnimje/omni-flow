import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../transports/packet_tap.dart';
import '../../transports/udp_transport.dart';
import '../channels.dart';

/// The TV refused to pair, or nobody answered its pairing prompt.
class TvPairingException extends CommandFailedException {
  TvPairingException(super.message);
}

/// The TV presented a different TLS certificate than the one pinned on first
/// use. Nothing is sent to it.
class TvCertificateMismatchException extends CommandFailedException {
  TvCertificateMismatchException({
    required this.deviceId,
    required this.pinned,
    required this.presented,
  }) : super(
         '$deviceId presented TLS certificate SHA-256 $presented, but '
         '$pinned is pinned. Nothing was sent. If you reset or replaced '
         'the TV, remove $deviceId and add it again so the new certificate '
         'is pinned, or store $presented as its certSha256 secret with '
         'omni secret set $deviceId certSha256',
       );

  final String deviceId;
  final String pinned;
  final String presented;
}

/// SHA-256 of a DER certificate, lowercase hex.
String certificateSha256(Uint8List der) => SHA256Digest()
    .process(der)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// A stored pin in the form [certificateSha256] returns. Colons and case
/// are accepted, so a fingerprint copied from elsewhere can be stored as is.
String? normalizeFingerprint(String? stored) {
  if (stored == null) return null;
  final hex = stored.replaceAll(':', '').trim().toLowerCase();
  return hex.isEmpty ? null : hex;
}

/// Keys whose values are secrets in TV pairing messages.
const _secretFields = {'client-key', 'token'};

/// One JSON-over-WebSocket connection to a TV.
///
/// For `wss` the certificate is pinned per device, trust on first use like
/// SSH host keys: TVs present self-signed certificates, so a chain check
/// proves nothing and the pin is the only identity check. The certificate is
/// accepted only for the one host this connection was opened to.
class TvSocket {
  TvSocket._(this._ws, this._remote, this._tap, this._redact) {
    _ws.listen(
      (data) {
        final text = data is String ? data : utf8.decode(data as List<int>);
        Map<String, Object?>? json;
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map) json = Map<String, Object?>.from(decoded);
        } on FormatException {
          json = null;
        }
        _record(PacketDirection.incoming, json, text);
        if (json != null) _offer(json);
      },
      onError: (_) => close(),
      onDone: close,
      cancelOnError: true,
    );
  }

  /// Opens [uri], `ws` or `wss`.
  ///
  /// For `wss`, [pinnedSha256] is the certificate pin, or null on first use.
  /// The fingerprint the TV presented is in [presentedSha256] afterwards,
  /// for the caller to store. [redact] lists the secret values that must
  /// never reach the packet tap. The URI itself is never recorded or put in
  /// an error message, since a Samsung token travels in it.
  static Future<TvSocket> connect({
    required String deviceId,
    required Uri uri,
    required Duration timeout,
    String? pinnedSha256,
    PacketTap? tap,
    Iterable<String> Function()? redact,
  }) async {
    final host = uri.host;
    final port = uri.port;
    final secure = uri.scheme == 'wss';
    String? presented;
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    if (secure) {
      client.connectionFactory = (target, proxyHost, proxyPort) async {
        if (target.host != host || target.port != port) {
          throw StateError('$deviceId: unexpected TLS target ${target.host}');
        }
        final task = await SecureSocket.startConnect(
          host,
          port,
          context: SecurityContext(withTrustedRoots: false),
          onBadCertificate: (_) => true,
        );
        return ConnectionTask.fromSocket(
          task.socket.then((socket) {
            final cert = socket.peerCertificate;
            if (cert == null) {
              socket.destroy();
              throw TvCertificateMismatchException(
                deviceId: deviceId,
                pinned: pinnedSha256 ?? 'a certificate',
                presented: 'no certificate',
              );
            }
            presented = certificateSha256(cert.der);
            if (pinnedSha256 != null && presented != pinnedSha256) {
              socket.destroy();
              throw TvCertificateMismatchException(
                deviceId: deviceId,
                pinned: pinnedSha256,
                presented: presented!,
              );
            }
            return socket;
          }),
          task.cancel,
        );
      };
    }
    final remote = '$host:$port';
    final WebSocket ws;
    var opened = false;
    try {
      ws = await WebSocket.connect(
        uri.toString(),
        customClient: client,
      ).timeout(timeout);
      opened = true;
    } on TvCertificateMismatchException {
      rethrow;
    } on TimeoutException {
      throw TransportTimeoutException('cannot reach $deviceId at $remote');
    } on SocketException catch (e) {
      throw TransportTimeoutException(
        'cannot reach $deviceId at $remote (${e.message})',
      );
    } on HandshakeException catch (e) {
      throw CommandFailedException(
        'TLS handshake with $deviceId failed (${e.message})',
      );
    } on WebSocketException catch (e) {
      // The SDK message quotes the whole URI, Samsung token included.
      final status = e.httpStatusCode;
      throw CommandFailedException(
        '$deviceId refused the WebSocket connection'
        '${status == null ? '' : ' (HTTP $status)'}',
      );
    } on HttpException {
      throw CommandFailedException(
        '$deviceId refused the WebSocket connection',
      );
    } finally {
      // A connect that timed out may still finish later, so it is cut off.
      client.close(force: !opened);
    }
    // A TV switched off at the wall leaves the socket half open, and a
    // Tizen key gets no reply that would show it. An unanswered ping closes
    // the socket so the next command reconnects.
    ws.pingInterval = const Duration(seconds: 20);
    return TvSocket._(ws, remote, tap, redact ?? () => const [])
      .._certificateSha256 = presented;
  }

  final WebSocket _ws;
  final String _remote;
  final PacketTap? _tap;
  final Iterable<String> Function() _redact;
  final _closed = Completer<void>();
  final _waiters = <_Waiter>[];

  /// Messages nobody was waiting for yet. A TV can answer before the caller
  /// asks (Tizen sends its connect event straight after the upgrade), so a
  /// few are kept for the next [next].
  final _backlog = ListQueue<Map<String, Object?>>();
  static const _backlogLimit = 32;
  String? _certificateSha256;

  /// The fingerprint of the certificate the TV presented, null for `ws`.
  String? get presentedSha256 => _certificateSha256;

  bool get isClosed => _closed.isCompleted;

  Future<void> get done => _closed.future;

  void send(Map<String, Object?> message) {
    if (isClosed) throw const SocketException('connection closed');
    final text = jsonEncode(message);
    _record(PacketDirection.outgoing, message, text);
    _ws.add(text);
  }

  /// Waits for the first message [accept] takes, failing when the socket
  /// closes first or [timeout] passes.
  Future<Map<String, Object?>> next(
    bool Function(Map<String, Object?> message) accept,
    Duration timeout,
  ) {
    for (final m in _backlog) {
      if (accept(m)) {
        _backlog.remove(m);
        return Future.value(m);
      }
    }
    if (isClosed) {
      return Future.error(const SocketException('connection closed'));
    }
    final waiter = _Waiter(accept);
    _waiters.add(waiter);
    return waiter.result.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException('no message in time');
      },
    );
  }

  void _offer(Map<String, Object?> message) {
    for (final w in _waiters) {
      if (w.accept(message)) {
        _waiters.remove(w);
        w.result.complete(message);
        return;
      }
    }
    _backlog.addLast(message);
    while (_backlog.length > _backlogLimit) {
      _backlog.removeFirst();
    }
  }

  void close() {
    if (isClosed) return;
    _closed.complete();
    _ws.close().ignore();
    final waiting = [..._waiters];
    _waiters.clear();
    for (final w in waiting) {
      w.result.completeError(const SocketException('connection closed'));
    }
  }

  void _record(
    PacketDirection direction,
    Map<String, Object?>? json,
    String text,
  ) {
    final tap = _tap;
    if (tap == null) return;
    var safe = json == null ? text : jsonEncode(_scrub(json));
    for (final secret in _redact()) {
      if (secret.isNotEmpty) safe = safe.replaceAll(secret, '<secret>');
    }
    tap.record(
      CapturedPacket(
        transport: 'websocket',
        direction: direction,
        remote: _remote,
        bytes: Uint8List.fromList(utf8.encode(safe)),
      ),
    );
  }

  static Object? _scrub(Object? value) => switch (value) {
    Map m => {
      for (final e in m.entries)
        e.key: _secretFields.contains(e.key) ? '<secret>' : _scrub(e.value),
    },
    List l => [for (final v in l) _scrub(v)],
    _ => value,
  };
}

class _Waiter {
  _Waiter(this.accept);

  final bool Function(Map<String, Object?> message) accept;
  final result = Completer<Map<String, Object?>>();
}
