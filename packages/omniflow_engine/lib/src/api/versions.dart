import 'dart:convert';

import 'package:drift/drift.dart';

import '../dag/canonical.dart';
import '../storage/database.dart';

/// One earlier saved version of an automation: what it was before a save
/// replaced it.
class AutomationVersion {
  const AutomationVersion({
    required this.flowId,
    required this.version,
    required this.at,
    required this.form,
    required this.byUser,
    required this.flow,
    this.spec,
  });

  final String flowId;

  /// Counts up per automation: 1 is the oldest kept.
  final int version;

  /// When it was replaced.
  final DateTime at;

  /// How it was written: rule, link, graph or scene.
  final String form;

  /// Whether the user saved or approved it, rather than an agent or an
  /// import.
  final bool byUser;
  final Map<String, Object?> flow;
  final Map<String, Object?>? spec;

  String get name => '${spec?['name'] ?? flow['name'] ?? flowId}';

  /// What a `automation.save` takes to save it again.
  Map<String, Object?> saveArgs() => {
    'form': form,
    'spec': form == FlowRecord.graph || spec == null ? flow : spec,
    if (form == FlowRecord.rule || form == FlowRecord.scene) 'id': flowId,
    if (form == FlowRecord.rule || form == FlowRecord.link) 'replace': true,
  };

  /// Everything about it, so it can be put back as it was.
  Map<String, Object?> fullJson() => {
    'id': flowId,
    'version': version,
    'at': at.toUtc().toIso8601String(),
    'form': form,
    'byUser': byUser,
    'flow': flow,
    'spec': ?spec,
  };

  static AutomationVersion fromFullJson(Map<String, Object?> j) =>
      AutomationVersion(
        flowId: j['id'] as String,
        version: j['version'] as int,
        at: DateTime.parse(j['at'] as String),
        form: j['form'] as String,
        byUser: j['byUser'] == true,
        flow: Map<String, Object?>.from(j['flow'] as Map),
        spec: j['spec'] == null
            ? null
            : Map<String, Object?>.from(j['spec'] as Map),
      );

  Map<String, Object?> toJson() => {
    'id': flowId,
    'version': version,
    'at': at.toUtc().toIso8601String(),
    'form': form,
    'source': byUser ? 'you' : 'agent',
    'name': name,
  };
}

/// The last [keep] versions of each automation, in the engine's database,
/// in a table of their own made the first time it is needed.
class AutomationVersionStore {
  AutomationVersionStore(this._db, {this.keep = 10});

  final OmniDatabase _db;
  final int keep;

  static const _table = 'automation_versions';
  static final _made = Expando<Future<void>>('automation versions table');

  Future<void> _ensure() => _made[_db] ??= _db.customStatement(
    'CREATE TABLE IF NOT EXISTS $_table ('
    'row INTEGER PRIMARY KEY AUTOINCREMENT, '
    'flow_id TEXT NOT NULL, version INTEGER NOT NULL, at TEXT NOT NULL, '
    'form TEXT NOT NULL, by_user INTEGER NOT NULL, flow_json TEXT NOT NULL, '
    'spec_json TEXT)',
  );

