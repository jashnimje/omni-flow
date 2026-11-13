import 'dart:typed_data';

import 'adb_commands.dart';

/// The width and height in a PNG's IHDR chunk, or null when [bytes] is not
/// a PNG.
(int, int)? pngSize(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
  final data = ByteData.sublistView(bytes);
  final width = data.getUint32(16);
  final height = data.getUint32(20);
  return width == 0 || height == 0 ? null : (width, height);
}

final _sizeLine = RegExp(r'(Physical|Override) size: (\d+)x(\d+)');

/// The size `input` works in, from `wm size`: the override when one is set.
(int, int)? parseWmSize(String output) {
  (int, int)? physical;
  (int, int)? override;
  for (final m in _sizeLine.allMatches(output)) {
    final size = (int.parse(m.group(2)!), int.parse(m.group(3)!));
    if (m.group(1) == 'Override') {
      override = size;
    } else {
      physical = size;
    }
  }
  final size = override ?? physical;
  return size == null || size.$1 == 0 || size.$2 == 0 ? null : size;
}

/// The busy share of the CPU between two `cpu` lines of /proc/stat, in
/// percent with one decimal. Idle time includes waiting for I/O.
double? cpuPercent(String first, String second) {
  List<int>? times(String line) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length < 5 || words.first != 'cpu') return null;
    final values = [for (final w in words.skip(1)) int.tryParse(w)];
    return values.contains(null) ? null : values.cast<int>();
  }

  final a = times(first);
  final b = times(second);
  if (a == null || b == null || a.length != b.length) return null;
  int sum(List<int> v) => v.fold(0, (s, x) => s + x);
  int idle(List<int> v) => v[3] + (v.length > 4 ? v[4] : 0);
  final total = sum(b) - sum(a);
  if (total <= 0) return 0;
  final busy = total - (idle(b) - idle(a));
  return (busy * 1000 / total).round().clamp(0, 1000) / 10;
}

/// MemTotal and MemAvailable from /proc/meminfo, in KiB. An old kernel
/// without MemAvailable gets free plus buffers plus cache.
({int totalKb, int availableKb})? parseMeminfo(String text) {
  final values = <String, int>{};
  for (final m in RegExp(
    r'^(\w+):\s+(\d+)',
    multiLine: true,
  ).allMatches(text)) {
    values[m.group(1)!] = int.parse(m.group(2)!);
  }
  final total = values['MemTotal'];
  if (total == null) return null;
  final available =
      values['MemAvailable'] ??
      (values['MemFree'] ?? 0) +
          (values['Buffers'] ?? 0) +
          (values['Cached'] ?? 0);
  return (totalKb: total, availableKb: available);
}

typedef TvMount = ({String mount, int sizeKb, int usedKb, int availableKb});

/// The rows of `df -k`. A long file system name on its own line is joined
/// to the numbers on the next, and a mount listed twice is kept once.
List<TvMount> parseDf(String text) {
  final rows = <TvMount>[];
  String? carried;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('Filesystem')) continue;
    final words = line.split(RegExp(r'\s+'));
    if (words.length == 1) {
      carried = words.single;
      continue;
    }
    final all = carried == null ? words : [carried, ...words];
    carried = null;
    final numbers = [for (final w in all.skip(1).take(3)) int.tryParse(w)];
    final mount = all.last;
    if (numbers.length < 3 ||
        numbers.contains(null) ||
        !mount.startsWith('/')) {
      continue;
    }
    if (rows.any((r) => r.mount == mount)) continue;
    rows.add((
      mount: mount,
      sizeKb: numbers[0]!,
      usedKb: numbers[1]!,
      availableKb: numbers[2]!,
    ));
  }
  return rows;
}

