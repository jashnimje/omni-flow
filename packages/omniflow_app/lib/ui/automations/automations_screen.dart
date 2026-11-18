import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/rule_calls.dart';
import '../../state/hub_mode.dart' show hubLinkProvider;
import '../../state/providers.dart';
import '../design/design.dart';
import '../help/screen_help.dart';
import '../home/suggestion_card.dart' show suggestionsProvider;
import '../settings/settings_screen.dart' show engineStatusProvider;
import 'automation_insights.dart' show AutomationConflictChip;
import 'automation_page.dart';
import 'automations_state.dart';
import 'card_look.dart';
import 'new_automation.dart';
import 'next_run_line.dart';
import 'removed_page.dart' show openRecentlyRemoved;
import 'review_page.dart';
import 'scenes.dart' show automationIconFor, openSceneEditor, runScene;
import 'suggestions_page.dart';
import 'test_run.dart';
import 'type_it_page.dart' show openTypeIt;

/// The three views of the list. The ones off, the quick links and the
/// ones that need you are found by searching for those words.
enum AutomationFilter { all, rules, scenes }

/// 2.1: every rule, link and scene as a bold colour card in a two-column
/// grid. Agent-made ones waiting for review
/// are flagged at the top. Ideas and Recently removed wait in collapsed
/// sections at the end.
class AutomationsScreen extends ConsumerStatefulWidget {
  const AutomationsScreen({super.key});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  var _filter = AutomationFilter.all;
  var _searching = false;
  final _query = TextEditingController();

  /// Rows swiped away to be removed, hidden until Undo brings them back.
  final _removing = <String>{};

  /// Of [_removing], the ones the list no longer has. One that comes back
  /// (Restore on Recently removed) shows again.
  final _gone = <String>{};

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

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
    AutomationFilter.rules => !a.isScene,
    AutomationFilter.scenes => a.isScene,
  };

  /// Whether [a] matches the search [q]: its name, its sentence, or one of
  /// the words that used to be filters ("off", "link", "needs you").
  static bool _matches(AutomationSummary a, String q) {
    if (q.isEmpty) return true;
    // A word that used to be a filter keeps meaning that filter.
    final off = !a.enabled || a.needsApproval;
    final word = switch (q) {
      'off' || 'turned off' => off,
      'link' || 'links' || 'quick link' || 'quick links' => a.isLink,
      'needs you' || 'review' => a.needsYou,
      _ => null,
    };
    return word ??
        (a.name.toLowerCase().contains(q) ||
            a.sentence.any((p) => p.text.toLowerCase().contains(q)));
  }

  String get _q => _query.text.trim().toLowerCase();

  bool _shows(AutomationSummary a) =>
      !_removing.contains(a.id) && _inFilter(a, _filter) && _matches(a, _q);

  /// Opens the search with [words] in it.
  void _search(String words) => setState(() {
    _searching = true;
    _filter = AutomationFilter.all;
    _query.text = words;
  });

  @override
  Widget build(BuildContext context) {
    ref.listen(automationsProvider, (_, next) {
      if (next.value case final all?) _track(all);
    });
    final async = ref.watch(automationsProvider);
    final all = async.value ?? const <AutomationSummary>[];
    final error = async.error;
    return TabPage.custom(
      title: 'Automations',
      subtitle: automationsStopped(ref)
          ? 'Stopped. Start them from the banner above.'
          : null,
      actions: [
        OmniIconAction(
          key: const ValueKey('automations-search'),
          icon: _searching ? OmniIcons.close : OmniIcons.search,
          label: _searching ? 'Close search' : 'Search automations',
          onPressed: () => setState(() {
            _searching = !_searching;
            if (!_searching) _query.clear();
          }),
        ),
        const ScreenHelpButton(HelpScreen.automations),
      ],
      filters: all.isEmpty ? null : _filters(),
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
      body: (context, padding) => _list(all, padding),
    );
  }

  /// The search field (while searching) and All, Rules and Scenes, pinned
  /// above the list.
  Widget _filters() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_searching)
        Padding(
          padding: const EdgeInsets.only(bottom: OmniSpace.sm),
          child: TextField(
            key: const ValueKey('automations-query'),
            controller: _query,
            autofocus: _query.text.isEmpty,
            decoration: const InputDecoration(
              hintText: 'Search, or type off, link or needs you',
              prefixIcon: Icon(OmniIcons.search),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      OmniSegmented<AutomationFilter>(
        key: const ValueKey('automation-filters'),
        segments: const [
          OmniSegment(AutomationFilter.all, 'All'),
          OmniSegment(AutomationFilter.rules, 'Rules'),
          OmniSegment(AutomationFilter.scenes, 'Scenes'),
        ],
        selected: _filter,
        onChanged: (f) => setState(() => _filter = f),
      ),
    ],
  );

  Widget _list(List<AutomationSummary> all, EdgeInsets padding) {
    final waiting = [
      for (final a in all)
        if (a.needsApproval && !a.isScene) a,
    ];
    // Rules and links first, then the scenes, as All has always read.
    final shown = [
      for (final a in all)
        if (!a.isScene && _shows(a)) a,
      for (final a in all)
        if (a.isScene && _shows(a)) a,
    ];
    final scenes = all.where((a) => a.isScene).length;
    final plain = _filter == AutomationFilter.all && !_searching;
    return RefreshIndicator(
      onRefresh: () => ref.read(automationsProvider.notifier).refresh(),
      child: ListView(
        key: const ValueKey('automations-list'),
        padding: padding,
        children: [
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
              onAction: () => _search('needs you'),
            ),
          if (shown.isEmpty)
            if (_filter == AutomationFilter.scenes && scenes == 0)
              const OmniEmptyState(
                key: ValueKey('scenes-empty'),
                icon: OmniIcons.scene,
                title: 'No scenes yet',
                message:
                    'A scene sets several things at once, like Movie: lamp '
                    '20%, TV on.',
                compact: true,
              )
            else
              OmniEmptyState(
                key: const ValueKey('filter-empty'),
                icon: OmniIcons.search,
                title: _q.isNotEmpty
                    ? switch (_q) {
                        'off' => 'Every automation is on.',
                        'needs you' =>
                          'Nothing needs you. Every automation is approved '
                              'and its last run worked.',
                        'link' || 'quick links' => 'No quick links yet.',
                        _ => 'Nothing matches "${_query.text.trim()}".',
                      }
                    : 'No rules yet.',
                compact: true,
              ),
          _grid(context, shown),
          if (plain) ...[
            const SizedBox(height: OmniSpace.md),
            const _IdeasSection(),
            const _RemovedSection(),
          ],
        ],
      ),
    );
  }

  /// [shown] as two columns of cards, or one from 130% text, where a
  /// card's name would not fit half the width.
  Widget _grid(BuildContext context, List<AutomationSummary> shown) {
    final columns = MediaQuery.textScalerOf(context).scale(10) > 13 ? 1 : 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i += columns)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.md),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < columns; c++) ...[
                    if (c > 0) const SizedBox(width: OmniSpace.md),
                    Expanded(
                      child: i + c < shown.length
                          ? _card(shown[i + c])
                          : const SizedBox(),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _card(AutomationSummary a) {
    final open = a.isScene && !a.needsApproval
        ? () => openSceneEditor(context, id: a.id)
        : () => _push(AutomationPage(id: a.id, summary: a));
    final card = AutomationCard(automation: a, onOpen: open);
    return a.isScene ? card : _swipeable(a, card);
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
        secondaryBackground: _SwipeBackground(
          icon: OmniIcons.delete,
          label: 'Remove',
          color: OmniPalette.of(context).bad,
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
        Flexible(
          child: Text(label, style: OmniText.bodyStrong.copyWith(color: color)),
        ),
      ],
    ),
  );
}

