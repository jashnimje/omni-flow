import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../api/diagram_calls.dart';
import '../../design/design.dart';
import '../rule_words.dart' show AutomationIcons;
import 'diagram_layout.dart';
import 'diagram_nodes.dart';
import 'diagram_painter.dart';

/// What a view asks of whoever shows it, per node and per edge. All
/// optional: a run view shows a diagram without any of them.
class DiagramHandlers {
  const DiagramHandlers({
    this.iconOf,
    this.errorOf,
    this.onTap,
    this.onLongPress,
    this.actionsOf,
    this.onPlus,
    this.color,
  });

  final IconData? Function(DiagramNode node)? iconOf;
  final String? Function(DiagramNode node)? errorOf;
  final void Function(DiagramNode node)? onTap;
  final void Function(DiagramNode node)? onLongPress;
  final Map<CustomSemanticsAction, VoidCallback> Function(DiagramNode node)?
  actionsOf;

  /// A "+" on edge [edge] was tapped. Only edges with an insert point
  /// show one.
  final void Function(DiagramEdge edge)? onPlus;

  /// The automation's colour, for step icons.
  final Color? color;
}

/// The words a "+" says for where it adds.
String plusLabel(DiagramInsert insert) => switch (insert.as) {
  DiagramInsert.check => 'Add a check here',
  DiagramInsert.trigger => 'Add a trigger here',
  _ => 'Add a step here',
};

/// The diagram drawn at its laid-out size: lines and boxes painted, nodes
/// and "+" buttons on top, at their places.
class DiagramCanvas extends StatelessWidget {
  const DiagramCanvas({
    super.key,
    required this.diagram,
    required this.layout,
    this.handlers = const DiagramHandlers(),
  });

  final Diagram diagram;
  final DiagramLayout layout;
  final DiagramHandlers handlers;

  @override
  Widget build(BuildContext context) {
    final h = handlers;
    final order = {for (final (i, id) in layout.order.indexed) id: i};
    return SizedBox.fromSize(
      key: const ValueKey('diagram-canvas'),
      size: layout.size,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: DiagramPainter(
                diagram: diagram,
                layout: layout,
                lit: RunColors.ran,
              ),
            ),
          ),
          for (final n in diagram.nodes)
            if (layout.nodes[n.id] case final rect?)
              Positioned.fromRect(
                rect: rect,
                child: DiagramNodeCard(
                  key: ValueKey('diagram-node-${n.id}'),
                  node: n,
                  size: rect.size,
                  order: order[n.id] ?? 0,
                  icon: h.iconOf?.call(n),
                  color: h.color,
                  error: h.errorOf?.call(n),
                  onTap: h.onTap == null ? null : () => h.onTap!(n),
                  onLongPress: h.onLongPress == null
                      ? null
                      : () => h.onLongPress!(n),
                  actions: h.actionsOf?.call(n) ?? const {},
                ),
              ),
          if (h.onPlus != null)
            for (final r in layout.edges)
              if (r.edge.insert case final insert?)
                Positioned(
                  left: r.plusAt.dx - DiagramPlus.size / 2,
                  top: r.plusAt.dy - DiagramPlus.size / 2,
                  child: DiagramPlus(
                    key: ValueKey('diagram-plus-${r.index}'),
                    label: plusLabel(insert),
                    order: order[r.edge.from] ?? 0,
                    onTap: () => h.onPlus!(r.edge),
                  ),
                ),
        ],
      ),
    );
  }
}

/// The diagram in a pan and zoom viewer that fills its space, fitted to
/// the width when it opens. A graph wider than the screen keeps a
/// readable size and scrolls sideways. Fit shows it all; the list shows
/// the same nodes as rows, and is the view a screen reader starts in.
class DiagramViewer extends StatefulWidget {
  const DiagramViewer({
    super.key,
    required this.diagram,
    this.handlers = const DiagramHandlers(),
    this.toolbar = const [],
  });

  final Diagram diagram;
  final DiagramHandlers handlers;

  /// More buttons for the bar over the diagram.
  final List<Widget> toolbar;

  /// The smallest scale a fit to width goes to, so words stay readable.
  static const minFitScale = 0.5;

  @override
  State<DiagramViewer> createState() => DiagramViewerState();
}

class DiagramViewerState extends State<DiagramViewer> {
  final _transform = TransformationController();
  late DiagramLayout _layout = DiagramLayout.of(widget.diagram);
  Size? _viewport;
  var _fitted = false;
  bool? _asList;

  /// The scale the diagram is shown at.
  double get scale => _transform.value.entry(0, 0);

  DiagramLayout get layout => _layout;

