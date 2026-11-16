import 'dart:convert';

import 'flow.dart';

/// The steps that send a value out of the run: to a device (a phone, a TV,
/// a board, an MQTT topic), to the web, into a global variable an agent can
/// read back, or into another automation.
const _sinks = {
  'device_capability',
  'device_toggle',
  'http_request',
  'run_flow',
};

/// The run variable each step fills when it names none with `as`.
const _defaultVar = {
  'get_value': 'value',
  'format_text': 'text',
  'calculate': 'result',
  'for_each': 'item',
  'ask': 'answer',
  'device_capability': 'state',
  'http_request': 'reply',
};

final _placeholder = RegExp(r'\{\{(.*?)\}\}', dotAll: true);

/// `msg` itself, or its `payload` or `shared` part: what the trigger
/// brought (a notification, a calendar event, a song title, shared text).
final _triggerWords = RegExp(r'\bmsg\b(?!\s*\.\s*(?!payload\b|shared\b))');
final _runVar = RegExp(r'%([A-Za-z_][A-Za-z0-9_]*)');

/// Why [flow], saved untrusted (by an agent), may not be saved, or null.
///
/// An untrusted automation may show what a trigger brought to the person
/// (a notify step) and keep it in a run variable, but never send it on: a
/// device step, a web request, a global variable or another automation
/// that reads `msg.payload` (or a run variable filled from it) is refused,
/// so a notification's one-time code cannot leave by a step an agent wrote.
String? untrustedTriggerTextProblem(FlowSpec flow) {
  final tainted = <String>{};
  bool reads(Object? config) {
    final text = jsonEncode(config);
    for (final m in _placeholder.allMatches(text)) {
      final inside = m.group(1)!;
      if (_triggerWords.hasMatch(inside)) return true;
      if (_runVar.allMatches(inside).any((v) => tainted.contains(v[1]))) {
        return true;
      }
    }
    return false;
  }

  for (var grew = true; grew;) {
    grew = false;
    for (final n in flow.nodes) {
      final out = _filledVar(n);
      if (out == null || tainted.contains(out)) continue;
      if (reads(_inputsOf(n))) grew = tainted.add(out) || grew;
    }
  }
  for (final n in flow.nodes) {
    final global =
        n.type == 'set_variable' && '${n.config['name']}'.startsWith(r'$');
    if (!_sinks.contains(n.type) && !global) continue;
    if (!reads(_inputsOf(n))) continue;
    final step = n.label.isEmpty ? n.type : n.label;
    return 'a rule an agent saves cannot send what its trigger brought (a '
        'notification, a calendar event, a song, shared text) to a device, '
        'a web request, a variable or another automation, and "$step" '
        'does. Show it with a notify step instead, or ask the user to save '
        'the rule';
  }
  return null;
}

/// The run variable [n] fills, without its `%`, or null.
String? _filledVar(NodeSpec n) {
  if (n.type == 'set_variable') {
    final name = '${n.config['name']}';
    return name.startsWith('%') ? name.substring(1) : null;
  }
  final as = n.config['as'];
  if (as is String && as.startsWith('%')) return as.substring(1);
  return _defaultVar[n.type];
}

/// What [n] reads, leaving out the names it writes to.
Map<String, Object?> _inputsOf(NodeSpec n) => {
  for (final e in n.config.entries)
    if (e.key != 'as' && !(n.type == 'set_variable' && e.key == 'name'))
      e.key: e.value,
};
