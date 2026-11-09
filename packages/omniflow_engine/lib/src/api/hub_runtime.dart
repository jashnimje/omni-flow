import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_error.dart';
import 'board_runtime.dart';
import 'engine_core.dart';
import 'things_runtime.dart';
import '../devices/board.dart';
import '../devices/device.dart';
import '../devices/wiz_push.dart';
import '../manifest/driver_manifest.dart';
import '../storage/database.dart';
import '../transports/udp_transport.dart';

/// The hub: what runs flows on their own and keeps device state live, from
/// WiZ pushes, board hellos, MQTT watches, state polls and flow timers.
class HubRuntime {
  HubRuntime(this._core, this._boards, this._things);

  final EngineCore _core;
  final BoardRuntime _boards;
  final ThingsRuntime _things;

  void _emit(Map<String, Object?> event) => _core.emit(event);
  void _track(Future<void> work) => _core.track(work);

  var _running = false;
  Future<void>? _hubStart;
  final _hubTimers = <Timer>[];
  final _polls = <String, Timer>{};
  UdpTransport? _helloSocket;
  WizPushManager? _wizPush;

  bool get running => _running;

  /// A second call while the hub runs does nothing.
  Future<void> start({
    required int wizListenPort,
    required int boardHelloPort,
  }) => _hubStart ??= _startHub(wizListenPort, boardHelloPort);

  Future<void> _startHub(int wizListenPort, int boardHelloPort) async {
    Future<void> listen(int port, Future<void> Function() bind) async {
      try {
        await bind();
      } on SocketException catch (e) {
        throw ApiError(
          'unavailable',
          'cannot listen on UDP port $port (${e.osError?.message ?? e.message}). '
              'Is another omni hub or watch running?',
        );
      }
    }

    try {
      await listen(
        wizListenPort,
        () => startWizPush(listenPort: wizListenPort),
      );
      if (boardHelloPort > 0) {
        await listen(boardHelloPort, () => _listenForHellos(boardHelloPort));
      }
      _running = true;
      for (final d in await DriftDeviceStore(_core.db).all()) {
        startLive(d);
      }
      _core.flows.startTimers();
      _hubTimers.add(
        Timer.periodic(
          const Duration(seconds: 1),
          (_) => _track(_things.tick(DateTime.now())),
        ),
      );
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  /// Stops what [start] started. Commands keep working.
  Future<void> stop() async {
    _hubStart = null;
    _running = false;
    for (final t in _hubTimers) {
      t.cancel();
    }
    _hubTimers.clear();
    for (final id in _polls.keys.toList()) {
      stopLive(id);
    }
    for (final d in await DriftDeviceStore(_core.db).all()) {
      _core.mqtt.unwatch(d.id);
    }
    _core.flows.stopTimers();
    _helloSocket?.close();
    _helloSocket = null;
    final push = _wizPush;
    _wizPush = null;
    await push?.stop();
  }

  /// Stops the hub's timers and sockets as the engine closes.
  Future<void> shutdown() async {
    for (final t in _hubTimers) {
      t.cancel();
    }
    for (final t in _polls.values) {
      t.cancel();
    }
    _helloSocket?.close();
    await _wizPush?.stop();
  }

  /// Starts what keeps a device's state live in the hub: board setup, the
  /// MQTT topics it publishes on, its state poll and WiZ pushes.
  void startLive(Device d, {bool provision = true}) {
    final manifest = _core.registry[d.driverId];
    if (provision && isBoardDriver(manifest)) {
      _track(_boards.provisionQuietly(d.id));
    }
    if (manifest?.transport.type == TransportType.mqtt) {
      _track(
        _core.mqtt.watch(d, manifest!).catchError((Object e) {
          _emit({'event': 'device.offline', 'device': d.id, 'error': '$e'});
        }),
      );
    }
    if (d.driverId == 'philips_wiz_udp' && d.stableId != null) {
      _track(_wizPush?.add(d) ?? Future.value());
    }
    _polls.remove(d.id)?.cancel();
    final seconds = manifest?.statePoll?['intervalSeconds'];
    if (seconds is int && seconds > 0) {
      final id = d.id;
      _polls[id] = Timer.periodic(Duration(seconds: seconds), (_) {
        // Tracked so close() waits for a poll in flight instead of closing
        // the database under it.
        _track(() async {
          try {
            // A poll runs unattended, so it never puts a pairing prompt on a TV.
            await _core.devices.refreshState(id, allowPairing: false);
          } catch (e) {
            _emit({'event': 'device.pollFailed', 'device': id, 'error': '$e'});
          }
        }());
      });
    }
  }

  void stopLive(String id) {
    _polls.remove(id)?.cancel();
    _core.mqtt.unwatch(id);
    _wizPush?.remove(id);
  }

  /// Listens for the hello every OmniFlow board on Wi-Fi broadcasts.
  Future<void> _listenForHellos(int port) async {
    if (_helloSocket != null) return;
    final socket = _helloSocket = await UdpTransport.bind(
      port: port,
      tap: _core.tap,
    );
    socket.incoming.listen((d) {
      final Object? json;
      try {
        json = jsonDecode(d.text);
      } on FormatException {
        return;
      }
      if (json is Map &&
          json['event'] == 'hello' &&
          json['node'] is String &&
          isLocalNetworkAddress(d.address)) {
        _boards.boardEvent(
          Map<String, Object?>.from(json),
          null,
          d.address.address,
        );
      }
    });
  }

  /// Starts live state from every WiZ device that has a stable id (its MAC).
  Future<int> startWizPush({required int listenPort}) async {
    final bulbs = [
      for (final d in await DriftDeviceStore(_core.db).all())
        if (d.driverId == 'philips_wiz_udp' && d.stableId != null) d,
    ];
    var push = _wizPush;
    if (push == null) {
      push = _wizPush = await WizPushManager.start(
        devices: _core.devices,
        listenPort: listenPort,
        tap: _core.tap,
      );
      push.firstBeats.listen(
        (b) => _emit({
          'event': 'wiz.firstBeat',
          'host': b.host,
          if (b.mac != null) 'mac': b.mac,
        }),
      );
      push.errors.listen((e) => _emit({'event': 'wiz.error', 'error': '$e'}));
    }
    await push.watch(bulbs);
    return bulbs.length;
  }
}
