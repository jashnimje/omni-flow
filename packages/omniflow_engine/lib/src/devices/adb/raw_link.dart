import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// A TCP connection that can switch to TLS and still be cut off while the
/// TLS handshake runs.
///
/// `SecureSocket.secure` takes the socket's file away from the caller, so
/// a peer that never finishes the handshake keeps it open for good, and a
/// timeout cannot close it. Over a [RawSocket] the plain socket stays in
/// hand, so [destroy] closes it whatever the handshake is doing.
class RawLink {
  RawLink._(this._raw) {
    _subscribe();
  }

  /// Connects to [host]:[port], giving up after [timeout].
  static Future<RawLink> connect(
    String host,
    int port, {
    required Duration timeout,
  }) async => RawLink._(await RawSocket.connect(host, port, timeout: timeout));

  RawSocket _raw;
  StreamSubscription<RawSocketEvent>? _subscription;

  /// The plain socket under the TLS one, closed with it.
  RawSocket? _plain;
  void Function(Uint8List data)? _onData;
  void Function()? _onDone;
  final _early = <Uint8List>[];
  final _pending = ListQueue<Uint8List>();
  var _offset = 0;
  Completer<void>? _drained;
  var _closed = false;
  final _done = Completer<void>();

  bool get isClosed => _closed;

  /// Completes once the link is closed, by either side.
  Future<void> get done => _done.future;

  /// The device's certificate once the link is TLS, else null.
  X509Certificate? get peerCertificate => switch (_raw) {
    final RawSecureSocket s => s.peerCertificate,
    _ => null,
  };

  /// Sends what arrives to [onData], and [onDone] once the link ends.
  /// Data that came before is handed over first.
  void listen(void Function(Uint8List data) onData, void Function() onDone) {
    _onData = onData;
    _onDone = onDone;
    for (final chunk in _early) {
      onData(chunk);
    }
    _early.clear();
    if (_closed) onDone();
  }

  void add(List<int> bytes) {
    if (_closed) return;
    _pending.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _pump();
  }

  /// Completes when everything added so far is written.
  Future<void> flush() {
    if (_pending.isEmpty || _closed) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  /// Turns the link into TLS 1.3 with [context]. [onBadCertificate] judges
  /// the device's certificate, as no root is trusted. When [timeout] passes
  /// first, the socket is closed, so a peer that never answers is cut off.
  Future<void> secure({
    required SecurityContext context,
    required bool Function(X509Certificate certificate) onBadCertificate,
    required Duration timeout,
    void Function(String line)? keyLog,
  }) async {
    final plain = _raw;
    final subscription = _subscription;
    _subscription = null;
    var abandoned = false;
    final pending = RawSecureSocket.secure(
      plain,
      subscription: subscription,
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
    );
    unawaited(
      pending.then<void>((s) {
        if (abandoned) s.close();
      }, onError: (Object _) {}),
    );
    final RawSecureSocket secure;
    try {
      secure = await pending.timeout(
        timeout > Duration.zero ? timeout : Duration.zero,
      );
    } catch (_) {
      abandoned = true;
      _plain = plain;
      _finish();
      rethrow;
    }
    if (_closed) {
      secure.close();
      throw const SocketException('the connection closed during TLS');
    }
    _plain = plain;
    _raw = secure;
    _subscribe();
  }

  void destroy() => _finish();

  void _subscribe() {
    _subscription = _raw.listen(
      _event,
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );
  }

  void _event(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _raw.read();
        if (data == null || data.isEmpty) return;
        final onData = _onData;
        if (onData == null) {
          _early.add(data);
        } else {
          onData(data);
        }
      case RawSocketEvent.write:
        _pump();
      case RawSocketEvent.readClosed:
      case RawSocketEvent.closed:
        _finish();
    }
  }

  void _pump() {
    while (_pending.isNotEmpty && !_closed) {
      final head = _pending.first;
      final int written;
      try {
        written = _raw.write(head, _offset);
      } on SocketException {
        _finish();
        return;
      }
      _offset += written;
      if (_offset < head.length) {
        _raw.writeEventsEnabled = true;
        return;
      }
      _pending.removeFirst();
      _offset = 0;
    }
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    unawaited(_subscription?.cancel());
    _subscription = null;
    for (final s in {_raw, ?_plain}) {
      unawaited(s.close().then<void>((_) {}, onError: (Object _) {}));
    }
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
    if (!_done.isCompleted) _done.complete();
    _onDone?.call();
  }
}
