import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../rules/rule_spec.dart' show OnMode, OnTrigger;
import '../../state/providers.dart';
import '../automations/rule_editor.dart' show openRuleEditor;
import '../design/design.dart';
import '../shell/shell.dart';
import '../tv/tv_widgets.dart' show askText;
import 'write_tag_sheet.dart';

/// Whether [device] is an NFC tag thing, which gets the tag page.
bool isTagDevice(Json device) => device['driver'] == 'nfc_tag';

/// How long ago [t] was, the way the tag page says it: "just now", "5 min
/// ago", "2 h ago", "yesterday", "3 Nov".
String agoText(DateTime t, {DateTime? now}) {
  final at = t.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final d = today.difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  // A few hours back reads in hours even across midnight: at 1 am,
  // "2 h ago" says more than "yesterday".
  if (d.inHours < 6 || (d.inHours < 24 && at.day == today.day)) {
    return '${d.inHours} h ago';
  }
  if (!at.isBefore(DateTime(today.year, today.month, today.day - 1))) {
    return 'yesterday';
  }
  return _day(at);
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

String _day(DateTime t) => '${t.day} ${_months[t.month - 1]}';

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "Today 17:40", "Yesterday 09:12", "3 Nov 08:00".
String whenText(DateTime t, {DateTime? now}) {
  final at = t.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final midnight = DateTime(today.year, today.month, today.day);
  final day = !at.isBefore(midnight)
      ? 'Today'
      : !at.isBefore(DateTime(today.year, today.month, today.day - 1))
      ? 'Yesterday'
      : _day(at);
  return '$day ${_clock(at)}';
}

/// "04:A1:B2:C3" for the UID the engine keeps as hex.
String uidText(String uid) =>
    [for (var i = 0; i + 1 < uid.length; i += 2) uid.substring(i, i + 2)]
        .join(':');

/// 5.3 NFC tag: when it was last scanned and by what, Write to a new tag,
/// the automations a scan runs with "Do something when scanned", and recent
/// scans from the tag's history.
class TagPage extends ConsumerStatefulWidget {
  const TagPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<TagPage> createState() => _TagPageState();
}

class _TagPageState extends ConsumerState<TagPage> {
  Reply<List<AutomationSummary>>? _uses;
  Reply<List<HistoryEntry>>? _scans;
  List<HistoryEntry> _sources = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final api = EngineApi(ref.read(engineClientProvider));
    final uses = await api.automations(tag: widget.id);
    final scans = await api.history(widget.id, key: 'last_scanned', limit: 10);
    final sources = await api.history(widget.id, key: 'last_source', limit: 10);
    if (!mounted) return;
    setState(() {
      _uses = uses;
      _scans = scans;
      _sources = sources.or(const []);
    });
  }

  Json? get _device => ref
      .watch(devicesProvider)
      .value
      ?.where((d) => d['id'] == widget.id)
      .firstOrNull;

  /// What read the tag: this phone, or a board's reader by its name.
  String _readerName(Object? source) {
    if (source == null) return '';
    if (source == 'phone') return 'this phone';
    final board = ref
        .read(devicesProvider)
        .value
        ?.where((d) => d['id'] == source)
        .firstOrNull;
    return '${board?['name'] ?? source} reader';
  }

  /// The reader of the scan at [at]. History keeps a key only when it
  /// changes, so the reader is the newest source set by then.
  String? _sourceAt(DateTime at) => _sources
      .where((s) => !s.at.isAfter(at.add(const Duration(seconds: 2))))
      .map((s) => _readerName(s.value))
      .firstOrNull;

  Future<void> _write(Json device) async {
    final wrote = await writeTag(context, ref, device);
    if (wrote) await ref.read(devicesProvider.notifier).refresh();
  }

  Future<void> _newAutomation(Json device) => openRuleEditor(
    context,
    spec: {
      'name': 'When ${device['name'] ?? widget.id} is scanned',
      'when': [
        OnTrigger(
          thing: widget.id,
          key: 'scanned',
          mode: OnMode.event,
        ).toJson(),
      ],
      'then': const <Object?>[],
    },
  ).then((_) => _load());

  Future<void> _more(Json device) async {
    final choice = await showOmniSheet<String>(
      context,
      builder: (context) => OmniSheet(
        title: '${device['name'] ?? widget.id}',
        children: [
          OmniListRow(
            key: const ValueKey('tag-rename'),
            icon: OmniIcons.edit,
            title: 'Rename',
            onTap: () => Navigator.of(context).pop('rename'),
          ),
          OmniListRow(
            key: const ValueKey('tag-forget-card'),
            icon: OmniIcons.retry,
            title: 'Use a different card',
            subtitle: 'The next card scanned with its link becomes this tag',
            onTap: () => Navigator.of(context).pop('forget'),
          ),
          OmniListRow(
            key: const ValueKey('tag-remove'),
            icon: OmniIcons.delete,
            iconForeground: OmniColors.bad,
            title: 'Remove this tag',
            onTap: () => Navigator.of(context).pop('remove'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        await _rename(device);
      case 'forget':
        await _forgetCard(device);
      case 'remove':
        await _remove(device);
    }
  }

  Future<void> _rename(Json device) async {
    final name = await askText(
      context,
      title: 'Rename ${device['name']}',
      label: 'Name',
      initial: '${device['name'] ?? ''}',
      action: 'Save',
      validate: (t) => t.trim().isEmpty ? 'Enter a name' : null,
    );
    if (name == null || !mounted) return;
    final devices = ref.read(devicesProvider.notifier);
    final reply = await ref
        .read(engineApiProvider)
        .saveTag(widget.id, name.trim());
    if (reply.ok) await devices.refresh();
  }

  Future<void> _forgetCard(Json device) async {
    final ok = await confirm(
      context,
      title: 'Use a different card?',
      body:
          'This card stops being ${device['name']}. The next card scanned '
          'with its OmniFlow link takes its place, so write the link on the '
          'new card first.',
      action: 'Forget this card',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final devices = ref.read(devicesProvider.notifier);
    final reply = await ref
        .read(engineApiProvider)
        .saveTag(widget.id, '${device['name']}', forgetCard: true);
    if (reply.ok) await devices.refresh();
  }

  Future<void> _remove(Json device) async {
    final uses = _uses?.value?.length ?? 0;
    final ok = await confirm(
      context,
      title: 'Remove ${device['name'] ?? widget.id}?',
      body: [
        'Scanning the card does nothing until it is added again.',
        if (uses > 0)
          '$uses ${uses == 1 ? 'automation stops' : 'automations stop'} '
              'working.',
      ].join(' '),
      action: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final devices = ref.read(devicesProvider.notifier);
    final navigator = Navigator.of(context);
    final reply = await ref.read(engineApiProvider).removeTag(widget.id);
    if (!reply.ok) return;
    await devices.refresh();
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    if (device == null) {
      return OmniPage(
        title: 'NFC tag',
        body: ref.watch(devicesProvider).isLoading
            ? const SizedBox.shrink()
            : const OmniEmptyState(
                icon: OmniIcons.tag,
                title: 'This tag is not here any more',
                message: 'It may have been removed.',
              ),
      );
    }
    final view = DeviceView(device);
    final last = DateTime.tryParse('${view.state['last_scanned']}');
    final uid = (device['settings'] as Map? ?? const {})['uid'] as String?;
    final by = _readerName(view.state['last_source']);
    return OmniPage(
      title: view.name,
      actions: [
        OmniIconAction(
          key: const ValueKey('tag-more'),
          icon: OmniIcons.more,
          label: 'More for this tag',
          onPressed: () => _more(device),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('tag-page'),
          padding: const EdgeInsets.only(bottom: OmniSpace.xl),
          children: [
            OmniHeroCard(
              key: const ValueKey('tag-hero'),
              icon: OmniIcons.tag,
              centered: true,
              tone: last == null ? HeroTone.plain : HeroTone.accent,
              title: last == null
                  ? 'Not scanned yet'
                  : 'Scanned ${agoText(last)}',
              subtitle: [
                if (by.isNotEmpty) 'by $by',
                if (uid != null)
                  'card ${uidText(uid)}'
                else
                  'no card yet: write one or scan it',
              ].join(' · '),
            ),
            OmniButton.ghost(
              key: const ValueKey('tag-write'),
              label: 'Write to a new tag',
              icon: OmniIcons.edit,
              onPressed: () => _write(device),
            ),
            const OmniSectionHeader('When scanned'),
            ..._usesList(),
            const SizedBox(height: OmniSpace.sm),
            OmniButton.ghost(
              key: const ValueKey('tag-new-automation'),
              label: 'Do something when scanned',
              icon: OmniIcons.add,
              onPressed: () => _newAutomation(device),
            ),
            const OmniSectionHeader('Recent scans'),
            ..._scansList(),
          ],
        ),
      ),
    );
  }

  List<Widget> _usesList() {
    final uses = _uses;
    if (uses == null) {
      return const [_Loading(label: 'Reading automations')];
    }
    if (!uses.ok) {
      return [
        OmniBanner.error(
          'Could not read which automations use it. ${uses.failure!.message}',
          actionLabel: 'Try again',
          onAction: _load,
        ),
      ];
    }
    final list = uses.value!;
    if (list.isEmpty) {
      return const [
        Text(
          'Nothing happens yet when it is scanned.',
          key: ValueKey('tag-no-automations'),
          style: OmniText.caption,
        ),
      ];
    }
    return [
      for (final a in list)
        OmniListRow(
          key: ValueKey('tag-automation-${a.id}'),
          icon: OmniIcons.automations,
          title: a.name,
          subtitle: _thenText(a),
          chevron: true,
          onTap: () =>
              ref.read(shellControllerProvider).open(AutomationLink(a.id)),
        ),
    ];
  }

  /// What the automation does, in its own sentence's words.
  static String _thenText(AutomationSummary a) {
    final then = [
      for (final p in a.sentence)
        if (p.kind == SentenceKind.then) p.text,
    ];
    if (then.isNotEmpty) return then.join(', then ');
    return a.sentence.map((p) => p.text).join(' ');
  }

  List<Widget> _scansList() {
    final scans = _scans;
    if (scans == null) return const [_Loading(label: 'Reading scans')];
    final list = scans.value ?? const <HistoryEntry>[];
    if (!scans.ok || list.isEmpty) {
      return [
        Text(
          scans.ok
              ? 'No scans yet. Hold the card to the phone to try it.'
              : 'Could not read the scans: ${scans.failure!.message}',
          key: const ValueKey('tag-no-scans'),
          style: OmniText.caption,
        ),
      ];
    }
    return [
      for (final (i, s) in list.indexed)
        OmniListRow(
          key: ValueKey('tag-scan-$i'),
          title: [
            whenText(DateTime.tryParse('${s.value}')?.toLocal() ?? s.at),
            ?_sourceAt(s.at),
          ].join(' · '),
        ),
    ];
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: OmniSpace.md),
    child: Semantics(label: label, child: const OmniProgressBar(height: 2)),
  );
}
