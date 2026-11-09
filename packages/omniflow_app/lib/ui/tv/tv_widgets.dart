import 'package:flutter/material.dart';

import '../../api/tv_calls.dart';
import 'tv_controller.dart';

String formatBytes(int? bytes) {
  if (bytes == null) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '$bytes B'
      : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

String formatDate(DateTime? time) {
  if (time == null) return '';
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// The running transfer's progress bar, hidden when nothing runs.
class TransferProgress extends StatelessWidget {
  const TransferProgress({super.key, required this.tv});

  final TvController tv;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tv,
    builder: (context, _) {
      final p = tv.progress;
      if (p == null) return const SizedBox.shrink();
      final total = p.total;
      final fraction = total == null || total <= 0
          ? null
          : (p.done / total).clamp(0.0, 1.0);
      return Padding(
        key: const ValueKey('tv-progress'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                progressLabel(p.op),
                if (p.done > 0)
                  total == null
                      ? formatBytes(p.done)
                      : '${formatBytes(p.done)} of ${formatBytes(total)}',
              ].join('  '),
              key: const ValueKey('tv-progress-text'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: fraction),
          ],
        ),
      );
    },
  );
}

String progressLabel(String op) => switch (op) {
  TvCalls.install || 'install' || 'push' => 'Installing',
  TvCalls.filesDownload || 'download' || 'recv' => 'Downloading',
  TvCalls.filesUpload || 'upload' || 'send' => 'Uploading',
  TvCalls.filesCopy || 'copy' => 'Copying',
  TvCalls.filesMove || 'move' => 'Moving',
  TvCalls.filesDelete || 'delete' => 'Deleting',
  _ => 'Working',
};

/// A short centred message with an optional retry, for empty and failed
/// lists.
class TvEmpty extends StatelessWidget {
  const TvEmpty({super.key, required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    ),
  );
}

/// Asks for one line of text, null when the user cancels.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  required String action,
  String? Function(String text)? validate,
  bool multiline = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(
    title: title,
    label: label,
    initial: initial,
    action: action,
    validate: validate,
    multiline: multiline,
  ),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.action,
    required this.validate,
    required this.multiline,
  });

  final String title;
  final String label;
  final String initial;
  final String action;
  final String? Function(String text)? validate;
  final bool multiline;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.validate?.call(_text.text);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('ask-text'),
        controller: _text,
        autofocus: true,
        minLines: 1,
        maxLines: widget.multiline ? 4 : 1,
        decoration: InputDecoration(labelText: widget.label, errorText: error),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('ask-text-ok'),
          onPressed: error == null
              ? () => Navigator.of(context).pop(_text.text)
              : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}
