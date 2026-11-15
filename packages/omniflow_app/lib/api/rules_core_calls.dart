import 'package:omniflow_engine/omniflow_engine.dart'
    show asIfMessage, ruleTriggerNodeId;

import 'engine_calls.dart';

/// The calls behind "Why didn't it run?", conflict warnings, version
/// history and "Try as if", with their argument shapes and the fields read
/// back. When the engine's shape changes, the change is made here.
abstract final class RulesCoreCalls {
  static const skips = 'automation.skips';
  static const conflicts = 'automation.conflicts';
  static const versions = 'automation.versions';
  static const restore = 'automation.restore';

  static Json idArgs(String id) => {'id': id};

  /// The user restores from the app, so it is trusted. The engine keeps a
  /// version an agent wrote untrusted anyway.
  static Json restoreArgs(String id, int version) => {
    'id': id,
    'version': version,
    'trusted': true,
  };

  /// A dry run of [rule] from its trigger [index], with an event made up
  /// for that trigger by the engine's rules.
  static Json tryAsIfArgs(Json rule, int index, {String? id}) {
    final when = rule['when'] as List? ?? const [];
    final trigger = Map<String, Object?>.from(when[index] as Map);
    return {
      ...EngineCalls.dryRunRuleArgs(rule, id: id),
      'trigger': ruleTriggerNodeId(index),
      'msg': asIfMessage(trigger),
    };
  }

  static List<Json> _rows(Object? list) => [
    for (final r in (list as List? ?? const []))
      if (r is Map) Map<String, Object?>.from(r),
  ];

  static List<SkipRecord> skipsOf(Json result) => [
    for (final j in _rows(result['skips'])) SkipRecord.fromJson(j),
  ];

  static List<ConflictRecord> conflictsOf(Json result) => [
    for (final j in _rows(result['conflicts'])) ConflictRecord.fromJson(j),
  ];

  static List<VersionRecord> versionsOf(Json result) => [
    for (final j in _rows(result['versions'])) VersionRecord.fromJson(j),
  ];
}

/// One trigger that fired without a run, and why, in words.
class SkipRecord {
  const SkipRecord({required this.at, required this.text, this.kind});

  factory SkipRecord.fromJson(Json json) => SkipRecord(
    at: DateTime.tryParse('${json['at']}')?.toLocal() ?? DateTime(0),
    text: '${json['text'] ?? json['reason'] ?? ''}',
    kind: json['kind'] as String?,
  );

  final DateTime at;

  /// "Front door turns on, but it was not between 18:00 and 23:00".
  final String text;
  final String? kind;
}

/// Two automations that set one device two ways on the same trigger.
class ConflictRecord {
  const ConflictRecord({required this.automations, required this.reason});

  factory ConflictRecord.fromJson(Json json) => ConflictRecord(
    automations: [
      for (final a in (json['automations'] as List? ?? const [])) '$a',
    ],
    reason: '${json['reason'] ?? ''}',
  );

  final List<String> automations;
  final String reason;
}

/// An earlier saved version of an automation.
class VersionRecord {
  const VersionRecord({
    required this.version,
    required this.at,
    required this.byYou,
    required this.name,
    this.sentence = const [],
  });

  factory VersionRecord.fromJson(Json json) => VersionRecord(
    version: (json['version'] as num?)?.toInt() ?? 0,
    at: DateTime.tryParse('${json['at']}')?.toLocal() ?? DateTime(0),
    byYou: json['source'] == 'you',
    name: '${json['name'] ?? ''}',
    sentence: [
      for (final p in (json['sentence'] as List? ?? const []))
        if (p is Map) SentencePart.fromJson(Map<String, Object?>.from(p)),
    ],
  );

  final int version;

  /// When a later save replaced it.
  final DateTime at;

  /// Whether you saved it, rather than an agent or an import.
  final bool byYou;
  final String name;
  final List<SentencePart> sentence;
}
