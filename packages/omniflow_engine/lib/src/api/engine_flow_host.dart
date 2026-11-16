import 'dart:io' show SocketException;

import 'engine_core.dart';
import 'rules_host.dart';
import '../dag/error_text.dart';
import '../dag/flow_engine.dart';
import '../dag/web_request.dart';
import '../storage/database.dart';
import '../transports/udp_transport.dart' show TransportTimeoutException;

/// What the flow engine reaches through the engine: devices, the stored
/// globals and run log, and the event stream.
///
/// A flow runs unattended and may be deployed by an agent, so it never
/// starts a pairing: an unpaired TV fails the node with needs_user instead
/// of showing a prompt on every run.
class EngineFlowHost with EngineRulesHost implements FlowHost {
  EngineFlowHost(this._core);

  final EngineCore _core;

  @override
  EngineCore get rulesCore => _core;

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) async {
    final builtIn = _core.builtInThings[deviceId];
    if (builtIn != null &&
        await DriftDeviceStore(_core.db).get(deviceId) == null) {
      return builtIn(capabilityId, params, by: flowId);
    }
    return _plain(
      deviceId,
      () async => (await _core.devices.invoke(
        deviceId,
        capabilityId,
        params,
        allowPairing: false,
        by: flowId,
      )).reply.json,
    );
  }

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) => _plain(
    deviceId,
    () async => (await _core.devices.toggle(
      deviceId,
      capabilityId,
      // A flow runs unattended, so it never puts a pairing prompt on a TV.
      allowPairing: false,
      by: flowId,
    )).reply.json,
  );

  /// Runs [send], and turns a device that did not answer into plain words
  /// ("Desk lamp did not answer. Is it switched on?"), with the address
  /// and retry count only in the failure's details. The run tile, the
  /// notification and Needs you show the words.
  Future<Map<String, Object?>?> _plain(
    String deviceId,
    Future<Map<String, Object?>?> Function() send,
  ) async {
    try {
      return await send();
    } catch (e) {
      if (e is! TransportTimeoutException && e is! SocketException) rethrow;
      final name = (await DriftDeviceStore(_core.db).get(deviceId))?.name;
      throw PlainStepFailure(
        '${name ?? deviceId} did not answer. Is it switched on?',
        withoutTypeName('$e'),
      );
    }
  }

  @override
  Future<void> saveGlobal(String name, Object? value) =>
      DriftGlobalStore(_core.db).put(name, value, DateTime.now().toUtc());

  @override
  Future<void> saveTrace(Map<String, Object?> trace) =>
      ExecutionLogStore(_core.db).add(trace);

  /// Every daily start is marked before it runs, so the mark alone says
  /// whether [scheduled] ran.
  @override
  Future<bool> ranAt(String flowId, String scheduled) async =>
      await DriftGlobalStore(_core.db).get(scheduledGlobalKey(flowId)) ==
      scheduled;

  @override
  Future<void> markScheduled(String flowId, String scheduled) =>
      DriftGlobalStore(_core.db)
          .put(scheduledGlobalKey(flowId), scheduled, DateTime.now().toUtc());

  @override
  Future<String?> webSecret(String name) =>
      _core.secrets.read(webSecretKey(name));

  @override
  Future<Map<String, Object?>?> deviceState(String deviceId) async =>
      (await DriftDeviceStore(_core.db).get(deviceId))?.state;

  @override
  Future<List<String>> roomDevices(String room) async {
    final wanted = room.trim().toLowerCase();
    final match = (await DriftRoomStore(_core.db).all())
        .where((r) => r.id == room || r.name.trim().toLowerCase() == wanted)
        .firstOrNull;
    if (match == null) throw StateError('there is no room called $room');
    final devices = [
      for (final d in await DriftDeviceStore(_core.db).all())
        if (d.room == match.id) d,
    ]..sort((a, b) => (a.order ?? 1 << 30).compareTo(b.order ?? 1 << 30));
    return [for (final d in devices) d.id];
  }

  @override
  void emit(Map<String, Object?> event) => _core.emit(event);

  @override
  Stream<Map<String, Object?>> get events => _core.events;
}
