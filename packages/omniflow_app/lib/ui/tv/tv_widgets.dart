import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/tv_calls.dart';
import '../design/design.dart';
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

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// A file date as the mockups write it: "3 Nov", with the year when it is
/// not this year.
String formatDate(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final t = time.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final day = '${t.day} ${_months[t.month - 1]}';
  return t.year == today.year ? day : '$day ${t.year}';
}

/// What the app in front is called: the label the TV gave, else a name made
/// from its package (`com.netflix.ninja` reads "Netflix"), never the bare
/// package.
String appNameOf(String package, {String? label}) {
  if (label != null && label.isNotEmpty) return label;
  const generic = {
    'com',
    'org',
    'net',
    'in',
    'co',
    'io',
    'tv',
    'android',
    'google',
    'apps',
    'app',
    'mobile',
    'amazon',
  };
  final word = package
      .split('.')
      .where((s) => s.isNotEmpty && !generic.contains(s.toLowerCase()))
      .firstOrNull;
  final name = word ?? package.split('.').last;
  return name.isEmpty
      ? package
      : '${name[0].toUpperCase()}${name.substring(1)}';
}

/// Brand colours of apps people know at a glance; others get a stable
/// colour of their own.
const _brandColours = {
  'com.netflix.ninja': Color(0xFFE50914),
  'com.google.android.youtube.tv': Color(0xFFFF0000),
  'com.google.android.youtube.tvmusic': Color(0xFFFF0000),
  'com.google.android.youtube.tvkids': Color(0xFFFF0000),
  'com.graymatrix.did': Color(0xFF8230C6),
  'in.startv.hotstar': Color(0xFF0F1A44),
  'com.amazon.amazonvideo.livingroom': Color(0xFF1A98FF),
  'com.spotify.tv.android': Color(0xFF1DB954),
  'com.disney.disneyplus': Color(0xFF113CCF),
  'com.sonyliv': Color(0xFF2B2B2B),
};

const _badgePalette = [
  Color(0xFF8E2C2C),
  Color(0xFF1F5A99),
  Color(0xFF6A3D9A),
  Color(0xFF2E6B3A),
  Color(0xFF00695C),
  Color(0xFF8A2E5C),
  Color(0xFF5D4037),
  Color(0xFF34408F),
  Color(0xFF455A64),
];

Color appColourOf(String package) =>
    _brandColours[package] ??
    _badgePalette[package.codeUnits.fold<int>(
          0,
          (a, b) => (a * 31 + b) & 0x7fffffff,
        ) %
        _badgePalette.length];

/// The coloured square with an app's first letter, as on the Apps tab.
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.package,
    required this.name,
    this.size = 32,
  });

  final String package;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colour = appColourOf(package);
    // The letter is drawn large and bold, so 3:1 is the bar it has to meet.
    final white = _contrast(colour, Colors.white) >= 3;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(size >= 40 ? 10 : 9),
        ),
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: TextStyle(
            fontSize: size * 0.6,
            fontWeight: FontWeight.w800,
            color: white ? Colors.white : const Color(0xFF14171C),
          ),
        ),
      ),
    );
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final (hi, lo) = la > lb ? (la, lb) : (lb, la);
    return (hi + 0.05) / (lo + 0.05);
  }
}

/// A key of the remote and of the app sheet: a rounded card with a label,
/// an icon, or both, 48 dp tall. A long press is its own action.
class TvKeyButton extends StatelessWidget {
  const TvKeyButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.onLongPress,
    this.showLabel = true,
    this.text,
    this.background = OmniColors.card,
    this.foreground = OmniColors.text,
    this.height = OmniSpace.target,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// False draws the icon alone; the label is still read out.
  final bool showLabel;

