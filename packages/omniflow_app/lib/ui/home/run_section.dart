import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart';
import '../../state/house.dart' show houseInViewProvider;
import '../../state/providers.dart';
import '../automations/scenes.dart'
    show automationIconFor, openScenes, openSceneEditor, sceneIconFor;
import '../design/automation_look.dart';
import '../design/design.dart';
import '../fun/springy_press.dart';
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

/// The scenes Surprise me picks from: the ones that run on a tap. Null
/// with fewer than two, when there is no surprise to have.
List<RunItem>? surpriseScenes(List<RunItem> items) {
  final scenes = [
    for (final i in items)
      if (i.isScene && !i.waiting) i,
  ];
  return scenes.length >= 2 ? scenes : null;
}

/// Home's Scenes: a 56 dp run button for every scene and manual
/// automation, then Surprise me with two scenes or more. "All" opens the
/// Scenes page. Each button is keyed by the house and what it runs, so the
/// last result of one house's button never shows on another's in the
/// same place.
class RunSection extends ConsumerWidget {
  const RunSection({super.key, required this.items});

  final List<RunItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final house = ref.watch(houseInViewProvider).value;
    final surprise = surpriseScenes(items);
    final tiles = <Widget>[
      for (final item in items)
        RunTile(key: ValueKey('run-tile-$house-${item.id}'), item: item),
      if (surprise != null)
        SurpriseTile(key: ValueKey('run-surprise-$house'), scenes: surprise),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('home-run'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniSectionHeader(
          'Scenes',
          actionLabel: 'All',
          onAction: () => openScenes(context),
        ),
        LayoutBuilder(
          builder: (context, box) {
            // Columns by the width the text needs, so large text gets
            // wider tiles rather than cut-off names.
            final width = box.maxWidth / runTextScale(context);
            final columns = runTextScale(context) > 1.3
                ? 1
                : width >= 520
                ? 3
                : width >= 260
                ? 2
                : 1;
            return Column(
              children: [
                for (var i = 0; i < tiles.length; i += columns)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OmniSpace.md),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var c = 0; c < columns; c++) ...[
                            if (c > 0) const SizedBox(width: OmniSpace.md),
                            Expanded(
                              child: i + c < tiles.length
                                  ? tiles[i + c]
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

/// How much larger than normal the system draws text.
double runTextScale(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(OmniText.body.fontSize!) /
    OmniText.body.fontSize!;

/// [lines] at normal text sizes, more at large ones so nothing is cut.
int runLines(BuildContext context, int lines) =>
    runTextScale(context) >= 1.3 ? lines * 2 : lines;

/// A coloured tile: a tap runs it (a short progress, then a check or the
/// plain reason it failed), a long press opens it.
class RunTile extends ConsumerStatefulWidget {
  const RunTile({super.key, required this.item, this.pick});

  final RunItem item;

  /// Chooses what a tap runs, for Surprise me. A tile with it has nothing
  /// to open on a long press.
  final RunItem Function()? pick;

  /// How long the check stays before the tile reads as ready again.
  static const doneFor = Duration(seconds: 2);

  @override
  ConsumerState<RunTile> createState() => _RunTileState();
}

class _RunTileState extends ConsumerState<RunTile> {
  var _state = _RunState.idle;
  String? _error;
  Timer? _reset;

  /// What the last tap of Surprise me ran.
  String? _ran;

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
    final target = widget.pick?.call() ?? _item;
    final api = ref.read(engineApiProvider);
    final reply = target.isScene
        ? await api.runScene(target.id)
        : await api.runAutomation(target.id);
    if (!mounted) return;
    final error = _errorOf(reply);
    setState(() {
      _state = error == null ? _RunState.done : _RunState.failed;
      _error = error;
      _ran = widget.pick == null ? null : target.name;
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
      return failed.error!.isEmpty
          ? '${failed.label ?? 'A step'} did not work'
          : failed.error!;
    }
    return run.reason ?? 'It did not finish';
  }

  void _open({bool review = false}) {
    if (widget.pick != null) return;
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
    _RunState.done => _ran == null ? 'Done' : 'Ran $_ran',
    _RunState.failed => _error ?? 'Did not run',
    _RunState.idle when widget.pick != null => 'A random scene',
    _RunState.idle => _item.isScene ? 'Scene' : 'Tap to run',
  };

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final palette = OmniPalette.of(context);
    final radius = BorderRadius.circular(OmniRadii.button);
    final failed = _state == _RunState.failed;
    final card = palette.card;
    final own = AutomationLook.colorOf(item.color);
    final caption = OmniDepth.captionOn(
      own == null ? card : OmniDepth.washTopOf(own, card),
      palette: palette,
    );
    return Semantics(
      container: true,
      button: true,
      label: '${item.name}, $_stateText',
      hint: item.waiting
          ? 'Opens its review'
          : widget.pick != null
          ? 'Runs one of your scenes at random'
          : 'Runs it',
      onLongPressHint: widget.pick == null ? 'Open it' : null,
      liveRegion: _state != _RunState.idle,
      excludeSemantics: true,
      onTap: _tap,
      onLongPress: widget.pick == null ? _open : null,
      child: SpringyPress(
        child: DecoratedBox(
          decoration: OmniDepth.surface(
            color: card,
            gradient: own == null ? null : OmniDepth.wash(own, card),
            radius: radius,
            border: failed ? palette.badLine : null,
          ),
          child: Material(
            key: ValueKey(item.isScene ? 'scene-${item.id}' : 'run-${item.id}'),
            type: MaterialType.transparency,
            shape: RoundedRectangleBorder(borderRadius: radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _tap,
              onLongPress: widget.pick == null ? _open : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: OmniSpace.targetLarge,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OmniSpace.md,
                    vertical: OmniSpace.sm,
                  ),
                  child: Row(
                    children: [
                      AutomationBadge(
                        icon: item.icon,
                        color: item.color,
                        size: 32,
                      ),
                      const SizedBox(width: OmniSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.name,
                              maxLines: runLines(context, 2),
                              overflow: TextOverflow.ellipsis,
                              style: OmniText.bodyStrong,
                            ),
                            Text(
                              _stateText,
                              key: ValueKey('run-state-${item.id}'),
                              maxLines: runLines(context, failed ? 3 : 1),
                              overflow: TextOverflow.ellipsis,
                              style: OmniText.labelMedium.copyWith(
                                color: failed
                                    ? palette.bad
                                    : item.waiting
                                    ? palette.warn
                                    : caption,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _Indicator(state: _state, id: item.id),
                    ],
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
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: OmniPalette.of(context).accent,
      ),
    ),
    _RunState.done => PoppingCheck(key: ValueKey('run-done-$id')),
    _RunState.failed => Icon(
      OmniIcons.error,
      key: ValueKey('run-failed-$id'),
      size: 20,
      color: OmniPalette.of(context).bad,
    ),
    _RunState.idle => const SizedBox.shrink(),
  };
}

/// Runs one of [scenes] at random, never the same one twice in a row.
class SurpriseTile extends StatefulWidget {
  const SurpriseTile({super.key, required this.scenes, this.random});

  final List<RunItem> scenes;

  /// Fixes the picks, for tests.
  final Random? random;

  @override
  State<SurpriseTile> createState() => _SurpriseTileState();
}

class _SurpriseTileState extends State<SurpriseTile> {
  late final _random = widget.random ?? Random();
  String? _last;

  RunItem _pick() {
    final choices = [
      for (final s in widget.scenes)
        if (s.id != _last) s,
    ];
    final pick = choices[_random.nextInt(choices.length)];
    _last = pick.id;
    return pick;
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: const ValueKey('run-surprise'),
    child: RunTile(
      item: const RunItem(
        id: '_surprise',
        name: 'Surprise me',
        icon: Symbols.casino_rounded,
        isScene: true,
      ),
      pick: _pick,
    ),
  );
}
