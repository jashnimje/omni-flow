import 'dart:convert';
import 'dart:io';

import 'fake_adbd.dart';

/// One app on the fake TV.
class FakeApp {
  FakeApp(
    this.package, {
    this.versionName = '1.0',
    this.versionCode = 1,
    this.system = false,
    this.enabled = 0,
    this.leanback = true,
    this.launcher = false,
    this.apkSizes = const [1000],
    this.updatedSystemApp = false,
    this.label,
  });

  final String package;
  String versionName;
  int versionCode;
  bool system;

  /// The `enabled=` of `User 0:`: 0 default, 1 enabled, 2-4 disabled.
  int enabled;
  bool leanback;
  bool launcher;
  List<int> apkSizes;
  bool updatedSystemApp;

  /// A label written as text in the manifest, which the full launcher
  /// query prints. Null is a resource label, printed as null.
  String? label;
  var installed = true;
  var dataCleared = 0;
  var cacheCleared = 0;

  /// What `pm path` lists. The bytes are what [FakeAdbd.fs] holds there.
  List<String> apkPaths = const [];
  List<String> installPermissions = const [];
  final runtimePermissions = <String, bool>{};
}

/// A real, small RGB PNG of [width] by [height].
List<int> fakePng(int width, int height) {
  List<int> be32(int v) => [
    (v >> 24) & 0xff,
    (v >> 16) & 0xff,
    (v >> 8) & 0xff,
    v & 0xff,
  ];
  int crc32(List<int> bytes) {
    var c = 0xffffffff;
    for (final b in bytes) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (c >> 1) ^ 0xedb88320 : c >> 1;
      }
    }
    return c ^ 0xffffffff;
  }

  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    return [...be32(data.length), ...body, ...be32(crc32(body))];
  }

  final raw = <int>[
    for (var y = 0; y < height; y++) ...[
      0,
      for (var x = 0; x < width; x++) ...[(x * 8) & 0xff, (y * 8) & 0xff, 0x0a],
    ],
  ];
  return [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
    ...chunk('IHDR', [...be32(width), ...be32(height), 8, 2, 0, 0, 0]),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', const []),
  ];
}

/// Splits a POSIX shell line into words, honouring single and double
/// quotes and backslashes, the way /system/bin/sh reads what the engine
/// builds. Unquoted `;`, `|` and `&` are kept as their own words.
List<String> shellWords(String line) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == "'") {
      final end = line.indexOf("'", i + 1);
      if (end < 0) throw StateError('unterminated quote in $line');
      word.write(line.substring(i + 1, end));
      inWord = true;
      i = end;
    } else if (c == '"') {
      final end = line.indexOf('"', i + 1);
      if (end < 0) throw StateError('unterminated quote in $line');
      word.write(line.substring(i + 1, end));
      inWord = true;
      i = end;
    } else if (c == r'\' && i + 1 < line.length) {
      word.write(line[++i]);
      inWord = true;
    } else if (c == ' ' || c == '\t') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
    } else if (c == ';' || c == '|' || c == '&') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
      words.add(c);
    } else {
      word.write(c);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}

/// The TV behind [FakeAdbd]: it answers the shell lines the engine builds
/// for state, keys, text, volume, apps, settings and files, and keeps what
/// they changed. Anything else prints "not found" and exits 127.
class FakeTv {
  FakeTv(this.adbd) {
    adbd
      ..respond = respond
      ..respondExec = _exec
      ..dropsConnection = (script) =>
          rebootDrops &&
          script.split('\n').any((l) => l == 'reboot' || l == 'reboot -p');
  }

  List<int> _exec(String line) =>
      line == 'screencap -p' ? screencap : utf8.encode(respond(line));

  final FakeAdbd adbd;

  FakeFs get fs => adbd.fs;

  var serial = 'FAKE0123456789';
  var wakefulness = 'Awake';
  String? focus =
      'com.google.android.youtube.tv/'
      'com.google.android.apps.youtube.tv.activity.MainActivity';
  var volume = 30;
  var volumeMax = 100;
  var muted = false;

  /// When true, `--set` is ignored, so the engine has to press keys.
  var volumeSetIgnored = false;