/// One automation as a bold card in its colour: the icon and its state
/// (On, Off, Asks, Review), the name, when it runs in one line, and, when
/// it needs you, why. A tap opens it. A scene's card has Run instead of a
/// state, since a scene runs when you ask.
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

  /// When it runs, in one line: the WHEN and ONLY IF parts of its
  /// sentence, or what a scene sets.
  static String whenLine(AutomationSummary a) {
    if (a.isScene) {
      final sets = a.sentence
          .where((p) => p.kind != SentenceKind.text)
          .map((p) => p.text)
          .join(', ');
      return sets.isEmpty ? 'Scene' : sets;
    }
    final when = [
      for (final p in a.sentence)
        if (p.kind == SentenceKind.when || p.kind == SentenceKind.onlyIf)
          p.text,
    ];
    if (when.isNotEmpty) return when.join(', ');
    return a.isLink ? 'Quick link' : sentenceText(a.sentence);
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final on = (_enabled ?? a.enabled) && !a.needsApproval;
    final last = a.lastRun;
    final failedLast = last != null && !last.ok && !a.needsApproval;
    final color = automationCardColor(a.color);
    const ink = OmniCardColors.onCard;
    final small = OmniText.caption.copyWith(color: ink);
    return Material(
      key: ValueKey(a.isScene ? 'scene-${a.id}' : 'automation-${a.id}'),
      color: color,
      borderRadius: BorderRadius.circular(OmniRadii.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.all(OmniSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CardIcon(
                    key: ValueKey('badge-${a.id}'),
                    icon: automationIconFor(a),
                  ),
                  const Spacer(),
                  if (a.isScene && !a.needsApproval)
                    _RunButton(scene: a)
                  else if (!a.isScene)
                    _StateBadge(
                      automation: a,
                      on: on,
                      onChanged: a.needsApproval ? null : _enable,
                    ),
                ],
              ),
              const SizedBox(height: OmniSpace.md),
              Text(a.name, style: OmniText.cardTitle.copyWith(color: ink)),
              const SizedBox(height: OmniSpace.xs),
              Text(whenLine(a), key: ValueKey('when-${a.id}'), style: small),
              if (a.askFirst)
                Text(
                  'Asks first',
                  key: ValueKey('asks-first-${a.id}'),
                  style: small,
                ),
              if (a.notifyOnRun)
                Text(
                  'Tells you when it runs',
                  key: ValueKey('tells-you-${a.id}'),
                  style: small,
                ),
              // Sets a device the other way from another automation.
              AutomationConflictChip(id: a.id, conflicts: a.conflicts),
              if (a.needsApproval)
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpace.xs),
                  child: Text('Waiting for your review', style: small),
                )
              else if (failedLast) ...[
                Padding(
                  padding: const EdgeInsets.only(top: OmniSpace.xs),
                  child: Text(
                    'Last run failed${last.error == null ? '' : ': ${last.error}'}',
                    key: ValueKey('last-failed-${a.id}'),
                    style: small.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  key: ValueKey('retry-${a.id}'),
                  onPressed: _retrying ? null : _retry,
                  icon: const Icon(OmniIcons.retry, size: 18),
                  label: const Text('Retry'),
                  style: TextButton.styleFrom(
                    foregroundColor: ink,
                    minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                    padding: const EdgeInsets.symmetric(
                      horizontal: OmniSpace.xs,
                    ),
                    textStyle: OmniText.label,
                  ),
                ),
              ],
              // No next run while this phone's automations are stopped.
              NextRunLine(
                a,
                enabled: on && !automationsStopped(ref),
                color: ink,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The state pill on a rule's card: On, Off, Asks (on, and asks before it
/// runs) or Review. A tap turns it on or off, with a 48 dp target; one
/// waiting for review cannot be turned on.
class _StateBadge extends StatelessWidget {
  const _StateBadge({
    required this.automation,
    required this.on,
    required this.onChanged,
  });

  final AutomationSummary automation;
  final bool on;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final a = automation;
    final label = a.needsApproval
        ? 'Review'
        : !on
        ? 'Off'
        : a.askFirst
        ? 'Asks'
        : 'On';
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      enabled: onChanged != null,
      label: a.needsApproval
          ? '${a.name} waits for your review'
          : on
          ? 'Turn ${a.name} off'
          : 'Turn ${a.name} on',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('enable-${a.id}'),
        borderRadius: BorderRadius.circular(OmniRadii.chip),
        onTap: onChanged == null ? null : () => onChanged!(!on),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: OmniSpace.target,
            minHeight: OmniSpace.target,
          ),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: OmniSpace.sm + 2,
                vertical: OmniSpace.xs,
              ),
              decoration: BoxDecoration(
                color: on
                    ? OmniCardColors.onCard
                    : OmniCardColors.onCard.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(OmniRadii.chip),
              ),
              child: Text(
                label,
                key: ValueKey('enable-label-${a.id}'),
                style: OmniText.labelMedium.copyWith(
                  color: on
                      ? automationCardColor(a.color)
                      : OmniCardColors.onCard,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Run on a scene's card.
class _RunButton extends ConsumerWidget {
  const _RunButton({required this.scene});

  final AutomationSummary scene;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
    color: OmniCardColors.onCard,
    shape: const CircleBorder(),
    child: OmniIconAction(
      key: ValueKey('scene-run-${scene.id}'),
      icon: OmniIcons.play,
      label: 'Run ${scene.name}',
      color: automationCardColor(scene.color),
      onPressed: () => runScene(ref, scene.id, scene.name),
    ),
  );
}

/// Ideas for you, collapsed: the suggestions from habits and the
/// templates.
class _IdeasSection extends ConsumerWidget {
  const _IdeasSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Home loads the suggestions when the app opens, so this list only
    // shows what is loaded and starts no read of its own.
    final suggestions = ref.watch(suggestionsProvider.exists)
        ? ref.watch(suggestionsProvider).value ?? const []
        : const [];
    final n = suggestions.length;
    return OmniDisclosure(
      key: const ValueKey('automations-ideas'),
      icon: OmniIcons.star,
      title: 'Ideas for you',
      summary: n == 0
          ? 'Templates to start from'
          : '$n ${n == 1 ? 'automation' : 'automations'} you could add',
      storageId: 'automations-ideas',
      children: const [AutomationHelpers()],
    );
  }
}

/// Recently removed, collapsed: a way to put one back.
class _RemovedSection extends StatelessWidget {
  const _RemovedSection();

  @override
  Widget build(BuildContext context) {
    return OmniDisclosure(
      key: const ValueKey('automations-removed'),
      icon: OmniIcons.delete,
      title: 'Recently removed',
      summary: 'Put back one you removed',
      storageId: 'automations-removed',
      children: [
        OmniListRow(
          key: const ValueKey('automations-removed-open'),
          icon: OmniIcons.retry,
          title: 'See what was removed',
          subtitle: 'Put one back as it was',
          chevron: true,
          divider: false,
          onTap: () => openRecentlyRemoved(context),
        ),
      ],
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
