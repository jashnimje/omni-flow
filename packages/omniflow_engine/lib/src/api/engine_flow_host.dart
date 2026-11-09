import 'engine_core.dart';
import '../dag/flow_engine.dart';
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
    Map<String, Object?> params,
  ) async => (await _core.devices.invoke(
    deviceId,
    capabilityId,
    params,
    allowPairing: false,
  )).reply.json;

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId,
  ) async => (await _core.devices.toggle(
    deviceId,
    capabilityId,
    // A flow runs unattended, so it never puts a pairing prompt on a TV.
    allowPairing: false,
  )).reply.json;

  @override
  Future<void> saveGlobal(String name, Object? value) =>
      DriftGlobalStore(_core.db).put(name, value, DateTime.now().toUtc());

  @override
  Future<void> saveTrace(Map<String, Object?> trace) =>
      ExecutionLogStore(_core.db).add(trace);

  @override
  void emit(Map<String, Object?> event) => _core.emit(event);

  @override
  Stream<Map<String, Object?>> get events => _core.events;
}
