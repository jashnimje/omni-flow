import 'automation_view.dart';
import '../dag/aligned_times.dart' show alignedWords;
import '../dag/people_triggers.dart' show personDriver;

/// The sentence of a held state trigger, a people trigger, the engine
/// starting, or an interval lined up on the clock. Null for every other
/// trigger, which [SentenceContext.trigger] words itself.
String? rulesCoreTriggerWords(SentenceContext w, Map<String, Object?> t) {
  if (t['on'] is String && t['for'] is int) return 'When ${heldWords(w, t)}';
  if (t['on'] != null) return null;
  if (t['people'] case final String kind) {
    return kind == 'first_arrives'
        ? 'When the first person gets home'
        : 'When the last person leaves';
  }
  if (t['event'] == 'engine_started') return 'When OmniFlow starts';
  if (t['interval'] case final int seconds
      when t['offset'] != null || t['between'] != null) {
    final every = seconds == 3600
        ? 'Every hour'
        : 'Every ${SentenceContext.seconds(seconds)}';
    final aligned = alignedWords(
      seconds,
      t['offset'] as int? ?? 0,
      (t['between'] as List?)?.cast<String>(),
    );
    return '$every $aligned';
  }
  return null;
}

/// "the front door has been on for 5 min", "I have been away for 10 min",
/// "the living room temperature has been above 28 for 15 min".
String heldWords(SentenceContext w, Map<String, Object?> t) {
  final ref = t['on'] as String;
  final dot = ref.indexOf('.');
  final thing = ref.substring(0, dot);
  final key = ref.substring(dot + 1);
  final how = SentenceContext.duration(t['for']);
  final crosses = t['crosses'];
  if (crosses is Map && crosses.isNotEmpty) {
    return '${w.state(ref)} has been ${crosses.keys.single} '
        '${crosses.values.single} for $how';
  }
  final change = t['change'];
  final to = change is Map ? change['to'] : null;
  if (key == 'home' && to is bool && w.drivers[thing]?.id == personDriver) {
    final where = to ? 'home' : 'away';
    return thing == w.person
        ? 'I have been $where for $how'
        : '${w.name(thing)} has been $where for $how';
  }
  return '${w.state(ref)} has been ${SentenceContext.value(to)} for $how';
}

/// The sentence of a people condition, or null for any other.
String? rulesCoreConditionWords(Map<String, Object?> c) =>
    switch (c['people']) {
      'all_away' => 'everyone is away',
      'anyone_home' => 'anyone is home',
      _ => null,
    };
