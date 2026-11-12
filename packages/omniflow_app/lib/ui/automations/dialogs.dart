import 'package:flutter/material.dart';

import '../design/design.dart';
import 'form_parts.dart' show Owning;

/// Asks for a name, starting from [initial]. Null when cancelled.
Future<String?> askName(
  BuildContext context, {
  required String title,
  String initial = '',
  String action = 'Save',
  String hint = 'Arrive home',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => Owning(
      [controller],
      child: StatefulBuilder(
        builder: (context, setState) {
          final name = controller.text.trim();
          return AlertDialog(
            title: Text(title),
            content: TextField(
              key: const ValueKey('name-field'),
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: 'Name', hintText: hint),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.of(context).pop(v.trim());
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              OmniButton(
                key: const ValueKey('name-ok'),
                label: action,
                expand: false,
                onPressed: name.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(name),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// "Today 19:02", "Yesterday 18:47", "3 Nov 09:12".
String whenText(DateTime t, {DateTime? now}) {
  final at = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  // Calendar days as UTC dates: local midnights are 23 or 25 hours apart
  // across a clock change.
  final today = DateTime.utc(n.year, n.month, n.day);
  final day = DateTime.utc(at.year, at.month, at.day);
  final time =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
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
String whenInline(DateTime at, {DateTime? now}) {
  final s = whenText(at, now: now);
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
