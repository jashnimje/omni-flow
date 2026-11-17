final _typeName = RegExp(
  r'^(\w+(Exception|Error)|Exception|Error|Bad state): ',
);

/// [text] without the leading `FooException: ` an exception's toString
/// adds, so a run log or an app screen shows only what went wrong.
String withoutTypeName(String text) {
  var out = text;
  while (_typeName.hasMatch(out)) {
    out = out.replaceFirst(_typeName, '');
  }
  return out;
}

/// [text] as a sentence: trimmed, with a full stop unless it already ends
/// with one, a question mark or an exclamation mark, so words joined after
/// a plain error never read "switched on?." or "Wi-Fi..". Empty stays
/// empty.
String asSentence(String text) {
  final out = text.trim();
  if (out.isEmpty || _sentenceEnd.hasMatch(out)) return out;
  return '$out.';
}

final _sentenceEnd = RegExp(r'[.?!]["\)]?$');

/// A step that failed, in words a person can act on ("Desk lamp did not
/// answer. Is it switched on?"), with the technical text ("no reply from
/// 10.0.2.81:38899 after 3 attempts") in [details] for the run log's
/// Details.
class PlainStepFailure implements Exception {
  const PlainStepFailure(this.message, this.details);

  final String message;
  final String details;

  @override
  String toString() => message;
}