  @override
  void didUpdateWidget(DiagramViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diagram != widget.diagram) {
      _layout = DiagramLayout.of(widget.diagram);
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// Fits the width, at no less than [DiagramViewer.minFitScale] and no
  /// more than full size, centred when narrower than the screen.
  void _fitWidth(Size view) {
    final w = _layout.size.width;
    final s = (view.width / w).clamp(DiagramViewer.minFitScale, 1.0);
    final dx = math.max(0.0, (view.width - w * s) / 2);
    _transform.value = Matrix4.diagonal3Values(s, s, 1)
      ..setTranslationRaw(dx, 0, 0);
  }

  /// Shows the whole diagram.
  void fitAll() {
    final view = _viewport;
    if (view == null) return;
    final size = _layout.size;
    final s = math.min(
      1.0,
      math.min(view.width / size.width, view.height / size.height),
    );
    final dx = math.max(0.0, (view.width - size.width * s) / 2);
    setState(() {
      _transform.value = Matrix4.diagonal3Values(s, s, 1)
        ..setTranslationRaw(dx, 0, 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final asList = _asList ?? MediaQuery.accessibleNavigationOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ...widget.toolbar,
            const Spacer(),
            if (!asList)
              TextButton.icon(
                key: const ValueKey('diagram-fit'),
                onPressed: fitAll,
                icon: const Icon(OmniIcons.screen, size: 18),
                label: const Text('Fit'),
              ),
            TextButton.icon(
              key: const ValueKey('diagram-as-list'),
              onPressed: () => setState(() => _asList = !asList),
              icon: Icon(
                asList ? OmniIcons.branch : AutomationIcons.list,
                size: 18,
              ),
              label: Text(asList ? 'Show diagram' : 'Show as list'),
            ),
          ],
        ),
        Expanded(
          child: asList
              ? DiagramList(
                  diagram: widget.diagram,
                  layout: _layout,
                  handlers: widget.handlers,
                )
              : LayoutBuilder(
                  builder: (context, c) {
                    _viewport = c.biggest;
                    if (!_fitted) {
                      _fitted = true;
                      _fitWidth(c.biggest);
                    }
                    return ClipRect(
                      child: InteractiveViewer(
                        key: const ValueKey('diagram-viewer'),
                        transformationController: _transform,
                        constrained: false,
                        minScale: 0.3,
                        maxScale: 2.5,
                        boundaryMargin: const EdgeInsets.all(120),
                        child: DiagramCanvas(
                          diagram: widget.diagram,
                          layout: _layout,
                          handlers: widget.handlers,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// The diagram drawn at a fixed scale that fits [maxWidth], for a page
/// that scrolls. Read-only.
class DiagramPicture extends StatelessWidget {
  const DiagramPicture({
    super.key,
    required this.diagram,
    this.handlers = const DiagramHandlers(),
  });

  final Diagram diagram;
  final DiagramHandlers handlers;

  @override
  Widget build(BuildContext context) {
    final layout = DiagramLayout.of(diagram);
    if (MediaQuery.accessibleNavigationOf(context)) {
      return DiagramList(
        diagram: diagram,
        layout: layout,
        handlers: handlers,
        scrolls: false,
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final s = math.min(1.0, c.maxWidth / layout.size.width);
        return Center(
          child: SizedBox(
            width: layout.size.width * s,
            height: layout.size.height * s,
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.topCenter,
              child: DiagramCanvas(
                diagram: diagram,
                layout: layout,
                handlers: handlers,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The diagram's nodes as rows in reading order, each with its kind and
/// what it did, for screen readers and anyone who prefers a list. A row
/// does what a tap on its node does.
class DiagramList extends StatelessWidget {
  const DiagramList({
    super.key,
    required this.diagram,
    required this.layout,
    this.handlers = const DiagramHandlers(),
    this.scrolls = true,
  });

  final Diagram diagram;
  final DiagramLayout layout;
  final DiagramHandlers handlers;
  final bool scrolls;

  @override
  Widget build(BuildContext context) {
    final h = handlers;
    final rows = [
      for (final id in layout.order)
        if (diagram.node(id) case final n? when n.kind != NodeKind.merge)
          OmniListRow(
            key: ValueKey('diagram-row-${n.id}'),
            icon: h.iconOf?.call(n) ?? _kindIcon(n.kind),
            iconForeground: RunColors.of(n),
            title: n.words.isEmpty ? nodeKindWords(n.kind) : n.words,
            subtitle: [
              nodeKindWords(n.kind),
              ?nodeStatusWords(n),
              if (n.seen case final seen?) 'saw $seen',
              ?h.errorOf?.call(n),
            ].join(', '),
            subtitleLines: 3,
            onTap: h.onTap == null ? null : () => h.onTap!(n),
          ),
    ];
    if (!scrolls) {
      return Column(key: const ValueKey('diagram-list'), children: rows);
    }
    return ListView(key: const ValueKey('diagram-list'), children: rows);
  }

  static IconData _kindIcon(String kind) => switch (kind) {
    NodeKind.trigger => OmniIcons.event,
    NodeKind.check || NodeKind.decision => OmniIcons.branch,
    NodeKind.wait => OmniIcons.wait,
    NodeKind.group => OmniIcons.repeat,
    NodeKind.end => OmniIcons.close,
    _ => OmniIcons.action,
  };
}
