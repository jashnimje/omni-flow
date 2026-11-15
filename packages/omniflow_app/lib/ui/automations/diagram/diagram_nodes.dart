import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../api/diagram_calls.dart';
import '../../design/design.dart';
import '../rule_words.dart' show AutomationIcons;
import 'diagram_layout.dart';
import 'diagram_painter.dart';

/// The colours a run lights nodes with.
abstract final class RunColors {
  static const ran = Color(0xFF34D399);
  static const failed = OmniColors.bad;
  static const skipped = OmniColors.muted;
  static const waiting = OmniColors.info;
  static const saidNo = OmniColors.warn;

  static Color? of(DiagramNode n) {
    if (n.saidNo) return saidNo;
    return switch (n.status) {
      NodeStatus.ran => ran,
      NodeStatus.failed => failed,
      NodeStatus.skipped => skipped,
      NodeStatus.waiting => waiting,
      _ => null,
    };
  }
}

/// What a node is, in words a screen reader says.
String nodeKindWords(String kind) => switch (kind) {
  NodeKind.trigger => 'Trigger',
  NodeKind.check || NodeKind.decision => 'Check',
  NodeKind.ask => 'Question',
  NodeKind.wait => 'Wait',
  NodeKind.group => 'Group',
  NodeKind.merge => 'Branches join',
  NodeKind.end => 'End',
  _ => 'Step',
};

/// What a node did in a run, in words, or null outside a run.
String? nodeStatusWords(DiagramNode n) {
  if (n.saidNo) return 'said no';
  return switch (n.status) {
    NodeStatus.ran => NodeKind.isDecision(n.kind) ? 'checked' : 'ran',
    NodeStatus.failed => 'failed',
    NodeStatus.skipped => 'skipped',
    NodeStatus.waiting => 'waiting',
    _ => null,
  };
}

/// Everything a screen reader says for [n].
String nodeSemantics(DiagramNode n, {String? error}) => [
  n.words.isEmpty ? nodeKindWords(n.kind) : n.words,
  nodeKindWords(n.kind),
  ?nodeStatusWords(n),
  if (n.seen case final seen?) 'saw $seen',
  if (n.risk != null) 'high risk',
  ?error,
].join(', ');

/// One node of the diagram at its laid-out size: a pill for a trigger, a
/// diamond for a check, a card for a step, a label for a group.
class DiagramNodeCard extends StatelessWidget {
  const DiagramNodeCard({
    super.key,
    required this.node,
    required this.size,
    required this.order,
    this.icon,
    this.color,
    this.error,
    this.onTap,
    this.onLongPress,
    this.actions = const {},
  });

  final DiagramNode node;
  final Size size;

  /// Its place in reading order.
  final int order;
  final IconData? icon;

  /// The automation's colour, for a step's icon box.
  final Color? color;
  final String? error;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Map<CustomSemanticsAction, VoidCallback> actions;

