import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../dag/canonical.dart';
import '../devices/device_service.dart';
import '../storage/database.dart';

/// The history key of a device that stopped answering (`false`) or
/// answers again (`true`). No driver state has it, so it reads apart from
/// state changes.
const historyOnlineKey = 'online';

/// The state key a TV or phone read sets false when the device did not
/// answer, and true when it did.
const reachableKey = 'reachable';

/// Writes every device state change to the capped history, and answers
/// `device.history`. A device that stops answering and comes back is
/// written too, once per transition, under [historyOnlineKey].
class DeviceHistoryLog {
  DeviceHistoryLog(this._core);

  final EngineCore _core;

  /// The state each device had at its last change, to tell what changed.
  final _last = <String, Map<String, Object?>>{};

  /// The devices last written as not answering, with when, so a poll that
  /// fails again is not a second entry and only a later answer is back.
  final _down = <String, DateTime>{};

  DriftHistoryStore get _store => DriftHistoryStore(_core.db);

  /// Reads each device's state and whether its newest answering entry
  /// says it stopped, so a restart does not write the same one again.
  Future<void> seed() async {
    for (final d in await DriftDeviceStore(_core.db).all()) {
      _last[d.id] = d.state;
      final newest = (await _store.recent(
        d.id,
        key: historyOnlineKey,
        limit: 1,
      )).firstOrNull;
      if (newest != null && newest.value == false) _down[d.id] = newest.at;
    }
  }

  void forget(String deviceId) {
    _last.remove(deviceId);
    _down.remove(deviceId);
  }

  /// The engine events that say a device did not answer: an MQTT watch
  /// that failed (`device.offline`) and a hub poll that failed
  /// (`device.pollFailed`).
  void observe(Map<String, Object?> event) {
    final kind = event['event'];
    if (kind != 'device.offline' && kind != 'device.pollFailed') return;
    final id = event['device'];
    if (id is String) _stopped(id, DateTime.now().toUtc());
  }

  void _stopped(String id, DateTime at) {
    if (_down.containsKey(id)) return;
    _down[id] = at;
    _write(id, [HistoryEntry(at, historyOnlineKey, false)]);
  }

  /// The keys of [e]'s state that differ from the last change, as entries,
  /// and a device that answers again after it stopped.
  void record(DeviceStateChanged e) {
    final id = e.device.id;
    final before = _last[id] ?? const {};
    final after = e.device.state;
    _last[id] = after;
    final at = DateTime.now().toUtc();
    // A TV or phone read that got no answer still saves its state, with
    // `reachable` false, and is not seen.
    if (after[reachableKey] == false) {
      // What it saved is a guess (a TV in deep standby is off), not a
      // change it reported.
      _stopped(id, at);
      return;
    } else if (_down[id] case final down?
        when e.device.lastSeen?.isAfter(down) ?? false) {
      _down.remove(id);
      _write(id, [HistoryEntry(at, historyOnlineKey, true)]);
    }
    // A driver whose pushes carry chatter (a WiZ heartbeat's rssi and
    // timestamps every few seconds) lists in `statePush.historyKeys` the
    // keys worth a history entry. The rest stay in state only.
    final only = _core.registry[e.device.driverId]?.statePush?['historyKeys'];
    final entries = [
      // A key that left the state (a WiZ speed once the bulb is out of
      // its scene) is not a change of its own.
      for (final key in after.keys)
        if (key != reachableKey &&
            (only is! List || only.contains(key)) &&
            canonicalJson(before[key]) != canonicalJson(after[key]))
          HistoryEntry(at, key, after[key], by: e.by),
    ];
    _write(id, entries);
  }

  void _write(String id, List<HistoryEntry> entries) {
    if (entries.isEmpty) return;
    // Written one after another, so a read waits only for these writes.
    final write = _writes.then((_) => _store.add(id, entries));
    _writes = write.catchError((Object _) {});
    _core.track(write);
  }

  Future<void> _writes = Future.value();

  /// `{id, key?, limit?, since?, before?}`: the newest changes first, only
  /// those after `since` and before `before`. Times are whole seconds, so
  /// a pager that asks `before` one second past its oldest entry and skips
  /// the entries of that second it already has misses none.
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
          before: optDateArg(args, 'before'),
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
