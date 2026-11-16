import 'dart:async';

import 'type_it_page.dart' show openTypeIt;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/rule_calls.dart';
import '../../state/clock.dart' show hour12Provider;
import '../../state/hub_mode.dart' show hubLinkProvider;
import '../../state/providers.dart';
import '../settings/settings_screen.dart' show engineStatusProvider;
import '../design/automation_look.dart';
import '../design/design.dart';
import 'automation_insights.dart' show AutomationConflictChip;
import 'automation_page.dart';
import 'automations_state.dart';
import 'dialogs.dart';
import '../help/screen_help.dart';
import 'new_automation.dart';
import 'next_run_line.dart';
import 'removed_page.dart' show openRecentlyRemoved;
import 'review_page.dart';
import 'scenes.dart' show SceneRow, automationIconFor, openSceneEditor;
import 'suggestions_page.dart';
import 'test_run.dart';

enum AutomationFilter { all, rules, links, scenes, off, needsYou }

/// 2.1: every rule and link, written as its sentence, with its switch and
/// how its last run went. Agent-made ones waiting for review are flagged
/// at the top.
class AutomationsScreen extends ConsumerStatefulWidget {
  const AutomationsScreen({super.key});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  var _filter = AutomationFilter.all;
  var _searching = false;
  var _query = '';

  /// Rows swiped away to be removed, hidden until Undo brings them back.
  final _removing = <String>{};

  /// Of [_removing], the ones the list no longer has. One that comes back
  /// (Restore on Recently removed) shows again.
  final _gone = <String>{};

  /// Keeps [_removing] in step with the list: a swiped id leaves it once
  /// the list has dropped it and then has it again.
  void _track(List<AutomationSummary> all) {
    if (_removing.isEmpty) return;
    final ids = {for (final a in all) a.id};
    final back = {
      for (final id in _gone)
        if (ids.contains(id)) id,
    };
    _gone
      ..addAll(_removing.where((id) => !ids.contains(id)))
      ..removeAll(back);
    if (back.isNotEmpty) setState(() => _removing.removeAll(back));
  }

  /// Whether [a] belongs under the filter [f], before any search.
  static bool _inFilter(AutomationSummary a, AutomationFilter f) => switch (f) {
    AutomationFilter.all => true,
    AutomationFilter.rules => a.source == 'rule' || a.source == 'graph',
    AutomationFilter.links => a.isLink,
    AutomationFilter.scenes => false,
    AutomationFilter.off => !a.enabled || a.needsApproval,
    AutomationFilter.needsYou => a.needsYou,
  };