  /// Media sessions as (package, active, PlaybackState name).
  var sessions = <(String, bool, String)>[
    ('com.google.android.youtube.tv', true, 'PLAYING(3)'),
    ('com.netflix.ninja', false, 'STOPPED(1)'),
  ];

  final settings = <String, Map<String, String>>{
    'system': {'screen_off_timeout': '600000', 'time_12_24': '24'},
    'secure': {'sleep_timeout': '1139000', 'screensaver_enabled': '1'},
    'global': {
      'animator_duration_scale': '0.5',
      'bluetooth_on': '1',
      'adb_enabled': '1',
      'private_dns_mode': 'hostname',
      'multi_line': 'first',
    },
  };

  final apps = <String, FakeApp>{};
  final keys = <List<String>>[];
  final typed = <String>[];
  final launched = <String>[];
  final stopped = <String>[];
  final installs = <(List<String>, int)>[];
  final shellLines = <String>[];
  var cwd = '/';

  /// What `exec:screencap -p` writes.
  List<int> screencap = fakePng(32, 18);
  var physicalSize = '1920x1080';
  String? overrideSize;
  var wmSizeReads = 0;
  final touches = <List<String>>[];

  /// The `cpu` lines of /proc/stat, one per read.
  var cpuSamples = [
    'cpu  1000 0 1000 8000 0 0 0 0 0 0',
    'cpu  1300 0 1200 8400 100 0 0 0 0 0',
  ];
  var meminfo =
      'MemTotal:        2000000 kB\nMemFree:          100000 kB\n'
      'MemAvailable:     800000 kB\nBuffers:           10000 kB\n';
  var dataFreeKb = 4000000;
  var netDev =
      'Inter-|   Receive                            |  Transmit\n'
      ' face |bytes    packets errs drop fifo frame compressed multicast|'
      'bytes    packets errs drop fifo colls carrier compressed\n'
      '    lo:  5000 50 0 0 0 0 0 0  5000 50 0 0 0 0 0 0\n'
      '  eth0: 1000000 900 0 0 0 0 0 0 200000 500 0 0 0 0 0 0\n'
      ' wlan0: 30000 30 0 0 0 0 0 0 4000 40 0 0 0 0 0 0\n';
  var uptime = '12345.67 40000.12\n';
  String? thermal = '41000\n52500\n-1\n';
  var ps =
      '  PID   RSS NAME\n'
      '    1  9000 init\n'
      '    2     0 [kthreadd]\n'
      '  410 20000 /system/bin/surfaceflinger\n'
      ' 1200 150000 com.google.android.youtube.tv\n'
      ' 1300  90000 com.netflix.ninja\n'
      ' 1301  30000 com.netflix.ninja:remote\n'
      ' 1400   5000 system_server_helper\n';

  var hasScreenrecord = true;

  /// False for a TV with no encoder screenrecord can use: it exits at once.
  var encoderWorks = true;
  var recording = false;
  final recordCommands = <List<String>>[];
  var trims = 0;
  final powerCommands = <String>[];

  /// Whether `reboot` takes the connection down before it answers.
  var rebootDrops = true;

  String respond(String script) {
    final out = StringBuffer();
    var status = 0;
    for (final line in script.split('\n')) {
      final exitMarker = RegExp(
        r'^echo "(@@omniflow-exit-[0-9a-f]+:)\$\?(:\$PWD)?"$',
      ).firstMatch(line);
      if (exitMarker != null) {
        out.writeln(
          '${exitMarker.group(1)}$status'
          '${exitMarker.group(2) == null ? '' : ':$cwd'}',
        );
        continue;
      }
      if (line.startsWith('cd ')) {
        final target = shellWords(line)[1];
        if (fs.nodes[target]?.isDir == true) {
          cwd = target;
          status = 0;
        } else {
          return '${out}sh: cd: $target: No such file or directory\n';
        }
        continue;
      }
      final (output, code, exits) = _line(line);
      out.write(output);
      status = code;
      if (exits) return out.toString();
    }
    return out.toString();
  }