/// Bytes received and sent over every interface but loopback, from
/// /proc/net/dev.
({int rxBytes, int txBytes}) parseNetDev(String text) {
  var rx = 0;
  var tx = 0;
  for (final line in text.split('\n')) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final name = line.substring(0, colon).trim();
    if (name.isEmpty || name == 'lo' || name.contains(' ')) continue;
    final fields = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
    if (fields.length < 9) continue;
    rx += int.tryParse(fields[0]) ?? 0;
    tx += int.tryParse(fields[8]) ?? 0;
  }
  return (rxBytes: rx, txBytes: tx);
}

/// Whole seconds since boot, from /proc/uptime.
int? parseUptime(String text) {
  final first = text.trim().split(RegExp(r'\s+')).first;
  return double.tryParse(first)?.floor();
}

/// The hottest thermal zone in degrees C with one decimal. Zones report
/// millidegrees, a few report degrees, and a value outside what a TV can
/// reach is a zone that is not a temperature.
double? parseThermal(String text) {
  double? hottest;
  for (final line in text.split('\n')) {
    final n = int.tryParse(line.trim());
    if (n == null) continue;
    final c = n.abs() >= 1000 ? n / 1000 : n.toDouble();
    if (c <= 0 || c > 150) continue;
    if (hottest == null || c > hottest) hottest = c;
  }
  return hottest == null ? null : (hottest * 10).round() / 10;
}

typedef TvProcess = ({String package, int pid, int memoryKb});

/// App processes from `ps -A -o PID,RSS,NAME`, largest first. A process
/// such as `com.app:remote` belongs to its package. Kernel threads and
/// native daemons have no package name, so they are left out.
List<TvProcess> parsePs(String text) {
  final out = <TvProcess>[];
  for (final line in text.split('\n')) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length < 3) continue;
    final pid = int.tryParse(words[0]);
    final rss = int.tryParse(words[1]);
    final name = words.sublist(2).join(' ');
    if (pid == null || rss == null) continue;
    if (name.startsWith('/') || name.startsWith('[')) continue;
    final package = name.split(':').first;
    if (!package.contains('.') || !adbPackagePattern.hasMatch(package)) {
      continue;
    }
    out.add((package: package, pid: pid, memoryKb: rss));
  }
  out.sort((a, b) {
    final byMemory = b.memoryKb.compareTo(a.memoryKb);
    return byMemory != 0 ? byMemory : a.pid.compareTo(b.pid);
  });
  return out;
}

final _permissionLine = RegExp(r'^\s+([A-Za-z0-9_.]+): granted=(true|false)');

/// The permissions in `dumpsys package` output, with whether each is
/// granted and whether it is a runtime one. Install permissions are
/// granted when the app is installed and cannot be changed.
List<({String name, bool granted, bool runtime})> parsePermissions(
  String text,
) {
  final found = <String, ({String name, bool granted, bool runtime})>{};
  var runtime = false;
  var inSection = false;
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.endsWith('permissions:')) {
      inSection =
          trimmed == 'install permissions:' ||
          trimmed == 'runtime permissions:';
      runtime = trimmed == 'runtime permissions:';
      continue;
    }
    if (!inSection) continue;
    final m = _permissionLine.firstMatch(line);
    if (m == null) {
      if (trimmed.isNotEmpty && !trimmed.contains('granted=')) {
        inSection = false;
      }
      continue;
    }
    final name = m.group(1)!;
    final previous = found[name];
    if (previous != null && previous.runtime && !runtime) continue;
    found[name] = (name: name, granted: m.group(2) == 'true', runtime: runtime);
  }
  return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// The APK paths `pm path` printed.
List<String> parsePmPath(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().startsWith('package:'))
      line.trim().substring('package:'.length),
];

/// The local file name for an APK of [package]: the base APK as
/// `<package>.apk`, a split as `<package>-<split>.apk`.
String apkBackupName(String package, String remote) {
  final base = remote.substring(remote.lastIndexOf('/') + 1);
  final stem = base.toLowerCase().endsWith('.apk')
      ? base.substring(0, base.length - 4)
      : base;
  if (stem == 'base') return '$package.apk';
  final split = stem.startsWith('split_') ? stem.substring(6) : stem;
  final safe = split.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
  return '$package-$safe.apk';
}