  bool _shows(AutomationSummary a) {
    final q = _query.trim().toLowerCase();
    return _inFilter(a, _filter) &&
        (q.isEmpty ||
            a.name.toLowerCase().contains(q) ||
            a.sentence.any((p) => p.text.toLowerCase().contains(q)));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(automationsProvider, (_, next) {
      if (next.value case final all?) _track(all);
    });
    final async = ref.watch(automationsProvider);
    final all = async.value ?? const <AutomationSummary>[];
    final list = [
      for (final a in all)
        if (!a.isScene) a,
    ];
    final scenes = [
      for (final a in all)
        if (a.isScene) a,
    ];
    final error = async.error;
    return TabPage.custom(
      title: 'Automations',
      subtitle: automationsStopped(ref)
          ? 'Stopped. Start them from the banner above.'
          : 'Each runs on the phone, even with the screen off.',
      actions: [
        OmniIconAction(
          key: const ValueKey('automations-search'),
          icon: _searching ? OmniIcons.close : OmniIcons.search,
          label: _searching ? 'Close search' : 'Search automations',
          onPressed: () => setState(() {
            _searching = !_searching;
            if (!_searching) _query = '';
          }),
        ),
        const ScreenHelpButton(HelpScreen.automations),
      ],
      filters: all.isEmpty ? null : _filters(list, scenes),
      state: OmniLoad.of(
        async,
        isEmpty: (v) => v.isEmpty,
        onRetry: () => ref.read(automationsProvider.notifier).retry(),
        error:
            error is AutomationsUnavailable &&
                error.failure.type != 'unreachable'
            ? 'The automations did not load: ${error.failure.message}'
            : 'OmniFlow did not answer, so the automations cannot show. It '
                  'may still be starting. Try again in a moment.',
      ),
      empty: OmniEmptyState(
        key: const ValueKey('automations-empty'),
        icon: OmniIcons.automations,
        title: 'No automations yet',
        message:
            'Make one from a template, like arrive home or bedtime, or link a '
            'button to a light.',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OmniButton(
              label: 'New automation',
              icon: OmniIcons.add,
              expand: false,
              onPressed: () => openNewAutomation(context),
            ),
            const SizedBox(height: OmniSpace.sm),
            OmniButton(
              key: const ValueKey('automations-empty-type-it'),
              label: 'Type what you want',
              kind: OmniButtonKind.ghost,
              expand: false,
              onPressed: () => openTypeIt(context),
            ),
          ],
        ),
      ),
      body: (context, padding) => _list(list, scenes, padding),
    );
  }

  /// The search field (while searching) and the filter chips, pinned
  /// above the list.
  Widget _filters(
    List<AutomationSummary> list,
    List<AutomationSummary> scenes,
  ) {
    final needsYou = list.where((a) => a.needsYou).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_searching)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: TextField(
              key: const ValueKey('automations-query'),
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search names and what they do',
                prefixIcon: Icon(OmniIcons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in AutomationFilter.values) ...[
                OmniFilterChip(
                  key: ValueKey('filter-${f.name}'),
                  label: switch (f) {
                    AutomationFilter.all => 'All',
                    AutomationFilter.rules => 'Rules',
                    AutomationFilter.links => 'Quick links',
                    AutomationFilter.scenes => 'Scenes',
                    AutomationFilter.off => 'Off',
                    AutomationFilter.needsYou => 'Needs you',
                  },
                  // Each chip counts what it shows, and a zero shows none.
                  count: switch (f == AutomationFilter.scenes
                      ? scenes.length
                      : list.where((a) => _inFilter(a, f)).length) {
                    0 => null,
                    final n => n,
                  },
                  dot: f == AutomationFilter.needsYou && needsYou > 0
                      ? StatusKind.warning
                      : null,
                  selected: _filter == f,
                  onTap: () => setState(() => _filter = f),
                ),
                if (f != AutomationFilter.values.last)
                  const SizedBox(width: OmniSpace.sm),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _list(
    List<AutomationSummary> list,
    List<AutomationSummary> scenes,
    EdgeInsets padding,
  ) {
    final waiting = [
      for (final a in list)
        if (a.needsApproval) a,
    ];
    final shown = [
      for (final a in list)
        if (!_removing.contains(a.id) && _shows(a)) a,
    ];
    final query = _query.trim().toLowerCase();
    final shownScenes = [
      for (final s in scenes)
        if (query.isEmpty || s.name.toLowerCase().contains(query)) s,
    ];
    return RefreshIndicator(
      onRefresh: () => ref.read(automationsProvider.notifier).refresh(),
      child: ListView(
        key: const ValueKey('automations-list'),
        padding: padding,
        children: [
          if (_filter == AutomationFilter.all && !_searching)
            const AutomationHelpers(),
          if (waiting.length == 1)
            OmniBanner.warning(
              'An agent made "${waiting.single.name}". Review before it can run.',
              key: const ValueKey('needs-review'),
              actionLabel: 'Review',
              onAction: () => _push(ReviewPage(id: waiting.single.id)),
            )
          else if (waiting.length > 1)
            OmniBanner.warning(
              'An agent made ${waiting.length} automations. Review them before '
              'they can run.',
              key: const ValueKey('needs-review'),
              actionLabel: 'Show them',
              onAction: () =>
                  setState(() => _filter = AutomationFilter.needsYou),
            ),
          if (_filter == AutomationFilter.scenes) ...[
            if (scenes.isEmpty)
              const OmniEmptyState(
                key: ValueKey('scenes-empty'),
                icon: OmniIcons.scene,
                title: 'No scenes yet',
                message:
                    'A scene sets several things at once, like Movie: lamp '
                    '20%, TV on.',
                compact: true,
              )
            else if (shownScenes.isEmpty)
              OmniEmptyState(
                key: const ValueKey('filter-empty'),
                icon: OmniIcons.search,
                title: 'Nothing matches "$_query"',
                compact: true,
              ),
            for (final s in shownScenes) SceneRow(scene: s),
            Align(
              alignment: Alignment.centerLeft,
              child: OmniButton.ghost(
                key: const ValueKey('scene-new'),
                label: 'New scene',
                icon: OmniIcons.add,
                expand: false,
                onPressed: () => openSceneEditor(context),
              ),
            ),
          ] else if (shown.isEmpty)
            OmniEmptyState(
              key: const ValueKey('filter-empty'),
              icon: OmniIcons.search,
              title: _query.isNotEmpty
                  ? 'Nothing matches "$_query".'
                  : switch (_filter) {
                      AutomationFilter.off => 'Every automation is on.',
                      AutomationFilter.needsYou =>
                        'Nothing needs you. Every automation is approved '
                            'and its last run worked.',
                      AutomationFilter.links => 'No quick links yet.',
                      _ => 'No rules yet.',
                    },
              compact: true,
            ),
          for (final a in shown)
            _swipeable(
              a,
              AutomationCard(
                automation: a,
                onOpen: () => _push(AutomationPage(id: a.id, summary: a)),
              ),
            ),
          if (_filter == AutomationFilter.all && !_searching)
            OmniListRow(
              key: const ValueKey('automations-removed'),
              icon: OmniIcons.delete,
              title: 'Recently removed',
              subtitle: 'Put back an automation you removed',
              chevron: true,
              onTap: () => openRecentlyRemoved(context),
            ),
        ],
      ),
    );
  }

  Future<void> _push(Widget page) =>
      Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));

  /// [card] with its swipes: right turns it off or on, left removes it.
  /// Both offer Undo, and a screen reader gets the same two as actions.
  Widget _swipeable(AutomationSummary a, Widget card) {
    final on = a.enabled && !a.needsApproval;
    final toggle = on ? 'Turn off' : 'Turn on';
    return Semantics(
      customSemanticsActions: {
        if (!a.needsApproval)
          CustomSemanticsAction(label: toggle): () => _setEnabled(a, !on),
        const CustomSemanticsAction(label: 'Remove'): () => _remove(a),
      },
      child: Dismissible(
        key: ValueKey('swipe-${a.id}'),
        // Not loaded until approved, so there is nothing to turn on yet.
        direction: a.needsApproval
            ? DismissDirection.endToStart
            : DismissDirection.horizontal,
        background: _SwipeBackground(
          icon: OmniIcons.power,
          label: toggle,
          color: OmniPalette.of(context).accent,
          start: true,
        ),
        secondaryBackground: const _SwipeBackground(
          icon: OmniIcons.delete,
          label: 'Remove',
          color: OmniColors.bad,
          start: false,
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.startToEnd) {
            unawaited(_setEnabled(a, !on));
            return false;
          }
          return true;
        },
        onDismissed: (_) => _remove(a),
        child: card,
      ),
    );
  }

  Future<void> _setEnabled(
    AutomationSummary a,
    bool on, {
    bool undo = true,
  }) async {
    final api = ref.read(engineApiProvider);
    final automations = ref.read(automationsProvider.notifier);
    final reply = await api.enableAutomation(a.id, on);
    await automations.refresh();
    if (!reply.ok || !undo) return;
    showMessage(
      'Turned ${a.name} ${on ? 'on' : 'off'}',
      action: 'Undo',
      onAction: () => _setEnabled(a, !on, undo: false),
    );
  }

  /// Removes [a]. Undo asks the engine to put it back as it was, with its
  /// trust, its on or off and its versions.
  Future<void> _remove(AutomationSummary a) async {
    setState(() => _removing.add(a.id));
    final api = ref.read(engineApiProvider);
    final client = ref.read(engineClientProvider);
    final automations = ref.read(automationsProvider.notifier);
    final saved = await api.automation(a.id);
    final record = saved.value == null
        ? null
        : EngineCalls.automationOf(saved.value!);
    final removed = record == null ? null : await api.removeAutomation(a.id);
    if (record == null || !(removed?.ok ?? false)) {
      await _show(a.id);
      return;
    }
    await automations.refresh();
    showMessage(
      'Removed ${a.name}',
      action: 'Undo',
      onAction: () async {
        // The engine puts it back as it was, on or off, in one step.
        if (!await RuleCalls.restore(client, record)) {
          showMessage('${a.name} could not be put back');
        }
        await automations.refresh();
        await _show(a.id);
      },
    );
  }

  /// Shows a swiped row again. A dismissed row must leave the tree for a
  /// frame first, so it comes back as a new row.
  Future<void> _show(String id) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _gone.remove(id);
    setState(() => _removing.remove(id));
  }
}