  (String, int, bool) _line(String line) {
    final sections = RegExp(r"(?:echo; )?echo '@@omniflow-section:(\w+)'; ")
        .allMatches(line)
        .toList();
    if (sections.isNotEmpty) {
      final out = StringBuffer();
      for (var i = 0; i < sections.length; i++) {
        final start = sections[i].end;
        final end = i + 1 < sections.length
            ? sections[i + 1].start
            : line.length;
        var command = line.substring(start, end).trim();
        if (command.endsWith(';')) {
          command = command.substring(0, command.length - 1);
        }
        out
          ..writeln()
          ..writeln('@@omniflow-section:${sections[i].group(1)}')
          ..write(_command(command).$1);
      }
      return (out.toString(), 0, false);
    }
    final (output, code) = _command(line);
    return (output, code, line.startsWith('exit '));
  }

  (String, int) _command(String line) {
    shellLines.add(line);
    if (line.startsWith('exit ')) return ('', int.parse(line.substring(5)));
    if (line == 'true') return ('', 0);
    if (line == 'echo') return ('\n', 0);
    if (line == 'false') return ('', 1);
    if (line == 'pwd') return ('$cwd\n', 0);
    if (line.startsWith('echo ')) {
      return ('${shellWords(line).skip(1).join(' ')}\n', 0);
    }
    if (line.startsWith('dumpsys power')) {
      return ('  mWakefulness=$wakefulness\n', 0);
    }
    if (line.startsWith('dumpsys window')) {
      return focus == null
          ? ('  mCurrentFocus=null\n', 0)
          : (
              '  mCurrentFocus=Window{203e46e u0 $focus}\n'
                  '  mFocusedApp=ActivityRecord{df4e625 u0 $focus t1910}\n',
              0,
            );
    }
    if (line.startsWith('dumpsys audio')) {
      return (
        '- STREAM_MUSIC:\n   Muted: $muted\n   Muted Internally: false\n',
        0,
      );
    }
    if (line.startsWith('dumpsys media_session')) {
      return (
        [
          for (final (p, active, state) in sessions)
            '      package=$p\n      active=$active\n'
                '      state=PlaybackState {state=$state, position=0}\n',
        ].join(),
        0,
      );
    }
    if (line.startsWith('dumpsys package packages')) return (_packages(), 0);
    if (line.startsWith('cmd package query-activities')) {
      return line.contains('--brief')
          ? (_activities(line.contains('LEANBACK')), 0)
          : (_labels(line), 0);
    }
    if (line.startsWith('c=\$(cmd package resolve-activity')) {
      final words = shellWords(line);
      final package =
          words[words.indexOf('android.intent.category.LEANBACK_LAUNCHER') + 1];
      final app = apps[package];
      if (app == null || !app.installed || !(app.leanback || app.launcher)) {
        return ('** No activities found to run, monkey aborted.\n', 0);
      }
      launched.add(package);
      return ('Starting: Intent { cmp=$package/.Main }\n', 0);
    }
    final words = shellWords(line);
    if (words.isEmpty) return ('', 0);
    return switch (words.first) {
      'getprop' => ('$serial\n', 0),
      'input' => _input(words),
      'cmd' => _cmd(words, line),
      'settings' => _settings(words),
      'am' when words[1] == 'force-stop' => () {
        stopped.add(words[2]);
        return ('', 0);
      }(),
      'pm' => _pm(words),
      'dumpsys' when words[1] == 'package' => _dumpsysPackage(words[2], line),
      'for' => _sizes(words),
      'rm' => _rm(words),
      'mkdir' => _mkdir(words),
      'cp' || 'mv' => _cpMv(words),
      'wm' when words[1] == 'size' => () {
        wmSizeReads++;
        return (
          'Physical size: $physicalSize\n'
              '${overrideSize == null ? '' : 'Override size: $overrideSize\n'}',
          0,
        );
      }(),
      'head' when line.contains('/proc/stat') => (
        '${cpuSamples.join('\n')}\n',
        0,
      ),
      'cat' => _cat(words[1]),
      'df' => _df(words.skip(2)),
      'ps' => (ps, 0),
      'command' when words[1] == '-v' =>
        words[2] == 'screenrecord' && hasScreenrecord
            ? ('/system/bin/screenrecord\n', 0)
            : ('', 1),
      'nohup' => _nohup(words),
      'sleep' => ('', 0),
      'pidof' =>
        words[1] == 'screenrecord' && recording ? ('4321\n', 0) : ('', 1),
      'pkill' => _pkill(words),
      'reboot' => () {
        powerCommands.add(line);
        return ('', 0);
      }(),
      _ => ('sh: ${words.first}: not found\n', 127),
    };
  }

