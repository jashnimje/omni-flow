import 'engine_calls.dart' show Json, SentencePart;
import 'engine_client.dart';

/// A rule offered from a habit: a `suggest.list` row. [words] is the plain
/// line ("You turn on Desk lamp around 19:05 most weekdays"), [spec] the
/// rule the editor opens, [sentence] its chips.
class Suggestion {
  const Suggestion({
    required this.id,
    required this.words,
    required this.spec,
    this.confidence = 0,
    this.sentence = const [],
  });

  factory Suggestion.fromJson(Json json) => Suggestion(
    id: '${json['id']}',
    words: '${json['words'] ?? ''}',
    spec: Map<String, Object?>.from(json['spec'] as Map? ?? const {}),
    confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
    sentence: SuggestionCalls.partsOf(json['sentence']),
  );

  final String id;
  final String words;
  final Json spec;
  final double confidence;
  final List<SentencePart> sentence;
}

/// One name the reader had to choose: the [text] typed, the thing it
/// picked, and the others it could be.
typedef ParseChoice = ({String text, String chosen, List<String> others});

/// What `rule.parse` made of a sentence. [spec] is null when it could not
/// make a rule, and [problem] then says why.
class ParsedRule {
  const ParsedRule({
    this.spec,
    this.sentence = const [],
    this.unknown = const [],
    this.choices = const [],
    this.notes = const [],
    this.problem,
  });

  factory ParsedRule.fromJson(Json json) => ParsedRule(
    spec: json['spec'] is Map
        ? Map<String, Object?>.from(json['spec'] as Map)
        : null,
    sentence: SuggestionCalls.partsOf(json['sentence']),
    unknown: [
      for (final w in (json['unknown'] as List? ?? const []))
        if (w is String) w,
    ],
    choices: [
      for (final a in (json['alternatives'] as List? ?? const []))
        if (a is Map)
          (
            text: '${a['text'] ?? ''}',
            chosen: '${(a['chosen'] as Map?)?['name'] ?? ''}',
            others: [
              for (final o in (a['options'] as List? ?? const []))
                if (o is Map) '${o['name']}',
            ],
          ),
    ],
    notes: [
      for (final n in (json['notes'] as List? ?? const []))
        if (n is String) n,
    ],
    problem: json['problem'] as String?,
  );

  final Json? spec;
  final List<SentencePart> sentence;
  final List<String> unknown;
  final List<ParseChoice> choices;
  final List<String> notes;
  final String? problem;
}

/// The "make it easy" calls: suggestions from habits, and a sentence read
/// as a rule. A failed call reads as nothing to offer, so Home and the
/// Automations tab never show an error for them.
abstract final class SuggestionCalls {
  static const list = 'suggest.list';
  static const dismiss = 'suggest.dismiss';
  static const parse = 'rule.parse';

  static List<SentencePart> partsOf(Object? list) => [
    for (final p in (list as List? ?? const []))
      if (p is Map) SentencePart.fromJson(Map<String, Object?>.from(p)),
  ];

  static Future<List<Suggestion>> fetch(EngineClient client) async {
    try {
      final r = await client.call(list, const {});
      if (r['ok'] != true) return const [];
      return [
        for (final s in (r['suggestions'] as List? ?? const []))
          if (s is Map) Suggestion.fromJson(Map<String, Object?>.from(s)),
      ];
    } on Object {
      return const [];
    }
  }

  /// Not now: the engine stops offering it. False when the call failed.
  static Future<bool> notNow(EngineClient client, String id) async {
    try {
      return (await client.call(dismiss, {'id': id}))['ok'] == true;
    } on Object {
      return false;
    }
  }

  /// [text] read as a rule. Null when the engine did not answer.
  static Future<ParsedRule?> read(EngineClient client, String text) async {
    try {
      final r = await client.call(parse, {'text': text});
      return r['ok'] == true ? ParsedRule.fromJson(r) : null;
    } on Object {
      return null;
    }
  }
}
