import 'package:flutter/material.dart';

import '../../../api/diagram_calls.dart';
import '../../design/design.dart';
import 'diagram_layout.dart';

/// The words an edge label reads as: "Yes", "No", "If it fails".
String edgeLabelText(String? label) => switch (label) {
  null || 'then' => '',
  'yes' => 'Yes',
  'no' => 'No',
  'otherwise' || 'else' => 'Otherwise',
  'fails' => 'If it fails',
  'each' => 'Each time',
  final answer => answer,
};

/// The lines, their labels and the group boxes under the nodes. In a run
/// the edges it took are solid and the rest faded.
class DiagramPainter extends CustomPainter {
  DiagramPainter({
    required this.diagram,
    required this.layout,
    this.palette = OmniPalette.teal,
    Color? line,
    Color? lit,
  }) : line = line ?? palette.line,
       lit = lit ?? palette.accent;

  final Diagram diagram;
  final DiagramLayout layout;

  /// The theme's colours, which a painter cannot read from a context.
  final OmniPalette palette;
  final Color line;
  final Color lit;

  /// Whether edge [index] is drawn solid: always outside a run, and in a
  /// run only when it was taken.
  bool isSolid(int index) =>
      !diagram.hasRun || diagram.edges[index].taken == true;

  @override
  void paint(Canvas canvas, Size size) {
    _groups(canvas);
    for (final r in layout.edges) {
      _edge(canvas, r);
    }
  }

  void _groups(Canvas canvas) {
    // Outer boxes first, so inner ones draw over them.
    final boxes = layout.groups.entries.toList()
      ..sort(
        (a, b) => (b.value.width * b.value.height).compareTo(
          a.value.width * a.value.height,
        ),
      );
    for (final MapEntry(key: id, value: rect) in boxes) {
      final rrect = RRect.fromRectAndRadius(
        rect,
        const Radius.circular(OmniRadii.card),
      );
      final run = diagram.hasRun;
      final status = diagram.node(id)?.status;
      canvas
        ..drawRRect(
          rrect,
          Paint()..color = palette.flowSoft.withValues(alpha: 0.35),
        )
        ..drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = run && status == NodeStatus.skipped
                ? palette.line
                : palette.flowLine,
        );
    }
  }

  void _edge(Canvas canvas, EdgeRoute r) {
    final solid = isSolid(r.index);
    final run = diagram.hasRun;
    final color = run
        ? (solid ? lit : line.withValues(alpha: 0.5))
        : palette.muted.withValues(alpha: 0.7);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = run && solid ? 2.4 : 1.4
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(r.points.first.dx, r.points.first.dy);
    for (final p in r.points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (run && !solid) {
      _dashed(canvas, path, paint);
    } else {
      canvas.drawPath(path, paint);
    }
    _arrow(canvas, r.points, color);
    final text = edgeLabelText(r.edge.label);
    if (text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: OmniText.caption.copyWith(
          color: run && !solid ? palette.muted : palette.text,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 120);
    final at = r.labelRight ? r.labelAt : r.labelAt - Offset(painter.width, 0);
    painter.paint(canvas, at);
  }

  static void _arrow(Canvas canvas, List<Offset> pts, Color color) {
    final tip = pts.last;
    final from = pts[pts.length - 2];
    final dir = tip - from;
    if (dir.distance == 0) return;
    final u = dir / dir.distance;
    final n = Offset(-u.dy, u.dx);
    final base = tip - u * 7;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((base + n * 4).dx, (base + n * 4).dy)
        ..lineTo((base - n * 4).dx, (base - n * 4).dy)
        ..close(),
      Paint()..color = color,
    );
  }

  static void _dashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(DiagramPainter old) =>
      old.diagram != diagram || old.layout != layout || old.palette != palette;
}

/// A diamond filling its box: the shape of a check.
class DiamondPainter extends CustomPainter {
  const DiamondPainter({
    required this.fill,
    required this.border,
    this.width = 1.4,
  });

  final Color fill;
  final Color border;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(0, size.height / 2)
      ..close();
    canvas
      ..drawPath(path, Paint()..color = fill)
      ..drawPath(
        path,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(DiamondPainter old) =>
      old.fill != fill || old.border != border || old.width != width;
}