  (String, int) _cat(String path) => switch (path) {
    '/proc/meminfo' => (meminfo, 0),
    '/proc/net/dev' => (netDev, 0),
    '/proc/uptime' => (uptime, 0),
    '/sys/class/thermal/thermal_zone*/temp' => (thermal ?? '', 0),
    _ => ('cat: $path: No such file or directory\n', 1),
  };

  (String, int) _df(Iterable<String> paths) {
    const size = 12000000;
    final used = size - dataFreeKb;
    final out = StringBuffer(
      'Filesystem      1K-blocks    Used Available Use% Mounted on\n',
    );
    for (final p in paths) {
      final (fs, mount) = p == '/data'
          ? ('/dev/block/dm-5', '/data')
          : ('/dev/fuse', '/storage/emulated');
      out.writeln('$fs $size $used $dataFreeKb 50% $mount');
    }
    return (out.toString(), 0);
  }

  (String, int) _nohup(List<String> words) {
    if (words[1] != 'screenrecord') return ('nohup: not found\n', 127);
    if (!hasScreenrecord) return ('nohup: screenrecord: not found\n', 127);
    final args = words.takeWhile((w) => !w.startsWith('>')).toList();
    recordCommands.add(args.sublist(1));
    if (encoderWorks) {
      recording = true;
      fs.writeFile(args.last, const []);
    }
    return ('', 0);
  }

  (String, int) _pkill(List<String> words) {
    if (words.last != 'screenrecord' || !recording) return ('', 1);
    recording = false;
    final file = recordCommands.last.last;
    fs.writeFile(file, List.filled(4096, 7));
    return ('', 0);
  }

  (String, int) _input(List<String> words) {
    if (words[1] == 'tap' || words[1] == 'swipe') {
      touches.add(words.skip(1).toList());
      return ('', 0);
    }
    if (words[1] == 'keyevent') {
      keys.add(words.skip(2).toList());
      return ('', 0);
    }
    if (words[1] == 'text') {
      typed.add(words[2]);
      return ('', 0);
    }
    return ('usage', 1);
  }

  (String, int) _cmd(List<String> words, String line) {
    if (words[1] == 'media_session' && words[2] == 'volume') {
      final head = '[V] will control stream=3 (STREAM_MUSIC)\n';
      if (words.contains('--set')) {
        final n = int.parse(words[words.indexOf('--set') + 1]);
        if (!volumeSetIgnored) volume = n.clamp(0, volumeMax);
        return ('$head[V] will set volume to index=$n\n', 0);
      }
      return ('$head[V] volume is $volume in range [0..$volumeMax]\n', 0);
    }
    if (words[1] == 'package' && words[2] == 'resolve-activity') {
      return _dumpsysPackage(words.last, line);
    }
    if (words[1] == 'bluetooth_manager') {
      settings['global']!['bluetooth_on'] = words[2] == 'enable' ? '1' : '0';
      return ('', 0);
    }
    return ('Unknown command: $line\n', 1);
  }

  (String, int) _settings(List<String> words) {
    final ns = settings[words[2]];
    if (ns == null) return ('Invalid namespace\n', 1);
    switch (words[1]) {
      case 'list':
        return (
          [for (final e in ns.entries) '${e.key}=${e.value}\n'].join() +
              (words[2] == 'global' ? 'continued line\n' : ''),
          0,
        );
      case 'get':
        return ('${ns[words[3]] ?? 'null'}\n', 0);
      case 'put':
        ns[words[3]] = words[4];
        return ('', 0);
      case 'delete':
        return ('Deleted ${ns.remove(words[3]) == null ? 0 : 1} rows\n', 0);
    }
    return ('usage\n', 1);
  }