  /// Keeps [record] as the newest earlier version of its automation.
  Future<void> add(FlowRecord record, DateTime at) async {
    await _ensure();
    final id = '${record.json['id']}';
    await _db.transaction(() async {
      final last = await _db
          .customSelect(
            'SELECT MAX(version) AS v FROM $_table WHERE flow_id = ?',
            variables: [Variable.withString(id)],
          )
          .getSingle();
      final version = (last.read<int?>('v') ?? 0) + 1;
      await _db.customStatement(
        'INSERT INTO $_table (flow_id, version, at, form, by_user, '
        'flow_json, spec_json) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          version,
          at.toUtc().toIso8601String(),
          record.source,
          record.trusted ? 1 : 0,
          jsonEncode(record.json),
          record.spec == null ? null : jsonEncode(record.spec),
        ],
      );
      await _db.customStatement(
        'DELETE FROM $_table WHERE flow_id = ? AND row NOT IN '
        '(SELECT row FROM $_table WHERE flow_id = ? ORDER BY version DESC '
        'LIMIT ?)',
        [id, id, keep],
      );
    });
  }

  /// The kept versions of [flowId], newest first.
  Future<List<AutomationVersion>> of(String flowId) async {
    await _ensure();
    final rows = await _db
        .customSelect(
          'SELECT * FROM $_table WHERE flow_id = ? ORDER BY version DESC',
          variables: [Variable.withString(flowId)],
        )
        .get();
    return [for (final r in rows) _version(r)];
  }

  Future<AutomationVersion?> get(String flowId, int version) async =>
      (await of(flowId)).where((v) => v.version == version).firstOrNull;

  /// Drops every kept version of [flowId], so a new automation saved later
  /// under the same id starts with none.
  Future<void> removeOf(String flowId) async {
    await _ensure();
    await _db.customStatement('DELETE FROM $_table WHERE flow_id = ?', [
      flowId,
    ]);
  }

  /// Puts back [versions] that [removeOf] dropped, as they were.
  Future<void> putBack(List<AutomationVersion> versions) async {
    await _ensure();
    for (final v in versions) {
      await _db.customStatement(
        'INSERT INTO $_table (flow_id, version, at, form, by_user, '
        'flow_json, spec_json) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          v.flowId,
          v.version,
          v.at.toUtc().toIso8601String(),
          v.form,
          v.byUser ? 1 : 0,
          jsonEncode(v.flow),
          v.spec == null ? null : jsonEncode(v.spec),
        ],
      );
    }
  }

  static AutomationVersion _version(QueryRow r) {
    final spec = r.read<String?>('spec_json');
    return AutomationVersion(
      flowId: r.read<String>('flow_id'),
      version: r.read<int>('version'),
      at: DateTime.parse(r.read<String>('at')),
      form: r.read<String>('form'),
      byUser: r.read<int>('by_user') == 1,
      flow: Map<String, Object?>.from(
        jsonDecode(r.read<String>('flow_json')) as Map,
      ),
      spec: spec == null
          ? null
          : Map<String, Object?>.from(jsonDecode(spec) as Map),
    );
  }
}

/// Saves to the stored automations, one at a time per database.
final _saving = Expando<Future<void>>('automation saves');

/// Runs [save] after every other save of [db]'s automations, and keeps the
/// version of each automation it changed, so a scene capture, a restore and
/// an import keep history as an editor save does. Two saves of one id at
/// once each keep the version the other replaced.
Future<Map<String, Object?>> keepingVersionsOf(
  OmniDatabase db,
  Future<Map<String, Object?>> Function() save,
) {
  final next = (_saving[db] ?? Future<void>.value()).then((_) async {
    final store = DriftFlowStore(db);
    final before = {for (final r in await store.all()) '${r.json['id']}': r};
    final saved = await save();
    final versions = AutomationVersionStore(db);
    final now = DateTime.now();
    for (final r in await store.all()) {
      final old = before['${r.json['id']}'];
      if (old != null && versionContent(r) != versionContent(old)) {
        await versions.add(old, now);
      }
    }
    return saved;
  });
  _saving[db] = next.then<void>((_) {}, onError: (Object _) {});
  return next;
}

/// What a version is, without its on or off.
String versionContent(FlowRecord r) => canonicalJson({
  'flow': {...r.json}..remove('enabled'),
  'spec': r.spec,
  'source': r.source,
});

/// How long a removed automation can be put back.
const removedKeptFor = Duration(days: 30);

/// One automation the user removed, kept with its versions for
/// [removedKeptFor] so it can be put back.
class RemovedAutomation {
  const RemovedAutomation({
    required this.record,
    required this.removedAt,
    required this.versions,
  });

  final FlowRecord record;
  final DateTime removedAt;
  final List<AutomationVersion> versions;

  String get id => '${record.json['id']}';
  String get name => '${record.spec?['name'] ?? record.json['name'] ?? id}';
  DateTime get keptUntil => removedAt.add(removedKeptFor);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'form': record.source,
    'removedAt': removedAt.toUtc().toIso8601String(),
    'keptUntil': keptUntil.toUtc().toIso8601String(),
    'versions': versions.length,
  };
}

/// The recently removed automations, newest first, in a table of their
/// own. A second removal of one id replaces the first.
class RemovedAutomationStore {
  RemovedAutomationStore(this._db);

  final OmniDatabase _db;

  static const _table = 'automation_removed';
  static final _made = Expando<Future<void>>('removed automations table');

  Future<void> _ensure() => _made[_db] ??= _db.customStatement(
    'CREATE TABLE IF NOT EXISTS $_table ('
    'flow_id TEXT PRIMARY KEY, removed_at TEXT NOT NULL, '
    'record_json TEXT NOT NULL, versions_json TEXT NOT NULL)',
  );