  /// A shorter word drawn instead of [label] ("Vol −"), which is still
  /// what is read out.
  final String? text;
  final Color background;
  final Color foreground;
  final double height;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(OmniRadii.button);
    final enabled = onTap != null;
    final fg = enabled ? foreground : OmniColors.muted;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Material(
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: const BorderSide(color: OmniColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: SizedBox(
              height: height,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) Icon(icon, size: 20, color: fg),
                        if (icon != null && showLabel) const SizedBox(width: 6),
                        if (showLabel || icon == null)
                          Text(
                            text ?? label,
                            style: TextStyle(
                              fontSize: 13,
                              color: fg,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A grid of [TvKeyButton]s, [columns] across with the mockups' 8 dp gaps.
class TvKeyGrid extends StatelessWidget {
  const TvKeyGrid({super.key, required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <List<Widget>>[];
    for (var i = 0; i < children.length; i += columns) {
      rows.add(children.sublist(i, (i + columns).clamp(0, children.length)));
    }
    return Column(
      children: [
        for (final (r, row) in rows.indexed) ...[
          if (r > 0) const SizedBox(height: OmniSpace.sm),
          Row(
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: OmniSpace.sm),
                Expanded(child: c < row.length ? row[c] : const SizedBox()),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// The running transfer as a card with its progress, hidden when nothing
/// runs. [onCancel] stops a batch after the file in flight.
class TransferProgress extends StatelessWidget {
  const TransferProgress({super.key, required this.tv, this.onCancel});

  final TvController tv;
  final VoidCallback? onCancel;

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
      final what = [progressLabel(p.op), ?tv.progressName].join(' ');
      return OmniCard(
        key: const ValueKey('tv-progress'),
        title: what,
        trailing: fraction == null
            ? null
            : Text('${(fraction * 100).round()}%', style: OmniText.caption),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: OmniSpace.xs),
            OmniProgressBar(value: fraction, semanticLabel: what),
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.done <= 0
                        ? 'Starting'
                        : total == null
                        ? formatBytes(p.done)
                        : '${formatBytes(p.done)} of ${formatBytes(total)}',
                    key: const ValueKey('tv-progress-text'),
                    style: OmniText.caption,
                  ),
                ),
                if (onCancel != null)
                  TextButton(
                    key: const ValueKey('tv-progress-cancel'),
                    onPressed: onCancel,
                    child: const Text('Stop after this file'),
                  ),
              ],
            ),
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

/// A list that failed to load: what happened, and Try again.
class TvLoadError extends StatelessWidget {
  const TvLoadError({
    super.key,
    required this.what,
    required this.reason,
    this.onRetry,
  });

  /// "The apps", "The settings": what could not be read.
  final String what;
  final String reason;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: OmniSpace.md),
    child: OmniBanner.error(
      '$what could not be read from the TV: $reason',
      actionLabel: onRetry == null ? null : 'Try again',
      onAction: onRetry,
    ),
  );
}

/// A centred spinner while a list loads.
class TvLoading extends StatelessWidget {
  const TvLoading({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: OmniSpace.xl),
    child: Center(
      child: Semantics(
        label: label,
        child: const SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
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

/// Icons of the TV control centre that the design system does not name.
abstract final class TvIcons {
  static const mic = Symbols.mic_rounded;
  static const back = Symbols.arrow_back_rounded;
  static const menu = Symbols.menu_rounded;
  static const info = Symbols.info_rounded;
  static const volumeUp = Symbols.volume_up_rounded;
  static const volumeDown = Symbols.volume_down_rounded;
  static const volumeOff = Symbols.volume_off_rounded;
  static const previous = Symbols.skip_previous_rounded;
  static const playPause = Symbols.play_pause_rounded;
  static const next = Symbols.skip_next_rounded;
  static const rewind = Symbols.fast_rewind_rounded;
  static const stop = Symbols.stop_rounded;
  static const forward = Symbols.fast_forward_rounded;
  static const up = Symbols.keyboard_arrow_up_rounded;
  static const down = Symbols.keyboard_arrow_down_rounded;
  static const left = Symbols.keyboard_arrow_left_rounded;
  static const right = Symbols.keyboard_arrow_right_rounded;
  static const backspace = Symbols.backspace_rounded;
  static const enter = Symbols.keyboard_return_rounded;
  static const input = Symbols.input_rounded;
  static const guide = Symbols.calendar_view_week_rounded;
  static const captions = Symbols.closed_caption_rounded;
  static const sleep = Symbols.bedtime_rounded;
  static const wake = Symbols.wb_sunny_rounded;
  static const lastChannel = Symbols.history_rounded;
  static const recents = Symbols.view_carousel_rounded;
  static const send = Symbols.send_rounded;
  static const folder = Symbols.folder_rounded;
  static const video = Symbols.movie_rounded;
  static const image = Symbols.image_rounded;
  static const apk = Symbols.android_rounded;
  static const audio = Symbols.audio_file_rounded;
  static const archive = Symbols.folder_zip_rounded;
  static const text = Symbols.description_rounded;
  static const file = Symbols.draft_rounded;
  static const link = Symbols.link_rounded;
  static const copy = Symbols.content_copy_rounded;
  static const cut = Symbols.content_cut_rounded;
  static const download = Symbols.download_rounded;
  static const upload = Symbols.upload_rounded;
  static const rename = Symbols.drive_file_rename_outline_rounded;
  static const newFolder = Symbols.create_new_folder_rounded;
  static const paste = Symbols.content_paste_rounded;
  static const checked = Symbols.check_box_rounded;
  static const unchecked = Symbols.check_box_outline_blank_rounded;
  static const open = Symbols.play_arrow_rounded;
  static const forceStop = Symbols.stop_circle_rounded;
  static const cache = Symbols.cleaning_services_rounded;
  static const data = Symbols.delete_sweep_rounded;
  static const disable = Symbols.block_rounded;
  static const enable = Symbols.check_circle_rounded;
  static const history = Symbols.history_rounded;
  static const run = Symbols.play_arrow_rounded;
  static const clear = Symbols.clear_all_rounded;
}