  String _block(FakeApp a) =>
      '  Package [${a.package}] (1a2b3c):\n'
      '    codePath=/data/app/~~x==/${a.package}-y==\n'
      '    dataDir=/data/user/0/${a.package}\n'
      '    versionCode=${a.versionCode} minSdk=24 targetSdk=34\n'
      '    versionName=${a.versionName}\n'
      '    pkgFlags=[ ${a.system ? 'SYSTEM ' : ''}HAS_CODE '
      '${a.updatedSystemApp ? 'UPDATED_SYSTEM_APP ' : ''}]\n'
      '    lastUpdateTime=2026-10-31 22:40:09\n'
      '    User 0: ceDataInode=1 installed=${a.installed} hidden=false '
      'suspended=false distractionFlags=0 stopped=false notLaunched=false '
      'enabled=${a.enabled} instant=false virtual=false\n'
      '      firstInstallTime=2009-01-01 05:30:00\n'
      '${a.installPermissions.isEmpty ? '' : '      install permissions:\n'}'
      '${[for (final p in a.installPermissions) '        $p: granted=true\n'].join()}'
      '${a.runtimePermissions.isEmpty ? '' : '      runtime permissions:\n'}'
      '${[for (final e in a.runtimePermissions.entries) '        ${e.key}: granted=${e.value}, flags=[ USER_SENSITIVE_WHEN_GRANTED ]\n'].join()}';

  String _hidden(FakeApp a) =>
      '  Package [${a.package}] (9f9f9f):\n'
      '    versionCode=1 minSdk=24 targetSdk=30\n'
      '    versionName=0.0.1-factory\n'
      '    pkgFlags=[ SYSTEM HAS_CODE ]\n'
      '    User 0: ceDataInode=0 installed=true hidden=false enabled=0\n';

  String _packages() {
    final lines = StringBuffer('Packages:\n');
    for (final a in apps.values) {
      for (final l in _block(a).split('\n')) {
        if (RegExp(
          r'^(  Package \[|    versionName=|    versionCode=|    pkgFlags=|'
          r'    User 0:)',
        ).hasMatch(l)) {
          lines.writeln(l);
        }
      }
    }
    lines.writeln('Hidden system packages:');
    for (final a in apps.values.where((a) => a.updatedSystemApp)) {
      lines.write(_hidden(a));
    }
    return lines.toString();
  }

  String _activities(bool leanback) {
    final list = [
      for (final a in apps.values)
        if (a.installed && (leanback ? a.leanback : a.launcher)) a.package,
    ];
    final out = StringBuffer('${list.length} activities found:\n');
    for (var i = 0; i < list.length; i++) {
      out
        ..writeln('  Activity #$i:')
        ..writeln('    priority=0 preferredOrder=0 match=0x108000')
        ..writeln('    ${list[i]}/.MainActivity');
    }
    return out.toString();
  }

  /// The `packageName=` and `nonLocalizedLabel=` lines of a full launcher
  /// query, as the grep after it keeps them.
  String _labels(String line) {
    final leanback = line.contains('category.LEANBACK_LAUNCHER');
    final launcher = line.contains('category.LAUNCHER');
    final out = StringBuffer();
    for (final a in apps.values) {
      if (!a.installed ||
          !((leanback && a.leanback) || (launcher && a.launcher))) {
        continue;
      }
      out
        ..writeln('      packageName=${a.package}')
        ..writeln(
          '      labelRes=0x7f0f0019 nonLocalizedLabel=${a.label ?? 'null'} '
          'icon=0x0 banner=0x0',
        );
    }
    return out.toString();
  }

  (String, int) _dumpsysPackage(String package, String line) {
    final app = apps[package];
    if (line.contains('resolve-activity')) {
      final leanback = line.contains('LEANBACK');
      if (app == null || !(leanback ? app.leanback : app.launcher)) {
        return ('No activity found\n', 0);
      }
      return ('priority=0 preferredOrder=0\n$package/.MainActivity\n', 0);
    }
    if (app == null) return ('Unable to find package: $package\n', 0);
    if (line.contains('grep -m 1')) {
      return (
        _block(app).split('\n').firstWhere((l) => l.startsWith('    User 0:')),
        0,
      );
    }
    return (
      'Activity Resolver Table:\n  Non-Data Actions:\n\nPackages:\n'
          '${_block(app)}\nHidden system packages:\n'
          '${app.updatedSystemApp ? _hidden(app) : ''}',
      0,
    );
  }

