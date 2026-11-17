import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../dag/canonical.dart';
import '../devices/device_service.dart';
import '../storage/database.dart';

/// Writes every device state change to the capped history, and answers
/// `device.history`.
class DeviceHistoryLog {
  DeviceHistoryLog(this._core);

  final EngineCore _core;

  /// The state each device had at its last change, to tell what changed.
  final _last = <String, Map<String, Object?>>{};

  DriftHistoryStore get _store => DriftHistoryStore(_core.db);

  Future<void> seed() async {
    for (final d in await DriftDeviceStore(_core.db).all()) {
      _last[d.id] = d.state;
    }
  }

  void forget(String deviceId) => _last.remove(deviceId);

  /// The keys of [e]'s state that differ from the last change, as entries.
  void record(DeviceStateChanged e) {
    final id = e.device.id;
    final before = _last[id] ?? const {};
    final after = e.device.state;
    _last[id] = after;
    final at = DateTime.now().toUtc();
    // A driver whose pushes carry chatter (a WiZ heartbeat's rssi and
    // timestamps every few seconds) lists in `statePush.historyKeys` the
    // keys worth a history entry. The rest stay in state only.
    final only = _core.registry[e.device.driverId]?.statePush?['historyKeys'];
    final entries = [
      // A key that left the state (a WiZ speed once the bulb is out of
      // its scene) is not a change of its own.
      for (final key in after.keys)
        if ((only is! List || only.contains(key)) &&
            canonicalJson(before[key]) != canonicalJson(after[key]))
          HistoryEntry(at, key, after[key], by: e.by),
    ];
    if (entries.isEmpty) return;
    // Written one after another, so a read waits only for these writes.
    final write = _writes.then((_) => _store.add(id, entries));
    _writes = write.catchError((Object _) {});
    _core.track(write);
  }

  Future<void> _writes = Future.value();

  /// `{id, key?, limit?, since?}`: the newest changes first.
  Future<Map<String, Object?>> history(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    await _core.device(id);
    final limit = optIntArg(args, 'limit') ?? 100;
    if (limit < 1 || limit > _store.cap) {
      throw ApiError('invalid', 'limit must be 1 to ${_store.cap}');
    }
    await _writes;
    return {
      'entries': [
        for (final e in await _store.recent(
          id,
          key: optStringArg(args, 'key'),
          limit: limit,
          since: optDateArg(args, 'since'),
        ))
          e.toJson(),
      ],
    };
  }
}

/// Who changed a device through the core API rather than an automation.
const changedByUser = 'user';

/// Who changed a device when an agent sent the command through
/// `agent.call`. Habits and away lighting learn only from the user's own
/// changes, so an agent's are kept apart.
const changedByAgent = 'agent';

/// The caller `args` names: the agent when `agent.call` forced `by`, else
/// the user. Nothing else can be claimed.
String callerOf(Map<String, Object?> args) =>
    args['by'] == changedByAgent ? changedByAgent : changedByUser;
