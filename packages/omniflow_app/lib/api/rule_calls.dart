import 'engine_calls.dart' show EngineCalls, Json;
import 'engine_client.dart';

/// One value a rule field can use at a rule path, from the trigger or an
/// earlier step: a `rule.tokens` row. [token] is the template's inside
/// (`%reply.body`, `msg.value`), [label] its short words ("Web reply ·
/// body"), [from] where it comes from, [kind] `text`, `number`, `bool`,
/// `object`, `list` or `any`.
class RuleToken {
  const RuleToken({
    required this.token,
    required this.label,
    this.from = '',
    this.kind = 'any',
  });

  factory RuleToken.fromJson(Json json) => RuleToken(
    token: RuleCalls.inside('${json['token'] ?? ''}'),
    label: '${json['label'] ?? json['token'] ?? ''}',
    from: '${json['from'] ?? ''}',
    kind: '${json['kind'] ?? 'any'}',
  );

  final String token;
  final String label;
  final String from;
  final String kind;

  /// The template a field holds for it: `{{%reply.body}}`.
  String get template => '{{$token}}';
}

/// The rule editor's calls beyond saving and testing a rule.
abstract final class RuleCalls {
  static const tokens = 'rule.tokens';

  /// [rule] as the editor holds it now, and the rule path of the field's
  /// step (`then[2]`, `then[0].then[1]`).
  static Json tokensArgs(Json rule, String path) => {
    'rule': rule,
    'path': path,
  };

  static List<RuleToken> tokensOf(Json result) => [
    for (final t in (result['tokens'] as List? ?? const []))
      if (t is Map) RuleToken.fromJson(Map<String, Object?>.from(t)),
  ];

  /// The values available at [path], or none when the call fails: the
  /// field still takes typed text.
  static Future<List<RuleToken>> fetch(
    EngineClient client,
    Json rule,
    String path,
  ) async {
    try {
      final r = await client.call(tokens, tokensArgs(rule, path));
      return r['ok'] == true ? tokensOf(r) : const [];
    } on Object {
      return const [];
    }
  }

  /// The `automation.save` args that put back an automation as
  /// `automation.get` read it before it was removed: the same form, spec
  /// and id. It is trusted only when it had been approved, so an agent's
  /// automation still waiting for review comes back waiting.
  static Json restoreArgs(Json record) => {
    'form': record['source'] ?? 'rule',
    'spec': record['spec'],
    'trusted': record['approved'] == true,
    if (record['id'] case final String id) 'id': id,
  };

  /// Saves [record] again for Undo. False when the engine refused it.
  static Future<bool> restore(EngineClient client, Json record) async {
    try {
      final r = await client.call(
        EngineCalls.automationSave,
        restoreArgs(record),
      );
      return r['ok'] == true;
    } on Object {
      return false;
    }
  }

  /// A token's inside without its braces: `{{%answer}}` and `%answer` both
  /// give `%answer`.
  static String inside(String token) {
    final t = token.trim();
    return t.startsWith('{{') && t.endsWith('}}')
        ? t.substring(2, t.length - 2).trim()
        : t;
  }
}