  /// `for f in $(pm path P | sed ...); do stat -c %s "$f"; done`.
  (String, int) _sizes(List<String> words) {
    final package = words.firstWhere(
      (w) => apps.containsKey(w),
      orElse: () => '',
    );
    final app = apps[package];
    return (app == null ? '' : '${app.apkSizes.join('\n')}\n', 0);
  }

  (String, int) _pm(List<String> words) {
    if (words[1] == 'install') {
      final path = words.last;
      final node = fs.nodes[path];
      if (node == null) return ('Failure [INSTALL_FAILED_INVALID_URI]\n', 1);
      installs.add((words.sublist(2, words.length - 1), node.size));
      apps['com.example.installed'] = FakeApp('com.example.installed');
      return ('Performing Streamed Install\nSuccess\n', 0);
    }
    if (words[1] == 'trim-caches') {
      trims++;
      dataFreeKb += 5000;
      return ('', 0);
    }
    if (words[1] == 'path') {
      final app = apps[words[2]];
      if (app == null || !app.installed) return ('', 1);
      return ([for (final p in app.apkPaths) 'package:$p\n'].join(), 0);
    }
    if (words[1] == 'grant' || words[1] == 'revoke') {
      final (package, permission) = (words[2], words[3]);
      final app = apps[package];
      final head = "Exception occurred while executing '${words[1]}':\n";
      if (app == null) {
        return (
          '${head}java.lang.IllegalArgumentException: Unknown package: '
              '$package\n',
          255,
        );
      }
      if (!app.runtimePermissions.containsKey(permission)) {
        return (
          '${head}java.lang.SecurityException: Package $package has not '
              'requested permission $permission\n',
          255,
        );
      }
      app.runtimePermissions[permission] = words[1] == 'grant';
      return ('', 0);
    }
    final package = words.last;
    final app = apps[package];
    if (app == null) {
      return ('Error: Unknown package: $package\n', 1);
    }
    switch (words[1]) {
      case 'clear':
        if (words.contains('--cache-only')) {
          app.cacheCleared++;
        } else {
          app.dataCleared++;
        }
        return ('Success\n', 0);
      case 'disable-user':
        app.enabled = 3;
        return ('Package $package new state: disabled-user\n', 0);
      case 'enable':
        app.enabled = 1;
        return ('Package $package new state: enabled\n', 0);
      case 'uninstall':
        if (app.system && !words.contains('--user')) {
          return ('Failure [DELETE_FAILED_INTERNAL_ERROR]\n', 1);
        }
        app.installed = false;
        return ('Success\n', 0);
    }
    return ('Unknown command\n', 1);
  }

  List<String> _operands(List<String> words) {
    final dash = words.indexOf('--');
    return dash < 0
        ? words.skip(1).where((w) => !w.startsWith('-')).toList()
        : words.sublist(dash + 1);
  }

  (String, int) _rm(List<String> words) {
    if (words.contains('-f') && !words.contains('--')) {
      fs.remove(words.last);
      return ('', 0);
    }
    final recursive = words.contains('-r');
    for (final p in _operands(words)) {
      final node = fs.nodes[p];
      if (node == null) return ('rm: $p: No such file or directory\n', 1);
      if (node.isDir && !recursive) return ('rm: $p: Is a directory\n', 1);
      fs.remove(p);
    }
    return ('', 0);
  }

  (String, int) _mkdir(List<String> words) {
    for (final p in _operands(words)) {
      fs.mkdirs(p);
    }
    return ('', 0);
  }

  (String, int) _cpMv(List<String> words) {
    final operands = _operands(words);
    final (from, to) = (operands[0], operands[1]);
    final node = fs.nodes[from];
    if (node == null) return ('${words.first}: $from: No such file\n', 1);
    if (node.isDir && words.first == 'cp' && !words.contains('-R')) {
      return ('cp: $from: Is a directory\n', 1);
    }
    if (words.first == 'cp') {
      fs.copyTree(from, to);
    } else {
      fs.moveTree(from, to);
    }
    return ('', 0);
  }
}
