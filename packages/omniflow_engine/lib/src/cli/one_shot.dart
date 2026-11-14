import '../api/local_client.dart';

/// How long a one-shot command waits for the automations its own change
/// triggered before it closes the engine it opened.
const oneShotFlowLimit = Duration(seconds: 2);

/// Closes [connection] once the automations the command just triggered
/// have run, waiting at most [limit].
///
/// With no hub, a command opens the engine itself and would close it before
/// the `device.stateChanged` event reached the flows, so a rule "when the
/// lamp turns on" never fired from `omni device invoke`. Waiting costs
/// nothing when no flow started. Through a hub nothing waits: the hub keeps
/// running and its flows see the event there.
Future<void> closeOneShot(
  EngineConnection connection, {
  Duration limit = oneShotFlowLimit,
}) async {
  try {
    if (connection is InProcessConnection) {
      await connection.engine.flows.settle(limit: limit);
    }
  } finally {
    await connection.close();
  }
}
