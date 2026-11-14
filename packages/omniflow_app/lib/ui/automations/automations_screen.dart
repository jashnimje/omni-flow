import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/rule_calls.dart';
import '../../state/providers.dart';
import '../design/automation_look.dart';
import '../design/design.dart';
import 'automation_page.dart';
import 'automations_state.dart';
import 'dialogs.dart';
import 'new_automation.dart';
import 'review_page.dart';
import 'scenes.dart' show SceneRow, automationIconFor, openSceneEditor;
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

  bool _shows(AutomationSummary a) {
    final ok = switch (_filter) {
      AutomationFilter.all => true,
      AutomationFilter.rules => a.source == 'rule' || a.source == 'graph',
      AutomationFilter.links => a.isLink,
      AutomationFilter.scenes => false,
      AutomationFilter.off => !a.enabled || a.needsApproval,
      AutomationFilter.needsYou => a.needsYou,
    };
    final q = _query.trim().toLowerCase();
    return ok &&
        (q.isEmpty ||
            a.name.toLowerCase().contains(q) ||
            a.sentence.any((p) => p.text.toLowerCase().contains(q)));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(automationsProvider);
    return OmniTabPage(
      title: 'Automations',
      subtitle: 'Each runs on the phone, even with the screen off.',
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
      ],
      body: switch (async) {
        AsyncData(:final value) => _list(value),
        AsyncError(:final error) => _offline(error),
        _ => const _Skeleton(),
      },
    );
  }

  Widget _offline(Object error) => ListView(
    key: const ValueKey('automations-offline'),
    children: [
      OmniBanner.error(
        error is AutomationsUnavailable && error.failure.type != 'unreachable'
            ? 'The automations did not load: ${error.failure.message}'
            : 'OmniFlow did not answer, so the automations cannot show. It '
                  'may still be starting. Try again in a moment.',
        actionLabel: 'Try again',
        onAction: () => ref.read(automationsProvider.notifier).retry(),
      ),
    ],
  );

  Widget _list(List<AutomationSummary> all) {
    final list = [
      for (final a in all)
        if (!a.isScene) a,
    ];
    final scenes = [
      for (final a in all)
        if (a.isScene) a,
    ];
    if (list.isEmpty && scenes.isEmpty) {
      return OmniEmptyState(
        key: const ValueKey('automations-empty'),
        icon: OmniIcons.automations,
        title: 'No automations yet',
        message:
            'Make one from a template, like arrive home or bedtime, or link a '
            'button to a light.',
        action: OmniButton(
          label: 'New automation',
          icon: OmniIcons.add,
          expand: false,
          onPressed: () => openNewAutomation(context),
        ),
      );
    }
    final waiting = [
      for (final a in list)
        if (a.needsApproval) a,
    ];
    final needsYou = list.where((a) => a.needsYou).length;
    final shown = [
      for (final a in list)
        if (!_removing.contains(a.id) && _shows(a)) a,
    ];
    return RefreshIndicator(
      onRefresh: () => ref.read(automationsProvider.notifier).refresh(),
      child: ListView(
        key: const ValueKey('automations-list'),
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
                    count: switch (f) {
                      AutomationFilter.all => list.length,
                      AutomationFilter.scenes when scenes.isNotEmpty =>
                        scenes.length,
                      AutomationFilter.needsYou when needsYou > 0 => needsYou,
                      _ => null,
                    },
                    dot: f == AutomationFilter.needsYou && needsYou > 0
                        ? StatusKind.warning
                        : null,
                    selected: _filter == f,
                    onTap: () => setState(() => _filter = f),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: OmniSpace.sm),
          if (waiting.length == 1)
            OmniBanner.warning(
              'Claude made "${waiting.single.name}". Review before it can run.',
              key: const ValueKey('needs-review'),
              actionLabel: 'Review',
              onAction: () => _push(ReviewPage(id: waiting.single.id)),
            )
          else if (waiting.length > 1)
            OmniBanner.warning(
              'Claude made ${waiting.length} automations. Review them before '
              'they can run.',
              key: const ValueKey('needs-review'),
              actionLabel: 'Show them',
              onAction: () =>
                  setState(() => _filter = AutomationFilter.needsYou),
            ),
          if (_filter == AutomationFilter.scenes) ...[
            if (scenes.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: OmniSpace.xl),
                child: Text(
                  'No scenes yet. A scene sets several things at once, '
                  'like Movie: lamp 20%, TV on.',
                  key: ValueKey('scenes-empty'),
                  textAlign: TextAlign.center,
                  style: OmniText.caption,
                ),
              ),
            for (final s in scenes)
              if (_query.isEmpty ||
                  s.name.toLowerCase().contains(_query.trim().toLowerCase()))
                SceneRow(scene: s),
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: OmniSpace.xl),
              child: Text(
                _query.isNotEmpty
                    ? 'Nothing matches "$_query".'
                    : switch (_filter) {
                        AutomationFilter.off => 'Every automation is on.',
                        AutomationFilter.needsYou =>
                          'Nothing needs you. Every automation is approved '
                              'and its last run worked.',
                        AutomationFilter.links => 'No quick links yet.',
                        _ => 'No rules yet.',
                      },
                key: const ValueKey('filter-empty'),
                textAlign: TextAlign.center,
                style: OmniText.caption,
              ),
            ),
          for (final a in shown)
            _swipeable(
              a,
              AutomationCard(
                automation: a,
                onOpen: () => _push(AutomationPage(id: a.id, summary: a)),
              ),
            ),
          // Clear of the New button.
          const SizedBox(height: 88),
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
          color: OmniColors.accent,
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

  /// Removes [a], keeping what it was so Undo can save it again as it was:
  /// the same id and spec, trusted only if it was approved, and off if it
  /// was off.
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
        if (await RuleCalls.restore(client, record)) {
          if (record['enabled'] == false) {
            await api.enableAutomation(a.id, false);
          }
        } else {
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
    if (mounted) setState(() => _removing.remove(id));
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
    margin: const EdgeInsets.symmetric(vertical: 4),
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
              const SizedBox(width: 6),
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
          const SizedBox(height: 6),
          if (a.sentence.isNotEmpty) AutomationSentence(a.sentence),
          if (a.askFirst || a.notifyOnRun)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
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
          if (a.needsApproval)
            Padding(
              padding: const EdgeInsets.only(top: 6),
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
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: const Text('Retry'),
                ),
              ],
            )
          else if (last != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                [
                  if (a.isLink) 'Link',
                  'Ran ${whenInline(last.at)}',
                  '${last.steps} ${last.steps == 1 ? 'step' : 'steps'}',
                ].join(' · '),
                key: ValueKey('last-run-${a.id}'),
                style: OmniText.caption,
              ),
            )
          else if (a.isLink)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Link', style: OmniText.caption),
            ),
        ],
      ),
    );
  }
}

/// Grey cards in the shape of the list while it loads.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading automations',
    child: ListView(
      key: const ValueKey('automations-loading'),
      children: [
        for (var i = 0; i < 3; i++)
          OmniCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final w in const [0.4, 0.9, 0.3])
                  FractionallySizedBox(
                    widthFactor: w,
                    child: Container(
                      height: 12,
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      decoration: BoxDecoration(
                        color: OmniColors.raised,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Whether the list has no automations yet, when its own empty state
/// carries the New button, so the floating one would be a second.
bool automationsAreEmpty(WidgetRef ref) =>
    switch (ref.watch(automationsProvider)) {
      AsyncData(:final value) => !value.any((a) => !a.isScene),
      _ => false,
    };
