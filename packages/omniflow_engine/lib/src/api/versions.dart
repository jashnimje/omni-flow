import 'dart:convert';

import 'package:drift/drift.dart';

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
