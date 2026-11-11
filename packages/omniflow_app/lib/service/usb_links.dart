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
        case 'closed' || 'detached':
          _open.remove(path)?._ended();
          if (e['event'] == 'detached') _plugs.add(e);
        case 'attached':
          _plugs.add(e);
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

  /// Asks Android to let OmniFlow use [path]: the phone shows its own
  /// prompt once, and remembers a choice the user ticks.
  Future<bool> allow(String path) async =>
      await _methods.invokeMethod<bool>('permission', {'path': path}) ?? false;

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
    final link = _UsbLink(path, _methods, () => _open.remove(path));
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
  _UsbLink(this.path, this._methods, this._forget);

  final String path;
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
  Future<void> setBaud(int baud) => _call('baud', {'baud': baud});

  void _ended() {
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
