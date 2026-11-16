import 'package:flutter/material.dart';

import '../../state/clock.dart' show timeOfDayText;
import '../design/design.dart';

/// Asks for a name in a sheet, starting from [initial]. Null when closed.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
  String action = 'Save',
  String hint = 'Arrive home',
}) => showPromptSheet(
  context,
  title: title,
  label: 'Name',
  initial: initial,
  action: action,
  hint: hint,
);

/// "Today 19:02", "Yesterday 18:47", "3 Nov 09:12", or with [hour12]
/// "Today 7:02 PM".
String whenText(DateTime t, {DateTime? now, bool hour12 = false}) {
  final at = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  // Calendar days as UTC dates: local midnights are 23 or 25 hours apart
  // across a clock change.
  final today = DateTime.utc(n.year, n.month, n.day);
  final day = DateTime.utc(at.year, at.month, at.day);
  final time = timeOfDayText(hour12, at);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today $time';
  if (diff == 1) return 'Yesterday $time';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${at.day} ${months[at.month - 1]} $time';
}

/// [whenText] for the middle of a sentence: "ran today 19:02".
String whenInline(DateTime at, {DateTime? now, bool hour12 = false}) {
  final s = whenText(at, now: now, hour12: hour12);
  return s.startsWith('Today') || s.startsWith('Yesterday')
      ? '${s[0].toLowerCase()}${s.substring(1)}'
      : s;
}

/// "1.4 s", "320 ms", "2 min".
String tookText(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
  if (d.inSeconds < 60) {
    final s = d.inMilliseconds / 1000;
    return '${s.toStringAsFixed(s < 10 ? 1 : 0)} s';
  }
  return '${d.inMinutes} min';
}
