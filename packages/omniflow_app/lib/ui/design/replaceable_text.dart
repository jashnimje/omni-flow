import 'package:flutter/widgets.dart';

/// Text the user will most likely replace, such as a suggested name. It
/// starts all selected, and the field's first tap selects it all again, so
/// typing replaces it instead of landing in the middle of it.
class ReplaceableText extends TextEditingController {
  ReplaceableText(String text)
    : super.fromValue(
        TextEditingValue(
          text: text,
          selection: TextSelection(baseOffset: 0, extentOffset: text.length),
        ),
      );

  var _tapped = false;

  /// For the field's `onTap`.
  void firstTap() {
    if (_tapped) return;
    _tapped = true;
    selection = TextSelection(baseOffset: 0, extentOffset: text.length);
  }
}
