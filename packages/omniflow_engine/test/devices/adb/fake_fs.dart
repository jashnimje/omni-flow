import 'dart:typed_data';

const sIfDir = 0x4000;
const sIfReg = 0x8000;
const sIfLnk = 0xa000;

/// One node of [FakeFs]: a file with bytes, a folder, or a link.
class FakeNode {
  FakeNode.file(List<int> bytes, {this.mode = sIfReg | 0x1a4, int? mtime})
    : bytes = Uint8List.fromList(bytes),
      target = null,
      mtime = mtime ?? 1700000000;

  FakeNode.dir({this.mode = sIfDir | 0x1f9, int? mtime})
    : bytes = null,
      target = null,
      mtime = mtime ?? 1700000000;

  FakeNode.link(this.target, {int? mtime})
    : bytes = null,
      mode = sIfLnk | 0x1ff,
      mtime = mtime ?? 1700000000;

  Uint8List? bytes;
  int mode;
  int mtime;
  final String? target;

  bool get isDir => mode & 0xf000 == sIfDir;
  bool get isLink => mode & 0xf000 == sIfLnk;
  int get size => bytes?.length ?? (isDir ? 4096 : (target?.length ?? 0));

  FakeNode copy() => isDir
      ? FakeNode.dir(mode: mode, mtime: mtime)
      : isLink
      ? FakeNode.link(target, mtime: mtime)
      : FakeNode.file(bytes!, mode: mode, mtime: mtime);
}

/// An in-memory file system with absolute paths, for the fake TV.
class FakeFs {
  FakeFs() {
    nodes['/'] = FakeNode.dir();
  }

  final nodes = <String, FakeNode>{};

  /// Names a hostile TV lists in a folder that no real folder holds, like
  /// `a/../../x`, by folder.
  final hostileNames = <String, List<String>>{};

  static String parentOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  static String join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  /// Follows a link in the last segment.
  String resolve(String path) {
    final node = nodes[path];
    return node != null && node.isLink ? node.target! : path;
  }

  void mkdirs(String path) {
    if (path == '/' || nodes[path]?.isDir == true) return;
    mkdirs(parentOf(path));
    nodes[path] = FakeNode.dir();
  }

  void writeFile(String path, List<int> bytes, {int? mode, int? mtime}) {
    mkdirs(parentOf(path));
    nodes[path] = FakeNode.file(
      bytes,
      mode: mode ?? sIfReg | 0x1a4,
      mtime: mtime,
    );
  }

  void link(String path, String target) {
    mkdirs(parentOf(path));
    nodes[path] = FakeNode.link(target);
  }

  /// The names directly in [dir], after following a link to it.
  List<String> children(String dir) {
    final real = resolve(dir);
    final prefix = real == '/' ? '/' : '$real/';
    return [
      for (final p in nodes.keys)
        if (p != real &&
            p.startsWith(prefix) &&
            !p.substring(prefix.length).contains('/'))
          p.substring(prefix.length),
    ]..sort();
  }

  Iterable<String> _subtree(String path) => nodes.keys
      .where((p) => p == path || p.startsWith(path == '/' ? '/' : '$path/'))
      .toList();

  void remove(String path) {
    for (final p in _subtree(path)) {
      nodes.remove(p);
    }
  }

  void copyTree(String from, String to) {
    for (final p in _subtree(from)) {
      nodes[to + p.substring(from.length)] = nodes[p]!.copy();
    }
  }

  void moveTree(String from, String to) {
    copyTree(from, to);
    for (final p in _subtree(from).toList()) {
      if (p == to || p.startsWith('$to/')) continue;
      nodes.remove(p);
    }
  }
}
