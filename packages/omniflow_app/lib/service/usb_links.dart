import 'dart:async';

import 'package:flutter/services.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

/// The phone's USB serial ports for the engine, through the service's
/// omniflow/usb and omniflow/usb_data channels: a board plugged into the
/// phone is set up, driven and flashed with no computer.
class UsbLinks implements SerialLinks {
  UsbLinks({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('omniflow/usb'),
      _events = events ?? const EventChannel('omniflow/usb_data');

  final MethodChannel _methods;
  final EventChannel _events;
  final _open = <String, _UsbLink>{};
  final _plugs = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription<Object?>? _sub;

  /// `attached` and `detached`, with the port's path.
  Stream<Map<String, Object?>> get plugs {
    _listen();
    return _plugs.stream;
  }

  void _listen() {
    _sub ??= _events.receiveBroadcastStream().listen((raw) {
      if (raw is! Map) return;
      final e = Map<String, Object?>.from(raw);
      final path = '${e['path']}';
      switch (e['event']) {
        case 'data':
          final bytes = e['bytes'];
          if (bytes is Uint8List) _open[path]?._in.add(bytes);
        case 'closed':
          _open.remove(path)?._ended();
        case 'detached':
          // Kept for a while: a board that comes back on the same name (a
          // cable wiggle, a hub reset) is opened again, and the engine
          // never notices.
          _open[path]?._unplugged(replugWait);
          _plugs.add(e);
        case 'attached':
          _plugs.add(e);
          if (_open[path] case final link? when link.unplugged) {
            unawaited(_reopen(link));
          }
      }
    }, onError: (Object _) {});
  }

  /// Each port with its vendor, product, name and whether OmniFlow may use
  /// it yet.
  Future<List<Map<String, Object?>>> describe() async {
    try {
      final list = await _methods.invokeListMethod<Object?>('ports') ?? [];
      return [
        for (final p in list)
          if (p is Map) Map<String, Object?>.from(p),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      // The USB service failing must not stop discovery of everything else.
      return const [];
    }
  }

  @override
  Future<List<String>> ports() async => [
    for (final p in await describe()) '${p['path']}',
  ];

  /// How long an unplugged port waits to come back before it closes.
  static const replugWait = Duration(minutes: 5);

  /// How long to wait for the person to answer Android's USB prompt. The
  /// phone side gives up a little sooner.
  static const permissionWait = Duration(seconds: 75);

  /// Asks Android to let OmniFlow use [path]: the phone shows its own
  /// prompt once, and remembers a choice the user ticks. False when nobody
  /// answers in [permissionWait].
  Future<bool> allow(String path) async {
    try {
      return await _methods
              .invokeMethod<bool>('permission', {'path': path})
              .timeout(permissionWait, onTimeout: () => false) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _reopen(_UsbLink link) async {
    try {
      if (!await allow(link.path)) throw const SerialPortClosed();
      await _methods.invokeMethod<void>('open', {
        'path': link.path,
        'baud': link.baud,
      });
      link._pluggedIn();
    } on Object {
      if (identical(_open[link.path], link)) _open.remove(link.path);
      link._ended();
    }
  }

  @override
  Future<SerialLink> open(String path, int baud) async {
    _listen();
    if (!await allow(path)) {
      throw TransportTimeoutException(
        'OmniFlow was not allowed to use the USB device $path',
      );
    }
    try {
      await _methods.invokeMethod<void>('open', {'path': path, 'baud': baud});
    } on PlatformException catch (e) {
      throw TransportTimeoutException(e.message ?? 'cannot open $path');
    }
    final link = _UsbLink(path, baud, _methods, () => _open.remove(path));
    _open[path] = link;
    return link;
  }

  Future<void> close() async {
    for (final link in _open.values.toList()) {
      await link.close();
    }
    await _sub?.cancel();
    _sub = null;
  }
}

class _UsbLink implements SerialLink {
  _UsbLink(this.path, this.baud, this._methods, this._forget);

  final String path;
  int baud;
  final MethodChannel _methods;
  final void Function() _forget;
  final _in = StreamController<List<int>>();
  var _closed = false;

  @override
  Stream<List<int>> get input => _in.stream;

  Future<void> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_closed) throw const SerialPortClosed();
    if (unplugged) {
      throw TransportTimeoutException('$path is unplugged: plug it back in');
    }
    try {
      await _methods.invokeMethod<void>(method, {'path': path, ...args});
    } on PlatformException catch (e) {
      throw TransportTimeoutException(e.message ?? '$path: $method failed');
    }
  }

  @override
  Future<void> write(List<int> bytes) =>
      _call('write', {'bytes': Uint8List.fromList(bytes)});

  @override
  Future<void> setLines({bool? dtr, bool? rts}) =>
      _call('lines', {'dtr': ?dtr, 'rts': ?rts});

  @override
  Future<void> setBaud(int baud) async {
    await _call('baud', {'baud': baud});
    this.baud = baud;
  }

  /// Unplugged and waiting to come back.
  bool get unplugged => _gone != null;
  Timer? _gone;

  void _unplugged(Duration wait) {
    _gone?.cancel();
    _gone = Timer(wait, () {
      _forget();
      _ended();
    });
  }

  void _pluggedIn() {
    _gone?.cancel();
    _gone = null;
  }

  void _ended() {
    _gone?.cancel();
    _gone = null;
    if (_closed) return;
    _closed = true;
    _in.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _forget();
    try {
      await _methods.invokeMethod<void>('close', {'path': path});
    } on Object {
      // Unplugged already: nothing to close.
    }
    _ended();
  }
}

/// A write to a USB port after it closed.
class SerialPortClosed implements Exception {
  const SerialPortClosed();

  @override
  String toString() => 'the USB port is closed';
}
