import 'dart:math' as math;
import 'dart:ui';

import '../../../api/diagram_calls.dart';

/// The sizes the diagram is laid out in, in logical pixels before zoom.
abstract final class DiagramMetrics {
  static const cardWidth = 208.0;
  static const pillWidth = 152.0;
  static const diamondWidth = 216.0;
  static const diamondHeight = 96.0;
  static const seenHeight = 34.0;
  static const endWidth = 112.0;
  static const endHeight = 36.0;
  static const mergeSize = 14.0;
  static const headerHeight = 30.0;

  /// Between rows: room for a label and a "+".
  static const vGap = 48.0;

  /// Between columns.
  static const hGap = 24.0;

  /// The empty column a branch with no steps takes, wide enough for "+".
  static const lane = 48.0;
  static const groupPad = 16.0;
  static const margin = 16.0;

  /// Characters a line of a card holds, at its text size.
  static const cardChars = 20;
  static const pillChars = 15;
  static const diamondChars = 16;
}

/// How an edge is drawn: its points, where its label and its "+" sit.
class EdgeRoute {
  const EdgeRoute({
    required this.index,
    required this.edge,
    required this.points,
    required this.labelAt,
    required this.plusAt,
    this.loop = false,
  });

  /// The edge's place in [Diagram.edges].
  final int index;
  final DiagramEdge edge;
  final List<Offset> points;

  /// The start of the label: left of a line going down, above one going
  /// right.
  final Offset labelAt;
  final Offset plusAt;

  /// A line back up (a repeat), drawn round the side.
  final bool loop;

  /// Whether the label sits right of [labelAt] (a line going right) or
  /// ends at it (a line going down).
  bool get labelRight => points.length > 1 && points[1].dy == points[0].dy;
}

/// Where each part of a diagram goes. Computed from the diagram alone, so
/// the same diagram always lays out the same way.
class DiagramLayout {
  DiagramLayout._({
    required this.size,
    required this.nodes,
    required this.groups,
    required this.edges,
    required this.order,
  });

  /// Lays [diagram] out top to bottom. Triggers sit in a row at the top,
  /// a decision's yes goes down and its other ways go right, the branches
  /// of a group sit side by side, and each group is a box round its
  /// nodes.
  factory DiagramLayout.of(Diagram diagram) => _Layouter(diagram).run();

  final Size size;

  /// Each node's box. A group's is its label at the top of its box.
  final Map<String, Rect> nodes;

  /// Each group's box, round its label and its nodes.
  final Map<String, Rect> groups;
  final List<EdgeRoute> edges;

  /// The nodes in reading order: top to bottom, each branch in turn.
  final List<String> order;

  /// The size [node] is drawn at.
  static Size sizeOf(DiagramNode node) {
    final len = node.words.length;
    int lines(int chars, int most) =>
        math.max(1, math.min(most, (len / chars).ceil()));
    return switch (node.kind) {
      NodeKind.trigger => Size(
        DiagramMetrics.pillWidth,
        math.max(44, 20 + lines(DiagramMetrics.pillChars, 2) * 17),
      ),
      NodeKind.check || NodeKind.decision => Size(
        DiagramMetrics.diamondWidth,
        DiagramMetrics.diamondHeight +
            (node.seen == null ? 0 : DiagramMetrics.seenHeight),
      ),
      NodeKind.end => const Size(
        DiagramMetrics.endWidth,
        DiagramMetrics.endHeight,
      ),
      NodeKind.merge => const Size(
        DiagramMetrics.mergeSize,
        DiagramMetrics.mergeSize,
      ),
      NodeKind.group => Size(
        (len * 7.0 + 40).clamp(96, DiagramMetrics.cardWidth),
        DiagramMetrics.headerHeight,
      ),
      _ => Size(
        DiagramMetrics.cardWidth,
        math.max(
          56,
          24 +
              lines(DiagramMetrics.cardChars, 3) * 18 +
              (node.seen == null ? 0 : 16),
        ),
      ),
    };
  }

  /// Where an edge leaves [rect] of [node] going down: a diamond's bottom
  /// point, not the bottom of the words under it.
  static double bottomOf(DiagramNode node, Rect rect) =>
      NodeKind.isDecision(node.kind)
      ? rect.top + DiagramMetrics.diamondHeight
      : rect.bottom;

