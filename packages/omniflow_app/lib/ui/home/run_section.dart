import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../automations/scenes.dart'
    show automationIconFor, openScenes, openSceneEditor, sceneIconFor;
import '../design/automation_look.dart';
import '../design/design.dart';
import '../shell/shell.dart';

/// One thing Home runs with a tap: a scene, or an automation whose only
/// trigger is manual.
class RunItem {
  const RunItem({
    required this.id,
    required this.name,
    required this.icon,
    required this.isScene,
    this.color,
    this.waiting = false,
  });

  final String id;
  final String name;
  final IconData icon;
  final bool isScene;
  final String? color;

  /// Waiting for review, so a tap opens the review instead.
  final bool waiting;
}

/// Home's Run section: every scene, then every automation that only runs
/// by hand. [summaries] is null while the automations load.
List<RunItem> runItems(List<Scene> scenes, List<AutomationSummary>? summaries) {
  final byId = {for (final a in summaries ?? const []) a.id: a};
  return [
    for (final s in scenes)
      if (s.id case final id?)
        RunItem(
          id: id,
          name: s.name,
          icon: sceneIconFor(s.icon),
          isScene: true,
          color: s.color ?? byId[id]?.color,
          waiting: byId[id]?.needsApproval ?? false,
        ),
    for (final a in summaries ?? const <AutomationSummary>[])
      if (a.manualOnly && !a.isScene)
        RunItem(
          id: a.id,
          name: a.name,
          icon: automationIconFor(a),
          isScene: false,
          color: a.color,
          waiting: a.needsApproval,
        ),
  ];
}

/// The Run header and a grid of coloured tiles, or nothing when there is
/// nothing to run.
class RunSection extends StatelessWidget {
  const RunSection({super.key, required this.items});

  final List<RunItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('home-run'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniSectionHeader(
          'Run',
          actionLabel: 'Scenes',
          onAction: () => openScenes(context),
        ),
        LayoutBuilder(
          builder: (context, box) {
            final columns = box.maxWidth >= 340 ? 3 : 2;
            return Column(
              children: [
                for (var i = 0; i < items.length; i += columns)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OmniSpace.gap),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var c = 0; c < columns; c++) ...[
                            if (c > 0) const SizedBox(width: OmniSpace.gap),
                            Expanded(
                              child: i + c < items.length
                                  ? RunTile(item: items[i + c])
                                  : const SizedBox(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

enum _RunState { idle, running, done, failed }

/// A coloured tile: a tap runs it (a short progress, then a check or the
/// plain reason it failed), a long press opens it.
class RunTile extends ConsumerStatefulWidget {
  const RunTile({super.key, required this.item});

  final RunItem item;

  /// How long the check stays before the tile reads as ready again.
  static const doneFor = Duration(seconds: 2);

  @override
  ConsumerState<RunTile> createState() => _RunTileState();
}

class _RunTileState extends ConsumerState<RunTile> {
  var _state = _RunState.idle;
  String? _error;
  Timer? _reset;

  RunItem get _item => widget.item;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _tap() async {
    if (_item.waiting) return _open(review: true);
    if (_state == _RunState.running) return;
    _reset?.cancel();
    setState(() {
      _state = _RunState.running;
      _error = null;
    });
    final api = ref.read(engineApiProvider);
    final reply = _item.isScene
        ? await api.runScene(_item.id)
        : await api.runAutomation(_item.id);
    if (!mounted) return;
    final error = _errorOf(reply);
    setState(() {
      _state = error == null ? _RunState.done : _RunState.failed;
      _error = error;
    });
    if (error == null) {
      _reset = Timer(RunTile.doneFor, () {
        if (mounted) setState(() => _state = _RunState.idle);
      });
    }
  }

  /// Null when it ran, else the plain reason it did not.
  static String? _errorOf(Reply<List<RunRecord>> reply) {
    if (reply.failure case final f?) return f.message;
    final run = reply.value?.firstOrNull;
    if (run == null || run.ok) return null;
    final failed = run.steps.where((n) => n.error != null).firstOrNull;
    if (failed != null) {
      return '${failed.label ?? 'A step'} failed'
          '${failed.error!.isEmpty ? '' : ': ${failed.error}'}';
    }
    return run.reason ?? 'It did not finish';
  }

  void _open({bool review = false}) {
    if (_item.isScene && !review) {
      openSceneEditor(context, id: _item.id);
      return;
    }
    ref
        .read(shellControllerProvider)
        .open(review ? ReviewLink(_item.id) : AutomationLink(_item.id));
  }

  String get _stateText => switch (_state) {
    _ when _item.waiting => 'Needs your review',
    _RunState.running => 'Running',
    _RunState.done => 'Done',
    _RunState.failed => _error ?? 'Did not run',
    _RunState.idle => _item.isScene ? 'Scene' : 'Tap to run',
  };

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final radius = BorderRadius.circular(OmniRadii.tile);
    final failed = _state == _RunState.failed;
    return Semantics(
      container: true,
      button: true,
      label: '${item.name}, $_stateText',
      hint: item.waiting ? 'Opens its review' : 'Runs it',
      onLongPressHint: 'Open it',
      liveRegion: _state != _RunState.idle,
      excludeSemantics: true,
      onTap: _tap,
      onLongPress: _open,
      child: Material(
        key: ValueKey(item.isScene ? 'scene-${item.id}' : 'run-${item.id}'),
        color: AutomationLook.tintOf(item.color),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: failed
                ? OmniColors.badLine
                : AutomationLook.lineOf(item.color),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _tap,
          onLongPress: _open,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 92),
            child: Padding(
              padding: const EdgeInsets.all(OmniSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      AutomationBadge(
                        icon: item.icon,
                        color: item.color,
                        size: 32,
                      ),
                      const Spacer(),
                      _Indicator(state: _state, id: item.id),
                    ],
                  ),
                  const SizedBox(height: OmniSpace.gap),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OmniText.label,
                  ),
                  Text(
                    _stateText,
                    key: ValueKey('run-state-${item.id}'),
                    maxLines: failed ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: OmniText.caption.copyWith(
                      color: failed
                          ? OmniColors.bad
                          : item.waiting
                          ? OmniColors.warn
                          : OmniColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tile's corner: a small spinner while it runs, a check after, a
/// warning when it failed.
class _Indicator extends StatelessWidget {
  const _Indicator({required this.state, required this.id});

  final _RunState state;
  final String id;

  @override
  Widget build(BuildContext context) => switch (state) {
    _RunState.running => SizedBox.square(
      key: ValueKey('run-busy-$id'),
      dimension: 18,
      child: const CircularProgressIndicator(strokeWidth: 2),
    ),
    _RunState.done => Icon(
      OmniIcons.check,
      key: ValueKey('run-done-$id'),
      size: 20,
      color: OmniColors.accent,
    ),
    _RunState.failed => Icon(
      OmniIcons.error,
      key: ValueKey('run-failed-$id'),
      size: 20,
      color: OmniColors.bad,
    ),
    _RunState.idle => const SizedBox(height: 20),
  };
}
