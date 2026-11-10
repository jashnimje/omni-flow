import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automation_page.dart';
import 'automations_state.dart';
import 'dialogs.dart';
import 'new_automation.dart';
import 'review_page.dart';
import 'test_run.dart';

enum AutomationFilter { all, rules, links, off, needsYou }

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

  bool _shows(AutomationSummary a) {
    final ok = switch (_filter) {
      AutomationFilter.all => true,
      AutomationFilter.rules => a.source == 'rule' || a.source == 'graph',
      AutomationFilter.links => a.isLink,
      AutomationFilter.off => !a.enabled,
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
    if (list.isEmpty) {
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
    final shown = list.where(_shows).toList();
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
                      AutomationFilter.links => 'Links',
                      AutomationFilter.off => 'Off',
                      AutomationFilter.needsYou => 'Needs you',
                    },
                    count: switch (f) {
                      AutomationFilter.all => list.length,
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
          if (shown.isEmpty)
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
                        AutomationFilter.links => 'No links yet.',
                        _ => 'No rules yet.',
                      },
                key: const ValueKey('filter-empty'),
                textAlign: TextAlign.center,
                style: OmniText.caption,
              ),
            ),
          for (final a in shown)
            AutomationCard(
              automation: a,
              onOpen: () => _push(AutomationPage(id: a.id, summary: a)),
            ),
          // Clear of the New button.
          const SizedBox(height: 88),
        ],
      ),
    );
  }

  Future<void> _push(Widget page) =>
      Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));
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
      title: a.name,
      onTap: widget.onOpen,
      trailing: Semantics(
        label: 'Run ${a.name} on its own',
        child: Switch(
          key: ValueKey('enable-${a.id}'),
          // Not loaded until approved, so it shows off whatever it says.
          value: enabled && !a.needsApproval,
          onChanged: a.needsApproval ? null : _enable,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (a.sentence.isNotEmpty) AutomationSentence(a.sentence),
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