  @override
  Widget build(BuildContext context) {
    final body = switch (node.kind) {
      NodeKind.trigger => _pill(context),
      NodeKind.check || NodeKind.decision => _diamond(context),
      NodeKind.merge => _merge(),
      NodeKind.end => _end(),
      NodeKind.group => _header(),
      _ => _card(context),
    };
    final faded = node.status == NodeStatus.skipped;
    final shown = SizedBox.fromSize(
      size: size,
      child: Opacity(
        opacity: faded ? 0.45 : 1,
        child: node.status == NodeStatus.waiting ? _Pulse(child: body) : body,
      ),
    );
    if (node.kind == NodeKind.merge) {
      return ExcludeSemantics(child: shown);
    }
    return Semantics(
      sortKey: OrdinalSortKey(order.toDouble()),
      container: true,
      button: onTap != null,
      label: nodeSemantics(node, error: error),
      onLongPressHint: onLongPress == null ? null : 'Move, copy or remove',
      customSemanticsActions: actions.isEmpty ? null : actions,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: shown,
      ),
    );
  }

  Color get _ring =>
      error != null ? OmniColors.bad : RunColors.of(node) ?? Colors.transparent;

  Widget? _badge() {
    final (IconData icon, Color color)? mark = node.saidNo
        ? (AutomationIcons.stop, RunColors.saidNo)
        : switch (node.status) {
            NodeStatus.ran => (OmniIcons.check, RunColors.ran),
            NodeStatus.failed => (AutomationIcons.fail, RunColors.failed),
            NodeStatus.waiting => (OmniIcons.wait, RunColors.waiting),
            _ => null,
          };
    if (mark == null) return null;
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(color: mark.$2, shape: BoxShape.circle),
      child: Icon(mark.$1, size: 13, color: OmniColors.background),
    );
  }

  Widget _withBadge(Widget child) {
    final badge = _badge();
    if (badge == null) return child;
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned(top: -6, right: -6, child: badge),
      ],
    );
  }

  /// Words in at most [lines] lines, and no more than the height given
  /// holds, so a large text size or a wide font ends in "…" instead of
  /// spilling out of the node.
  Widget _text(String text, {int lines = 3, TextAlign? align, double? size}) {
    final style = TextStyle(
      fontSize: size ?? 13,
      color: OmniColors.text,
      height: 1.3,
    );
    return LayoutBuilder(
      builder: (context, c) {
        final line = MediaQuery.textScalerOf(context)
            .scale(style.fontSize! * style.height!);
        final fit = c.maxHeight.isFinite
            ? (c.maxHeight / line).floor().clamp(1, lines)
            : lines;
        return Text(
          text,
          maxLines: fit,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: style,
        );
      },
    );
  }

  Widget _pill(BuildContext context) => _withBadge(
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: ShapeDecoration(
        color: OmniColors.triggerSoft,
        shape: StadiumBorder(
          side: BorderSide(
            color: _ring == Colors.transparent ? OmniColors.trigger : _ring,
            width: _ring == Colors.transparent ? 1.2 : 2,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(icon ?? OmniIcons.event, size: 18, color: OmniColors.trigger),
          const SizedBox(width: 6),
          Expanded(child: _text(node.words, lines: 2, size: 12)),
        ],
      ),
    ),
  );

  Widget _diamond(BuildContext context) {
    final ring = _ring;
    final diamond = SizedBox(
      height: DiagramMetrics.diamondHeight,
      child: CustomPaint(
        painter: DiamondPainter(
          fill: OmniColors.conditionSoft,
          border: ring == Colors.transparent ? OmniColors.condition : ring,
          width: ring == Colors.transparent ? 1.4 : 2.4,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 46),
            child: _text(
              node.words,
              lines: 3,
              align: TextAlign.center,
              size: 12,
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _withBadge(diamond),
        if (node.seen case final seen?)
          SizedBox(
            height: DiagramMetrics.seenHeight,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                // Left of the yes line going down from the point.
                width: DiagramMetrics.diamondWidth / 2 - 8,
                child: Text(
                  node.saidNo ? 'Said no, saw $seen' : 'Saw $seen',
                  key: ValueKey('diagram-seen-${node.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: OmniText.caption.copyWith(
                    color: node.saidNo ? RunColors.saidNo : OmniColors.text,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _card(BuildContext context) {
    final ring = _ring;
    final tint = color ?? OmniColors.action;
    final isWait = node.kind == NodeKind.wait;
    return _withBadge(
      Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: BoxDecoration(
          color: OmniColors.card,
          borderRadius: BorderRadius.circular(OmniRadii.step),
          border: Border.all(
            color: ring == Colors.transparent
                ? (isWait ? OmniColors.flowLine : OmniColors.line)
                : ring,
            width: ring == Colors.transparent ? 1 : 2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(OmniRadii.iconBox),
              ),
              child: Icon(icon ?? OmniIcons.action, size: 18, color: tint),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: _text(node.words, lines: node.seen == null ? 3 : 2),
                  ),
                  if (node.seen case final seen?)
                    Text(
                      'Saw $seen',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OmniText.caption,
                    ),
                ],
              ),
            ),
            if (node.risk != null)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(
                  OmniIcons.warning,
                  key: ValueKey('diagram-risk'),
                  size: 16,
                  color: OmniColors.warn,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _merge() => Center(
    child: Container(
      width: DiagramMetrics.mergeSize,
      height: DiagramMetrics.mergeSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: OmniColors.raised,
        border: Border.all(color: RunColors.of(node) ?? OmniColors.muted),
      ),
    ),
  );

  Widget _end() => _withBadge(
    Container(
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: OmniColors.raised,
        shape: StadiumBorder(
          side: BorderSide(color: RunColors.of(node) ?? OmniColors.line),
        ),
      ),
      child: Text(
        node.words.isEmpty ? 'Stops here' : node.words,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OmniText.caption.copyWith(color: OmniColors.text),
      ),
    ),
  );

  Widget _header() => Container(
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: OmniColors.flowSoft,
      borderRadius: BorderRadius.circular(OmniRadii.chip),
      border: Border.all(
        color: error != null ? OmniColors.bad : OmniColors.flowLine,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon ?? AutomationIcons.together,
          size: 14,
          color: OmniColors.flowControl,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            node.words,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OmniText.labelMedium,
          ),
        ),
      ],
    ),
  );
}

/// A waiting node's glow, breathing in and out. Still under reduced
/// motion.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (OmniMotion.reduced(context)) {
      _c
        ..stop()
        ..value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(OmniRadii.step),
        boxShadow: [
          BoxShadow(
            color: RunColors.waiting.withValues(alpha: 0.15 + 0.35 * _c.value),
            blurRadius: 4 + 8 * _c.value,
          ),
        ],
      ),
      child: child,
    ),
    child: widget.child,
  );
}

/// A "+" on an edge: adds a step or a check where the edge runs.
class DiagramPlus extends StatelessWidget {
  const DiagramPlus({
    super.key,
    required this.label,
    required this.onTap,
    required this.order,
  });

  final String label;
  final VoidCallback onTap;
  final int order;

  static const size = 36.0;

  @override
  Widget build(BuildContext context) => Semantics(
    sortKey: OrdinalSortKey(order + 0.5),
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: OmniColors.raised,
              border: Border.all(color: OmniColors.accentLine),
            ),
            child: const Icon(
              OmniIcons.add,
              size: 16,
              color: OmniColors.accent,
            ),
          ),
        ),
      ),
    ),
  );
}
