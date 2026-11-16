import 'engine_calls.dart' show Json;

/// The engine commands the settings, board and device screens send, by
/// name, so every command the app sends is named in `lib/api/`. Each
/// screen still makes the call itself through the engine client.

/// Variables: `var.list`, `var.set`, `var.remove`.
abstract final class VarCalls {
  static const list = 'var.list';
  static const set = 'var.set';
  static const remove = 'var.remove';
}

/// What agents may do: `agent.access`, `agent.access.set`.
abstract final class AgentCalls {
  static const access = 'agent.access';
  static const setAccess = 'agent.access.set';
}

/// Backups: `config.export`, `config.import`.
abstract final class BackupCalls {
  static const export = 'config.export';
  static const import = 'config.import';
}

/// Boards on USB: the ports, flashing, finding one and setting it up.
abstract final class BoardCalls {
  static const ports = 'board.ports';
  static const flash = 'board.flash';
  static const setup = 'board.setup';
}

/// Devices beyond the unified calls: finding, reading one, adding one,
/// its SSH host key, and pointing it at a new address.
abstract final class DeviceCalls {
  static const list = 'device.list';
  static const get = 'device.get';
  static const discover = 'device.discover';
  static const hostKey = 'device.hostkey';
  static const add = 'thing.add';

  /// `device.move`: the engine adds [id] again at the address of [find],
  /// keeping its driver, name, room, settings and automations.
  static const move = 'device.move';

  static Json moveArgs(String id, Json find) => {
    'id': id,
    'host': find['host'],
    'port': ?find['port'],
    'stableId': ?find['stableId'],
  };
}

/// Flows, for the run log.
abstract final class FlowCalls {
  static const list = 'flow.list';
}