/// What shows under a row as it is swiped: the action's icon and words.
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.icon,
    required this.label,
    required this.color,
    required this.start,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool start;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: OmniSpace.xs),
    padding: const EdgeInsets.symmetric(horizontal: OmniSpace.lg),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(OmniRadii.card),
    ),
    alignment: start ? Alignment.centerLeft : Alignment.centerRight,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: OmniSpace.sm),
        Text(label, style: OmniText.bodyStrong.copyWith(color: color)),
      ],
    ),
  );
}

/// One automation: name and switch, its sentence, and its last run (or
/// why it failed, with Retry).
class AutomationCard extends ConsumerStatefulWidget {
  const AutomationCard({super.key, required this.automation, this.onOpen});

  final AutomationSummary automation;
  final VoidCallback? onOpen;

  @override
  ConsumerState<AutomationCard> createState() => _AutomationCardState();
}

class _AutomationCardState extends ConsumerState<AutomationCard> {
  bool? _enabled;
  var _retrying = false;

  AutomationSummary get _a => widget.automation;

  @override
  void didUpdateWidget(AutomationCard old) {
    super.didUpdateWidget(old);
    if (old.automation.enabled != _a.enabled) _enabled = null;
  }

  Future<void> _enable(bool on) async {
    setState(() => _enabled = on);
    final reply = await ref.read(engineApiProvider).enableAutomation(_a.id, on);
    if (!mounted) return;
    if (!reply.ok) setState(() => _enabled = null);
    await ref.read(automationsProvider.notifier).refresh();
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    final reply = await ref.read(engineApiProvider).runAutomation(_a.id);
    if (!mounted) return;
    setState(() => _retrying = false);
    final run = reply.value?.firstOrNull;
    if (run != null) {
      final failed = run.steps.where((n) => n.error != null).firstOrNull;
      showMessage(
        run.ok
            ? '${_a.name} ran: ${stepsOf(run)} steps'
            : '${_a.name} failed again${failed?.error == null ? '' : ': ${failed!.error}'}',
      );
    }
    await ref.read(automationsProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final enabled = _enabled ?? a.enabled;
    final last = a.lastRun;
    final failedLast = last != null && !last.ok;
    return OmniCard(
      key: ValueKey('automation-${a.id}'),
      onTap: widget.onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AutomationBadge(
                key: ValueKey('badge-${a.id}'),
                icon: automationIconFor(a),
                color: a.color,
              ),
              const SizedBox(width: OmniSpace.gap),
              Expanded(child: Text(a.name, style: OmniText.bodyStrong)),
              ExcludeSemantics(
                child: Text(
                  enabled && !a.needsApproval ? 'On' : 'Off',
                  key: ValueKey('enable-label-${a.id}'),
                  style: OmniText.caption,
                ),
              ),
              const SizedBox(width: OmniSpace.sm),
              Semantics(
                label: enabled && !a.needsApproval
                    ? 'Turn ${a.name} off'
                    : 'Turn ${a.name} on',
                child: Switch(
                  key: ValueKey('enable-${a.id}'),
                  // Not loaded until approved, so it shows off whatever it
                  // says.
                  value: enabled && !a.needsApproval,
                  onChanged: a.needsApproval ? null : _enable,
                ),
              ),
            ],
          ),
          const SizedBox(height: OmniSpace.xs),
          if (a.sentence.isNotEmpty) AutomationSentence(a.sentence),
          if (a.askFirst || a.notifyOnRun)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.xs),
              child: Wrap(
                spacing: OmniSpace.sm,
                runSpacing: OmniSpace.xs,
                children: [
                  if (a.askFirst)
                    BehaviourBadge(
                      key: ValueKey('asks-first-${a.id}'),
                      icon: AutomationLook.askIcon,
                      label: 'Asks first',
                    ),
                  if (a.notifyOnRun)
                    BehaviourBadge(
                      key: ValueKey('tells-you-${a.id}'),
                      icon: OmniIcons.notifications,
                      label: 'Tells you when it runs',
                    ),
                ],
              ),
            ),
          // Sets a device the other way from another automation.
          AutomationConflictChip(id: a.id, conflicts: a.conflicts),
          if (a.needsApproval)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.xs),
              child: Text(
                'Waiting for your review',
                style: OmniText.caption.copyWith(color: OmniColors.warn),
              ),
            )
          else if (failedLast)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Last run failed${last.error == null ? '' : ': ${last.error}'}',
                    key: ValueKey('last-failed-${a.id}'),
                    style: OmniText.caption.copyWith(color: OmniColors.bad),
                  ),
                ),
                TextButton(
                  key: ValueKey('retry-${a.id}'),
                  onPressed: _retrying ? null : _retry,
                  style: TextButton.styleFrom(
                    foregroundColor: OmniColors.bad,
                    minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                    textStyle: OmniText.labelMedium,
                  ),
                  child: const Text('Retry'),
                ),
              ],
            )
          else if (last != null)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.xs),
              child: Text(
                [
                  if (a.isLink) 'Link',
                  'Ran ${whenInline(last.at, hour12: ref.watch(hour12Provider))}',
                  '${last.steps} ${last.steps == 1 ? 'step' : 'steps'}',
                ].join(' · '),
                key: ValueKey('last-run-${a.id}'),
                style: OmniText.caption,
              ),
            )
          else if (a.isLink)
            const Padding(
              padding: EdgeInsets.only(top: OmniSpace.xs),
              child: Text('Link', style: OmniText.caption),
            ),
          // No next run while this phone's automations are stopped.
          NextRunLine(a, enabled: enabled && !automationsStopped(ref)),
        ],
      ),
    );
  }
}

/// Whether this phone runs its own home and its hub is off, so no
/// automation runs on its own (the shell's banner says so, with Start).
bool automationsStopped(WidgetRef ref) =>
    ref.watch(hubLinkProvider) == null &&
    ref.watch(engineStatusProvider).value?['hubRunning'] == false;

/// Whether the list has nothing at all, no rule and no scene, so its own
/// empty state carries the New button and the floating one would be a
/// second. With scenes and no rules the list shows, so the FAB must too.
bool automationsAreEmpty(WidgetRef ref) =>
    switch (ref.watch(automationsProvider)) {
      AsyncData(:final value) => value.isEmpty,
      _ => false,
    };
