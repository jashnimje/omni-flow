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