  Future<void> add(
    FlowRecord record,
    List<AutomationVersion> versions,
    DateTime at,
  ) async {
    await _ensure();
    await _db.customStatement(
      'INSERT OR REPLACE INTO $_table (flow_id, removed_at, record_json, '
      'versions_json) VALUES (?, ?, ?, ?)',
      [
        '${record.json['id']}',
        at.toUtc().toIso8601String(),
        jsonEncode({
          'flow': record.json,
          'enabled': record.enabled,
          'approved': record.approved,
          'trusted': record.trusted,
          'source': record.source,
          'spec': ?record.spec,
        }),
        jsonEncode([for (final v in versions) v.fullJson()]),
      ],
    );
  }

  /// Drops what was removed more than [removedKeptFor] before [now].
  Future<void> purge(DateTime now) async {
    await _ensure();
    await _db.customStatement('DELETE FROM $_table WHERE removed_at < ?', [
      now.subtract(removedKeptFor).toUtc().toIso8601String(),
    ]);
  }

  /// What is kept as at [now], newest first.
  Future<List<RemovedAutomation>> all(DateTime now) async {
    await purge(now);
    final rows = await _db
        .customSelect('SELECT * FROM $_table ORDER BY removed_at DESC')
        .get();
    return [for (final r in rows) _removed(r)];
  }

  Future<RemovedAutomation?> get(String id, DateTime now) async =>
      (await all(now)).where((r) => r.id == id).firstOrNull;

  Future<void> forget(String id) async {
    await _ensure();
    await _db.customStatement('DELETE FROM $_table WHERE flow_id = ?', [id]);
  }

  static RemovedAutomation _removed(QueryRow r) {
    final j = Map<String, Object?>.from(
      jsonDecode(r.read<String>('record_json')) as Map,
    );
    return RemovedAutomation(
      record: FlowRecord(
        Map<String, Object?>.from(j['flow'] as Map),
        enabled: j['enabled'] == true,
        approved: j['approved'] == true,
        trusted: j['trusted'] == true,
        source: '${j['source']}',
        spec: j['spec'] == null
            ? null
            : Map<String, Object?>.from(j['spec'] as Map),
      ),
      removedAt: DateTime.parse(r.read<String>('removed_at')),
      versions: [
        for (final v in (jsonDecode(
          r.read<String>('versions_json'),
        ) as List).cast<Map>())
          AutomationVersion.fromFullJson(Map<String, Object?>.from(v)),
      ],
    );
  }
}

/// The automations removing a device turned off, by that device, so adding
/// it back turns each on again once every device it lost is back.
class TurnedOffByRemoval {
  TurnedOffByRemoval(this._db);

  final OmniDatabase _db;

  static const _table = 'automation_turned_off';
  static final _made = Expando<Future<void>>('turned off table');

  Future<void> _ensure() => _made[_db] ??= _db.customStatement(
    'CREATE TABLE IF NOT EXISTS $_table ('
    'device_id TEXT NOT NULL, flow_id TEXT NOT NULL, '
    'PRIMARY KEY (device_id, flow_id))',
  );

  Future<void> add(String deviceId, Iterable<String> flowIds) async {
    await _ensure();
    for (final f in flowIds) {
      await _db.customStatement(
        'INSERT OR IGNORE INTO $_table (device_id, flow_id) VALUES (?, ?)',
        [deviceId, f],
      );
    }
  }

  /// Every automation a removal holds off.
  Future<Set<String>> held() async {
    await _ensure();
    return {
      for (final r
          in await _db
              .customSelect('SELECT DISTINCT flow_id FROM $_table')
              .get())
        r.read<String>('flow_id'),
    };
  }

  /// Forgets [deviceId], and returns the automations it held off that no
  /// other removed device still holds off.
  Future<List<String>> back(String deviceId) async {
    await _ensure();
    final held = await _db
        .customSelect(
          'SELECT flow_id FROM $_table WHERE device_id = ?',
          variables: [Variable.withString(deviceId)],
        )
        .get();
    await _db.customStatement('DELETE FROM $_table WHERE device_id = ?', [
      deviceId,
    ]);
    final free = <String>[];
    for (final r in held) {
      final id = r.read<String>('flow_id');
      final still = await _db
          .customSelect(
            'SELECT 1 FROM $_table WHERE flow_id = ? LIMIT 1',
            variables: [Variable.withString(id)],
          )
          .get();
      if (still.isEmpty) free.add(id);
    }
    return free;
  }

  /// Forgets [flowId] everywhere, once it is removed or turned on by hand.
  Future<void> forgetFlow(String flowId) async {
    await _ensure();
    await _db.customStatement('DELETE FROM $_table WHERE flow_id = ?', [
      flowId,
    ]);
  }
}