  /// The middle height of a diamond, where its side ways leave.
  static double sideOf(DiagramNode node, Rect rect) =>
      NodeKind.isDecision(node.kind)
      ? rect.top + DiagramMetrics.diamondHeight / 2
      : rect.center.dy;
}

/// A laid-out piece: its size, the x of the line through it, and what it
/// holds at offsets from its top left.
class _Block {
  double w = 0;
  double h = 0;
  double axis = 0;
  final items = <(Offset, Object)>[];

  bool get isEmpty => items.isEmpty;
}

/// A node placed in a block.
class _NodeItem {
  const _NodeItem(this.id, this.size);
  final String id;
  final Size size;
}

/// An empty branch: the column its edge goes down.
class _LaneItem {
  const _LaneItem(this.edge);
  final int edge;
}

/// A group's box round [inner].
class _GroupItem {
  const _GroupItem(this.id, this.inner);
  final String id;
  final _Block inner;
}

class _Layouter {
  _Layouter(this.d);

  final Diagram d;
  late final Map<String, DiagramNode> _byId = {
    for (final n in d.nodes) n.id: n,
  };

  /// The edges out of each node, by index, in the diagram's order.
  final _out = <String, List<int>>{};
  final _back = <int>{};
  final _ipdom = <String, String?>{};
  final _parent = <String, String>{};
  final _members = <String, Set<String>>{};
  final _placed = <String>{};
  final _order = <String>[];

  /// Edges that leave a decision from its side.
  final _side = <int>{};

  /// The x of each lane, relative to its block, flattened to the canvas.
  final _laneX = <int, double>{};
  final _rects = <String, Rect>{};
  final _groupRects = <String, Rect>{};

  DiagramLayout run() {
    _graph();
    final root = _Block();
    final roots = _roots();
    if (roots.length > 1) {
      final join = _commonJoin(roots);
      _stack(root, _sideBySide(roots, join));
      _stack(root, _chain(join, null, null, null).$1);
    } else if (roots.isNotEmpty) {
      _stack(root, _chain(roots.first, null, null, null).$1);
    }
    // Anything no edge reaches, in the diagram's order.
    for (final n in d.nodes) {
      if (_placed.contains(n.id) || _parent.containsKey(n.id)) continue;
      _stack(root, _chain(n.id, null, null, null).$1);
    }
    for (final n in d.nodes) {
      if (_placed.contains(n.id)) continue;
      _stack(root, _chain(n.id, null, null, null).$1);
    }
    _flatten(root, const Offset(DiagramMetrics.margin, DiagramMetrics.margin));
    final routes = _route();
    var right = root.w + DiagramMetrics.margin;
    var bottom = root.h + DiagramMetrics.margin;
    for (final r in routes) {
      for (final p in r.points) {
        right = math.max(right, p.dx);
        bottom = math.max(bottom, p.dy);
      }
    }
    return DiagramLayout._(
      size: Size(right + DiagramMetrics.margin, bottom + DiagramMetrics.margin),
      nodes: _rects,
      groups: _groupRects,
      edges: routes,
      order: _order,
    );
  }

  // The graph: edges out, back edges, groups and post-dominators.

  void _graph() {
    for (final (i, e) in d.edges.indexed) {
      (_out[e.from] ??= []).add(i);
    }
    for (final n in d.nodes) {
      if (n.kind != NodeKind.group) continue;
      for (final c in n.children) {
        if (_byId.containsKey(c) && c != n.id) _parent[c] ??= n.id;
      }
    }
    // A group listed inside itself, through its children, is cut there.
    for (final g in _parent.keys.toList()) {
      final seen = <String>{g};
      var p = _parent[g];
      while (p != null) {
        if (!seen.add(p)) {
          _parent.remove(g);
          break;
        }
        p = _parent[p];
      }
    }
    _findBackEdges();
    _postDominators();
  }

  void _findBackEdges() {
    final state = <String, int>{};
    void visit(String id) {
      state[id] = 1;
      for (final i in _out[id] ?? const <int>[]) {
        final to = d.edges[i].to;
        switch (state[to]) {
          case 1:
            _back.add(i);
          case null:
            visit(to);
        }
      }
      state[id] = 2;
    }

    for (final r in _roots()) {
      if (state[r] == null) visit(r);
    }
    for (final n in d.nodes) {
      if (state[n.id] == null) visit(n.id);
    }
  }

