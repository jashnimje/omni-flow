import 'engine_core.dart';
import '../dag/flow_engine.dart';
import '../dag/web_request.dart';
import '../storage/database.dart';

/// What the flow engine reaches through the engine: devices, the stored
/// globals and run log, and the event stream.
///
/// A flow runs unattended and may be deployed by an agent, so it never
/// starts a pairing: an unpaired TV fails the node with needs_user instead
/// of showing a prompt on every run.
class EngineFlowHost implements FlowHost {
  EngineFlowHost(this._core);

  final EngineCore _core;

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) async => (await _core.devices.invoke(
    deviceId,
    capabilityId,
    params,
    allowPairing: false,
    by: flowId,
  )).reply.json;

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) async => (await _core.devices.toggle(
    deviceId,
    capabilityId,
    // A flow runs unattended, so it never puts a pairing prompt on a TV.
    allowPairing: false,
    by: flowId,
  )).reply.json;

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
  void emit(Map<String, Object?> event) => _core.emit(event);

  @override
  Stream<Map<String, Object?>> get events => _core.events;
}
