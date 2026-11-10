import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'rule_words.dart';

/// 2.5: an automation an agent made, waiting for the user. It shows what it
/// does and what it can and cannot touch, then Reject (deletes it) or
/// Approve (approves exactly the revision shown).
class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  Json? _automation;
  ApiFailure? _failure;
  String? _notice;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failure = null);
    final api = ref.read(engineApiProvider);
    final got = await api.automation(widget.id);
    await ref.read(automationsProvider.notifier).refresh();
    if (!mounted) return;
    setState(() {
      _automation = got.value;
      _failure = got.failure;
    });
  }

  String get _name => '${_automation?['name'] ?? widget.id}';

  AutomationSummary? _summary(List<AutomationSummary> list) =>
      list.where((a) => a.id == widget.id).firstOrNull;

  String _automationName(String id) =>
      (ref.read(automationsProvider).value ?? const <AutomationSummary>[])
          .where((a) => a.id == id)
          .firstOrNull
          ?.name ??
      id;

  Future<void> _approve() async {
    final revision = _automation?['revision'];
    if (revision is! String) return;
    setState(() => _busy = true);
    final api = ref.read(engineApiProvider);
    final reply = await api.approveAutomation(widget.id, revision);
    if (!mounted) return;
    setState(() => _busy = false);
    if (reply.failure case final f?) {
      if (f.type == 'conflict') {
        setState(() {
          _notice =
              'It changed since you opened it. Read it again before you '
              'approve it.';
        });
        await _load();
      }
      return;
    }
    await ref.read(automationsProvider.notifier).refresh();
    showMessage('Approved $_name. It runs on its own now.');
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _reject() async {
    final ok = await confirm(
      context,
      title: 'Reject $_name?',
      body:
          'It is deleted and never runs. Claude can make it again if you '
          'ask it to.',
      action: 'Reject',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final reply = await ref.read(engineApiProvider).removeAutomation(widget.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!reply.ok) return;
    await ref.read(automationsProvider.notifier).refresh();
    showMessage('Rejected $_name');
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final automation = _automation;
    final summary = _summary(ref.watch(automationsProvider).value ?? const []);
    final words = RuleWords(ref.watch(ruleThingsProvider));
    final approved = automation?['approved'] == true;
    return OmniPage(
      title: 'Review "$_name"',
      body: switch ((automation, _failure)) {
        (_, final ApiFailure f) => OmniEmptyState(
          key: const ValueKey('review-error'),
          icon: OmniIcons.error,
          title: f.type == 'not_found'
              ? 'This automation is gone'
              : 'Could not open it',
          message: f.type == 'not_found'
              ? 'It was removed, or it was never saved.'
              : f.message,
          action: f.type == 'not_found'
              ? null
              : OmniButton.ghost(label: 'Try again', onPressed: _load),
        ),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final Json a, _) => ListView(
          children: [
            if (_notice != null) OmniBanner.warning(_notice!),
            if (approved)
              const OmniBanner.info(
                'Already approved. It runs on its own.',
                key: ValueKey('review-approved'),
              )
            else
              const OmniBanner.warning(
                'Made by Claude. It runs only after you approve this exact '
                'version.',
              ),
            if (summary != null && summary.sentence.isNotEmpty)
              OmniCard(child: AutomationSentence(summary.sentence)),
            const OmniSectionHeader('What it can do'),
            ..._can(a, summary, words),
            const OmniSectionHeader('It cannot'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                a['highRisk'] == true
                    ? 'control any device not listed above'
                    : 'run shell commands, install apps or change settings, '
                          'or control any device not listed above',
                key: const ValueKey('review-cannot'),
                style: OmniText.caption,
              ),
            ),
            const SizedBox(height: OmniSpace.xl),
          ],
        ),
      },
      bottom: automation == null || approved
          ? null
          : Row(
              children: [
                Expanded(
                  child: OmniButton.danger(
                    key: const ValueKey('review-reject'),
                    label: 'Reject',
                    onPressed: _busy ? null : _reject,
                  ),
                ),
                const SizedBox(width: OmniSpace.sm),
                Expanded(
                  child: OmniButton(
                    key: const ValueKey('review-approve'),
                    label: 'Approve',
                    onPressed: _busy ? null : _approve,
                  ),
                ),
              ],
            ),
    );
  }

  /// The devices it drives and reads, the commands it runs on a computer
  /// or TV, the automations it starts and whether it notifies, taken from
  /// the stored flow rather than from labels its author chose.
  List<Widget> _can(Json a, AutomationSummary? summary, RuleWords words) {
    final nodes = [
      for (final n in ((a['flow'] as Map?)?['nodes'] as List? ?? const []))
        if (n is Map) n,
    ];
    final controls = {
      ...?summary?.controls,
      for (final n in nodes)
        if (n['type'] == 'device_capability' || n['type'] == 'device_toggle')
          '${(n['config'] as Map?)?['deviceId']}',
    };
    final reads = {...?summary?.devices}.difference(controls);
    final risky = <String>{
      for (final n in nodes)
        if (n['type'] == 'device_capability')
          if ((n['config'] as Map?) case final Map c)
            if (words
                    .thing('${c['deviceId']}')
                    ?.capability('${c['capabilityId']}')
                case final cap? when isHighRisk(cap))
              '${c['deviceId']}',
    };
    final runs = {
      for (final n in nodes)
        if (n['type'] == 'run_flow') '${(n['config'] as Map?)?['flowId']}',
    };
    final notifies = nodes.any(
      (n) => n['type'] == 'notify' || n['type'] == 'speak',
    );
    String names(Iterable<String> ids) =>
        andList([for (final id in ids) words.thing(id)?.name ?? id]);
    IconData iconOf(Iterable<String> ids) =>
        words.thing(ids.first)?.icon ?? OmniIcons.device;
    final rows = <Widget>[
      if (controls.isNotEmpty)
        OmniListRow(
          key: const ValueKey('can-control'),
          icon: iconOf(controls),
          title: 'Control ${names(controls)}',
        ),
      if (reads.isNotEmpty)
        OmniListRow(
          key: const ValueKey('can-read'),
          icon: iconOf(reads),
          title: reads.length == 1
              ? 'Read ${names(reads)}\'s state'
              : 'Read the state of ${names(reads)}',
        ),
      if (risky.isNotEmpty)
        OmniListRow(
          key: const ValueKey('can-commands'),
          icon: OmniIcons.warning,
          iconForeground: OmniColors.warn,
          title: 'Run commands on ${names(risky)}',
          subtitle: 'High risk: it can do anything a command there can',
          subtitleLines: 2,
        ),
      if (runs.isNotEmpty)
        OmniListRow(
          icon: OmniIcons.automations,
          title: 'Run ${andList([for (final r in runs) _automationName(r)])}',
        ),
      if (notifies)
        const OmniListRow(icon: OmniIcons.notifications, title: 'Notify you'),
    ];
    return rows.isEmpty
        ? [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                'Nothing: it drives no device and runs nothing.',
                style: OmniText.caption,
              ),
            ),
          ]
        : rows;
  }
}