  Iterable<int> _dagOut(String id) =>
      (_out[id] ?? const <int>[]).where((i) => !_back.contains(i));

  /// Nodes no forward edge reaches, triggers first, in the diagram's order.
  List<String> _roots() {
    final reached = {
      for (final (i, e) in d.edges.indexed)
        if (!_back.contains(i)) e.to,
    };
    final roots = [
      for (final n in d.nodes)
        if (!reached.contains(n.id) &&
            (_out[n.id]?.isNotEmpty ?? false) &&
            n.kind != NodeKind.group)
          n.id,
    ];
    roots.sort((a, b) {
      final ta = _byId[a]!.kind == NodeKind.trigger ? 0 : 1;
      final tb = _byId[b]!.kind == NodeKind.trigger ? 0 : 1;
      return ta.compareTo(tb);
    });
    if (roots.isEmpty && d.nodes.isNotEmpty) return [d.nodes.first.id];
    return roots;
  }

  static const _sink = '\u0000sink';

  /// For each node, the first node every way out of it passes through:
  /// where its branches join again.
  void _postDominators() {
    final pdom = <String, Set<String>>{};
    final indeg = <String, int>{for (final n in d.nodes) n.id: 0};
    for (final n in d.nodes) {
      for (final i in _dagOut(n.id)) {
        indeg[d.edges[i].to] = (indeg[d.edges[i].to] ?? 0) + 1;
      }
    }
    final topo = <String>[];
    final queue = [
      for (final n in d.nodes)
        if (indeg[n.id] == 0) n.id,
    ];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      topo.add(id);
      for (final i in _dagOut(id)) {
        final to = d.edges[i].to;
        indeg[to] = indeg[to]! - 1;
        if (indeg[to] == 0) queue.add(to);
      }
    }
    for (final id in topo.reversed) {
      final succ = {for (final i in _dagOut(id)) d.edges[i].to};
      Set<String>? meet;
      for (final s in succ) {
        final ps = pdom[s] ?? {s, _sink};
        meet = meet == null ? {...ps} : meet.intersection(ps);
      }
      pdom[id] = {id, ...?meet, if (meet == null) _sink};
    }
    for (final id in topo) {
      final mine = pdom[id]!;
      String? best;
      for (final c in mine) {
        if (c == id || c == _sink) continue;
        if ((pdom[c]?.length ?? 0) == mine.length - 1) best = c;
      }
      _ipdom[id] = best;
    }
    _pdom = pdom;
  }

  Map<String, Set<String>> _pdom = const {};

  /// The nearest node all of [roots] lead to, or null.
  String? _commonJoin(List<String> roots) {
    Set<String>? meet;
    for (final r in roots) {
      final ps = _pdom[r] ?? {r};
      meet = meet == null ? {...ps} : meet.intersection(ps);
    }
    String? best;
    var bestSize = -1;
    for (final c in meet ?? const <String>{}) {
      if (c == _sink) continue;
      final size = _pdom[c]?.length ?? 0;
      if (size > bestSize) {
        best = c;
        bestSize = size;
      }
    }
    return best;
  }

  /// [g] and every group and node inside it.
  Set<String> _membersOf(String g) => _members[g] ??= {
    g,
    for (final n in d.nodes)
      if (_ancestors(n.id).contains(g)) n.id,
  };

  /// The groups [id] sits in, innermost first.
  List<String> _ancestors(String id) {
    final out = <String>[];
    var p = _parent[id];
    while (p != null) {
      out.add(p);
      p = _parent[p];
    }
    return out;
  }

  /// The outermost group holding [id] (or [id] itself, a group) that the
  /// chain being laid out, inside [scopeGroup], has not opened yet.
  String? _groupToOpen(String id, String? scopeGroup) {
    final open = {
      ?scopeGroup,
      if (scopeGroup != null) ..._ancestors(scopeGroup),
    };
    final holding = [
      if (_byId[id]!.kind == NodeKind.group) id,
      ..._ancestors(id),
    ].reversed;
    for (final g in holding) {
      if (!open.contains(g)) return g;
    }
    return null;
  }

  // Blocks.

  _Block _nodeBlock(String id) {
    final size = DiagramLayout.sizeOf(_byId[id]!);
    return _Block()
      ..w = size.width
      ..h = size.height
      ..axis = size.width / 2
      ..items.add((Offset.zero, _NodeItem(id, size)));
  }

  _Block _laneBlock(int edge, {double height = 24}) => _Block()
    ..w = DiagramMetrics.lane
    ..h = height
    ..axis = DiagramMetrics.lane / 2
    ..items.add((Offset.zero, _LaneItem(edge)));

  /// Puts [b] under what [column] holds, lining up their lines.
  void _stack(_Block column, _Block b) {
    if (b.isEmpty) return;
    final top = column.isEmpty ? 0.0 : column.h + DiagramMetrics.vGap;
    final axis = math.max(column.axis, b.axis);
    final shiftOld = axis - column.axis;
    if (shiftOld > 0) {
      for (var i = 0; i < column.items.length; i++) {
        final (o, item) = column.items[i];
        column.items[i] = (o + Offset(shiftOld, 0), item);
      }
      column.w += shiftOld;
    }
    final x = axis - b.axis;
    column.items.add((Offset(x, top), b));
    column
      ..axis = axis
      ..w = math.max(column.w, x + b.w)
      ..h = top + b.h;
  }

  /// Lays out from [start] down until [stop], a node outside [scope], or
  /// a node already placed. Gives the block and where it stopped.
  (_Block, String?) _chain(
    String? start,
    String? stop,
    Set<String>? scope,
    String? scopeGroup,
  ) {
    final column = _Block();
    var cur = start;
    while (cur != null &&
        cur != stop &&
        !_placed.contains(cur) &&
        (scope == null || scope.contains(cur))) {
      if (_groupToOpen(cur, scopeGroup) case final g?) {
        final (box, next) = _groupBlock(g, cur, stop, scope, scopeGroup);
        _stack(column, box);
        cur = next;
        continue;
      }
      _placed.add(cur);
      _order.add(cur);
      final outs = _dagOut(cur)
          .where((i) => !_besideGroup.contains(i))
          .toList();
      if (outs.length <= 1) {
        _stack(column, _nodeBlock(cur));
        cur = outs.isEmpty ? null : d.edges[outs.first].to;
        continue;
      }
      var join = _ipdom[cur];
      if (join == null && scope != null) {
        // A way out of the group with no common end: the chain goes on
        // there once the group is done.
        final leaving = {
          for (final i in outs)
            if (!scope.contains(d.edges[i].to)) d.edges[i].to,
        };
        if (leaving.length == 1) join = leaving.single;
      }
      _stack(column, _fork(cur, outs, join ?? stop, scope, scopeGroup));
      cur = join;
    }
    return (column, cur);
  }

  /// Edges from a group's label that leave the group sideways (a try's
  /// "If it fails"): drawn beside the box, not inside it.
  final _besideGroup = <int>{};

  static const _sideLabels = {'no', 'otherwise', 'else', 'fails'};

  /// [g]'s box: its label, then its nodes from [entry], until the chain
  /// leaves it, with a way out of its label that leaves sideways laid
  /// beside the box. Gives the box and the node after it.
  (_Block, String?) _groupBlock(
    String g,
    String entry,
    String? stop,
    Set<String>? scope,
    String? scopeGroup,
  ) {
    final members = _membersOf(g);
    final beside = entry != g
        ? const <int>[]
        : [
            for (final i in _dagOut(g))
              if (!members.contains(d.edges[i].to) &&
                  _sideLabels.contains(d.edges[i].label))
                i,
          ];
    _besideGroup.addAll(beside);
    final inner = _Block();
    if (entry != g && !_placed.contains(g)) {
      // A group the edges pass by: its label still heads the box.
      _placed.add(g);
      _order.add(g);
      _stack(inner, _nodeBlock(g));
    }
    final (body, next) = _chain(entry, stop, members, g);
    _stack(inner, body);
    const pad = DiagramMetrics.groupPad;
    final box = _Block()
      ..w = inner.w + pad * 2
      ..h = inner.h + pad * 2
      ..axis = inner.axis + pad
      ..items.add((Offset.zero, _GroupItem(g, inner)));
    if (beside.isEmpty) return (box, next);
    final join = _ipdom[g] ?? next;
    final row = _Block()
      ..w = box.w
      ..h = box.h
      ..axis = box.axis
      ..items.add((Offset.zero, box));
    const y = pad + DiagramMetrics.headerHeight / 2 + 16;
    for (final i in beside) {
      _side.add(i);
      final to = d.edges[i].to;
      var b = _Block();
      if (to != join &&
          !_placed.contains(to) &&
          (scope == null || scope.contains(to))) {
        b = _chain(to, join ?? stop, scope, scopeGroup).$1;
      }
      if (b.isEmpty) b = _laneBlock(i, height: 8);
      final x = row.w + DiagramMetrics.hGap;
      row.items.add((Offset(x, y), b));
      row
        ..w = x + b.w
        ..h = math.max(row.h, y + b.h);
    }
    return (row, next ?? join);
  }

  /// [roots] side by side, each down to [join].
  _Block _sideBySide(List<String> roots, String? join) {
    final row = _Block();
    for (final r in roots) {
      final (b, _) = _chain(r, join, null, null);
      if (b.isEmpty) continue;
      final x = row.isEmpty ? 0.0 : row.w + DiagramMetrics.hGap;
      row.items.add((Offset(x, 0), b));
      row
        ..w = x + b.w
        ..h = math.max(row.h, b.h);
    }
    row.axis = row.w / 2;
    return row;
  }

  /// A node with more than one way out, its branches, down to [join].
  _Block _fork(
    String id,
    List<int> outs,
    String? join,
    Set<String>? scope,
    String? scopeGroup,
  ) {
    final node = _byId[id]!;
    final size = DiagramLayout.sizeOf(node);
    // A decision, and anything with a no, otherwise or fails way out,
    // goes on down its main way and out to the right on the others.
    final decision =
        NodeKind.isDecision(node.kind) ||
        outs.any((i) => _sideLabels.contains(d.edges[i].label));
    if (decision) {
      final main = outs.indexWhere(
        (i) => !_sideLabels.contains(d.edges[i].label),
      );
      if (main > 0) outs.insert(0, outs.removeAt(main));
    }
    _Block branch(int edge, {required bool side}) {
      final to = d.edges[edge].to;
      final empty =
          to == join ||
          _placed.contains(to) ||
          (scope != null && !scope.contains(to));
      if (!empty) {
        final (b, _) = _chain(to, join, scope, scopeGroup);
        if (!b.isEmpty) return b;
      }
      return _laneBlock(edge, height: side ? 8 : 24);
    }

    final block = _Block();
    if (decision) {
      final first = branch(outs.first, side: false);
      final a0 = math.max(size.width / 2, first.axis);
      final col0 = a0 + math.max(size.width / 2, first.w - first.axis);
      block.items
        ..add((Offset(a0 - size.width / 2, 0), _NodeItem(id, size)))
        ..add((
          Offset(a0 - first.axis, size.height + DiagramMetrics.vGap),
          first,
        ));
      var right = col0;
      var h = size.height + DiagramMetrics.vGap + first.h;
      final y =
          (NodeKind.isDecision(node.kind)
              ? DiagramMetrics.diamondHeight / 2
              : size.height / 2) +
          16;
      for (final i in outs.skip(1)) {
        _side.add(i);
        final b = branch(i, side: true);
        final x = right + DiagramMetrics.hGap;
        block.items.add((Offset(x, y), b));
        right = x + b.w;
        h = math.max(h, y + b.h);
      }
      block
        ..w = right
        ..h = h
        ..axis = a0;
      return block;
    }
    final row = <(_Block, double)>[];
    var x = 0.0;
    for (final i in outs) {
      final b = branch(i, side: false);
      row.add((b, x));
      x += b.w + DiagramMetrics.hGap;
    }
    final rowW = x - DiagramMetrics.hGap;
    final firstAxis = row.first.$2 + row.first.$1.axis;
    final lastAxis = row.last.$2 + row.last.$1.axis;
    final center = (firstAxis + lastAxis) / 2;
    final nodeX = center - size.width / 2;
    final shift = nodeX < 0 ? -nodeX : 0.0;
    block.items.add((Offset(nodeX + shift, 0), _NodeItem(id, size)));
    var h = 0.0;
    for (final (b, bx) in row) {
      block.items.add((
        Offset(bx + shift, size.height + DiagramMetrics.vGap),
        b,
      ));
      h = math.max(h, b.h);
    }
    block
      ..w = math.max(rowW + shift, nodeX + shift + size.width)
      ..h = size.height + DiagramMetrics.vGap + h
      ..axis = center + shift;
    return block;
  }

  // Placing and routing.

  void _flatten(_Block b, Offset at) {
    for (final (o, item) in b.items) {
      final p = at + o;
      switch (item) {
        case _NodeItem(:final id, :final size):
          _rects[id] = p & size;
        case _LaneItem(:final edge):
          _laneX[edge] = p.dx + DiagramMetrics.lane / 2;
        case _GroupItem(:final id, :final inner):
          const pad = DiagramMetrics.groupPad;
          _groupRects[id] = p & Size(inner.w + pad * 2, inner.h + pad * 2);
          _flatten(
            inner,
            p + const Offset(DiagramMetrics.groupPad, DiagramMetrics.groupPad),
          );
        case final _Block child:
          _flatten(child, p);
      }
    }
  }

  List<EdgeRoute> _route() {
    final routes = <EdgeRoute>[];
    const half = DiagramMetrics.vGap / 2;
    for (final (i, e) in d.edges.indexed) {
      final a = _rects[e.from];
      final b = _rects[e.to];
      if (a == null || b == null) continue;
      final from = _byId[e.from]!;
      final bottom = DiagramLayout.bottomOf(from, a);
      final lane = _laneX[i];
      final List<Offset> pts;
      var loop = false;
      if (_side.contains(i)) {
        final y = DiagramLayout.sideOf(from, a);
        final x = lane ?? b.center.dx;
        pts = [
          Offset(a.right, y),
          Offset(x, y),
          if (lane != null) ...[
            Offset(x, b.top - half),
            Offset(b.center.dx, b.top - half),
          ],
          Offset(b.center.dx, b.top),
        ];
      } else if (lane != null && b.top >= bottom) {
        pts = [
          Offset(a.center.dx, bottom),
          Offset(a.center.dx, bottom + half),
          Offset(lane, bottom + half),
          Offset(lane, b.top - half),
          Offset(b.center.dx, b.top - half),
          Offset(b.center.dx, b.top),
        ];
      } else if (!_back.contains(i) && b.top >= bottom) {
        if ((a.center.dx - b.center.dx).abs() < 0.5) {
          pts = [Offset(a.center.dx, bottom), Offset(b.center.dx, b.top)];
        } else {
          final fork = _dagOut(e.from).length > 1;
          final bend = fork ? bottom + half : b.top - half;
          pts = [
            Offset(a.center.dx, bottom),
            Offset(a.center.dx, bend),
            Offset(b.center.dx, bend),
            Offset(b.center.dx, b.top),
          ];
        }
      } else {
        // Back up (a repeat) or across: round the right side.
        loop = true;
        final x = math.max(a.right, b.right) + 10;
        final ya = DiagramLayout.sideOf(from, a);
        final yb = DiagramLayout.sideOf(_byId[e.to]!, b);
        pts = [
          Offset(a.right, ya),
          Offset(x, ya),
          Offset(x, yb),
          Offset(b.right, yb),
        ];
      }
      routes.add(
        EdgeRoute(
          index: i,
          edge: e,
          points: pts,
          labelAt: _labelAt(pts),
          plusAt: _plusAt(pts),
          loop: loop,
        ),
      );
    }
    return routes;
  }

  static Offset _labelAt(List<Offset> pts) {
    final a = pts.first;
    final b = pts[1];
    if (a.dy == b.dy) return Offset(a.dx + 8, a.dy - 16);
    return Offset(a.dx - 8, a.dy + 2);
  }

  /// The middle of the longest stretch going down near the end, or of the
  /// longest stretch at all.
  static Offset _plusAt(List<Offset> pts) {
    var best = 0;
    var bestLen = -1.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final len = (pts[i + 1] - pts[i]).distance;
      final down = pts[i].dx == pts[i + 1].dx;
      final score = len + (down ? 12 : 0) + i * 0.01;
      if (score > bestLen) {
        best = i;
        bestLen = score;
      }
    }
    return Offset.lerp(pts[best], pts[best + 1], 0.5)!;
  }
}
