import 'dart:convert';

import 'engine_calls.dart' show Json;
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

  static const unremove = 'automation.unremove';

  /// Puts back the automation [record] (as `automation.get` read it) that
  /// was just removed: the engine restores it as it was, on or off, with
  /// its trust and versions, in one step. False when the engine refused.
  static Future<bool> restore(EngineClient client, Json record) async {
    final id = record['id'];
    if (id is! String) return false;
    try {
      final r = await client.call(unremove, {'id': id});
      return r['ok'] == true;
    } on Object {
      return false;
    }
  }

  static const words = 'rule.words';

  /// The engine's words for every part of [rule] as the editor holds it,
  /// and what still keeps it from being saved. Null when the engine does
  /// not answer, so the editor keeps the words it has.
  static Future<RuleWordsReply?> fetchWords(
    EngineClient client,
    Json rule,
  ) async {
    try {
      final r = await client.call(words, {'rule': rule});
      if (r['ok'] != true || r['parts'] is! List) return null;
      return RuleWordsReply.of(r);
    } on Object {
      return null;
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

/// One piece of a part's words: plain text, or a [blank] a tap edits on
/// its own (`device`, `value`, `time`, `days`), with the template [token]
/// it shows in words.
typedef RuleWordPiece = ({String text, String? blank, String? token});

/// What `rule.words` gives: each part's pieces, keyed by the part's JSON as
/// the editor sent it, and [missing], what still keeps the rule from being
/// saved.
class RuleWordsReply {
  const RuleWordsReply(this.parts, this.missing);

  factory RuleWordsReply.of(Json r) => RuleWordsReply({
    for (final p in (r['parts'] as List).whereType<Map>())
      if (p['part'] is Map)
        keyOf(p['part'] as Map): [
          for (final w in (p['words'] as List? ?? const []).whereType<Map>())
            (
              text: '${w['text'] ?? ''}',
              blank: w['blank'] as String?,
              token: w['token'] as String?,
            ),
        ],
  }, r['missing'] as String?);

  final Map<String, List<RuleWordPiece>> parts;
  final String? missing;

  /// The key a part's words are found by: its JSON.
  static String keyOf(Map part) => jsonEncode(part);
}
