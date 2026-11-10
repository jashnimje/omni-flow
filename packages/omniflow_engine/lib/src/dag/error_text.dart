final _typeName = RegExp(r'^(\w+(Exception|Error)|Exception|Error): ');

/// [text] without the leading `FooException: ` an exception's toString
/// adds, so a run log or an app screen shows only what went wrong.
String withoutTypeName(String text) {
  var out = text;
  while (_typeName.hasMatch(out)) {
    out = out.replaceFirst(_typeName, '');
  }
  return out;
}
