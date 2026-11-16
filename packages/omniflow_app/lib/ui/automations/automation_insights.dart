import 'package:flutter/material.dart';

import '../../state/clock.dart' show hour12Provider;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart';
import '../../api/rules_core_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';
import 'dialogs.dart';
import 'rule_blocks.dart' show RuleDraft;
import 'test_run.dart' show TestRunPage;

/// Why [id] clashes with other automations, from the automation list the
/// engine sends with each row's clashes.
List<String> conflictsOf(WidgetRef ref, String id) =>
    (ref.watch(automationsProvider).value ?? const <AutomationSummary>[])
        .where((a) => a.id == id)
        .firstOrNull
        ?.conflicts ??
    const [];

/// A warning chip on an automation's card when it sets a device the other
/// way from another automation on the same trigger. Nothing otherwise.
class AutomationConflictChip extends StatelessWidget {
  const AutomationConflictChip({
    super.key,
    required this.id,
    required this.conflicts,
  });

  final String id;

  /// The reason of each clash.
  final List<String> conflicts;

  @override
  Widget build(BuildContext context) {
    if (conflicts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        label: 'Clashes with another automation: ${conflicts.first}',
        excludeSemantics: true,
        child: Container(
          key: ValueKey('conflict-$id'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: OmniColors.warnSoft,
            borderRadius: BorderRadius.circular(OmniRadii.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(OmniIcons.warning, size: 14, color: OmniColors.warn),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  conflicts.length == 1
                      ? 'Clashes with another automation'
                      : 'Clashes with ${conflicts.length} automations',
                  style: OmniText.caption.copyWith(color: OmniColors.warn),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bottom of an automation's page: why it clashes with another one,
/// the triggers that fired without a run and why, and its earlier versions
/// with Restore. [onRestored] reloads the page with the version restored.
class AutomationInsights extends ConsumerStatefulWidget {
  const AutomationInsights({super.key, required this.id, this.onRestored});

  final String id;
  final VoidCallback? onRestored;

  @override
  ConsumerState<AutomationInsights> createState() => _AutomationInsightsState();
}

class _AutomationInsightsState extends ConsumerState<AutomationInsights> {
  List<SkipRecord>? _skips;
  List<VersionRecord>? _versions;
  var _restoring = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(engineClientProvider);
    final args = RulesCoreCalls.idArgs(widget.id);
    final skips = await client.call(RulesCoreCalls.skips, args);
    final versions = await client.call(RulesCoreCalls.versions, args);
    if (!mounted) return;
    setState(() {
      _skips = skips['ok'] == true ? RulesCoreCalls.skipsOf(skips) : const [];
      _versions = versions['ok'] == true
          ? RulesCoreCalls.versionsOf(versions)
          : const [];
    });
  }

  Future<void> _restore(VersionRecord v) async {
    final ok = await confirm(
      context,
      title: 'Go back to this version?',
      body:
          'It replaces what the automation does now. What it does now is '
          'kept in the history, so you can come back to it.',
      action: 'Restore',
    );
    if (!ok || !mounted) return;
    setState(() => _restoring = true);
    final result = await callEngine(
      ref,
      RulesCoreCalls.restore,
      RulesCoreCalls.restoreArgs(widget.id, v.version),
    );
    if (!mounted) return;
    setState(() => _restoring = false);
    if (result['ok'] != true) return;
    showMessage(
      result['approved'] == false
          ? 'Restored. It runs once you approve it'
          : 'Restored the version from ${whenInline(v.at)}',
    );
    await ref.read(automationsProvider.notifier).refresh();
    await _load();
    widget.onRestored?.call();
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = conflictsOf(ref, widget.id);
    final skips = _skips;
    final versions = _versions;
    return Column(
      key: const ValueKey('automation-insights'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, reason) in conflicts.indexed)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpace.sm),
            child: OmniBanner.warning(
              'This clashes with another automation. $reason.',
              key: ValueKey('conflict-reason-$i'),
            ),
          ),
        const OmniSectionHeader('Why didn\'t it run?'),
        if (skips == null)
          const LinearProgressIndicator()
        else if (skips.isEmpty)
          const Text(
            'Nothing was stopped. Each time it was set off, it ran.',
            key: ValueKey('skips-none'),
            style: OmniText.caption,
          )
        else
          for (final (i, s) in skips.indexed)
            OmniListRow(
              key: ValueKey('skip-$i'),
              icon: Symbols.block_rounded,
              title: s.text,
              subtitle: whenText(s.at, hour12: ref.watch(hour12Provider)),
            ),
        const OmniSectionHeader('History'),
        if (versions == null)
          const LinearProgressIndicator()
        else if (versions.isEmpty)
          const Text(
            'No earlier versions yet. Each save keeps the one before, up '
            'to 10.',
            key: ValueKey('versions-none'),
            style: OmniText.caption,
          )
        else
          for (final v in versions)
            _VersionRow(
              version: v,
              onRestore: _restoring ? null : () => _restore(v),
            ),
      ],
    );
  }
}

/// "Try as if": a dry run of the rule on screen from its trigger [index],
/// with an event the engine makes up for that trigger, shown step by step.
/// Nothing is sent to any device.
class TryAsIfButton extends ConsumerStatefulWidget {
  const TryAsIfButton({super.key, required this.draft, required this.index});

  final RuleDraft draft;
  final int index;

  @override
  ConsumerState<TryAsIfButton> createState() => _TryAsIfButtonState();
}

class _TryAsIfButtonState extends ConsumerState<TryAsIfButton> {
  var _busy = false;

  Future<void> _try() async {
    final draft = widget.draft;
    setState(() => _busy = true);
    final result = await ref
        .read(engineClientProvider)
        .call(
          EngineCalls.automationDryRun,
          RulesCoreCalls.tryAsIfArgs(draft.spec.toJson(), widget.index),
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result['ok'] != true) {
      draft.fail(ApiFailure.of(result));
      return;
    }
    final run = [
      for (final j in EngineCalls.dryRuns(result)) RunRecord.fromJson(j),
    ].firstOrNull;
    final name = draft.spec.name.trim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TestRunPage(
          name: name.isEmpty ? 'New automation' : name,
          dryRun: run,
          rule: draft.spec.toJson(),
          unsaved: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerEnd,
    child: TextButton.icon(
      key: ValueKey('try-as-if-${widget.index}'),
      onPressed: _busy ? null : _try,
      icon: const Icon(OmniIcons.test, size: 18),
      label: const Text('Try as if this happens'),
      style: TextButton.styleFrom(
        minimumSize: const Size(OmniSpace.target, OmniSpace.target),
      ),
    ),
  );
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.version, required this.onRestore});

  final VersionRecord version;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) => Padding(
    key: ValueKey('version-${version.version}'),
    padding: const EdgeInsets.only(bottom: OmniSpace.sm),
    child: OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Saved until ${whenInline(version.at)}'
                  '${version.byYou ? '' : ', made by an agent'}',
                  style: OmniText.bodyStrong,
                ),
              ),
              TextButton(
                key: ValueKey('restore-${version.version}'),
                onPressed: onRestore,
                style: TextButton.styleFrom(
                  minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                ),
                child: Semantics(
                  label:
                      'Restore the version saved until '
                      '${whenInline(version.at)}',
                  excludeSemantics: true,
                  child: const Text('Restore'),
                ),
              ),
            ],
          ),
          if (version.sentence.isNotEmpty)
            AutomationSentence(version.sentence)
          else
            Text(version.name, style: OmniText.caption),
        ],
      ),
    ),
  );
}
