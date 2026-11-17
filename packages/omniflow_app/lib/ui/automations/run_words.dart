import 'package:omniflow_engine/omniflow_engine.dart' show clockWords;

/// A time of day in a step's words ("19:30"), not part of a longer number
/// and not already followed by AM or PM.
final _clock = RegExp(
  r'(?<![\d:.])([01]?\d|2[0-3]):([0-5]\d)(?![\d:]|\s?[AaPp][Mm])',
);

/// A step's words as a row shows them: capitalised like the sentence and
/// the diagram ("If between 6:00 PM and 11:00 PM"), with each time of day
/// as this phone reads the time. The words of a stored run or flow were
/// written when it was saved, on a 24-hour clock.
String stepWords(String text, {required bool hour12}) {
  var s = text.trim();
  if (hour12) {
    s = s.replaceAllMapped(_clock, (m) => clockWords(m[0], hour12: true));
  }
  return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
