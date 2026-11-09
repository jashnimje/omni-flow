import 'adb_commands.dart';

/// Starts each section of a combined shell run, so one round trip reads
/// several things. Device output does not print it.
const tvSectionMarker = '@@omniflow-section:';

/// One shell line that prints each of [commands] under its name.
String tvSections(Map<String, String> commands) => [
  for (final MapEntry(:key, :value) in commands.entries)
    "echo; echo '$tvSectionMarker$key'; $value",
].join('; ');

/// The output of [tvSections], by name.
Map<String, String> splitTvSections(String output) {
  final out = <String, String>{};
  String? current;
  final buffer = StringBuffer();
  void flush() {
    if (current != null) out[current] = buffer.toString();
    buffer.clear();
  }

  for (final line in output.split('\n')) {
    final trimmed = line.trimRight();
    if (trimmed.startsWith(tvSectionMarker)) {
      flush();
      current = trimmed.substring(tvSectionMarker.length);
    } else if (current != null) {
      buffer.writeln(trimmed);
    }
  }
  flush();
  return out;
}

/// The reads behind `tv.state`, as [tvSections] runs them.
final Map<String, String> tvStateCommands = {
  'power': "dumpsys power | grep -E 'mWakefulness='",
  'focus': "dumpsys window | grep -E 'mCurrentFocus=|mFocusedApp='",
  'volume': TvShell.volumeGet(),
  'audio': "dumpsys audio | grep -A2 -E '^- STREAM_MUSIC:'",
  'media':
      "dumpsys media_session | grep -E 'package=|active=|state=PlaybackState'",
};

final _wakefulness = RegExp(r'mWakefulness=(\w+)');
final _window = RegExp(r'u\d+ ([A-Za-z][\w.]*)/([\w.$]+)');
final _volume = RegExp(r'volume is (\d+) in range \[(\d+)\.\.(\d+)\]');
final _muted = RegExp(r'Muted: (true|false)');
final _playbackState = RegExp(r'state=PlaybackState \{state=(\w+)');

/// What [tvStateCommands] printed, as the `tv.state` result.
Map<String, Object?> parseTvState(Map<String, String> sections) {
  final wakefulness = _wakefulness.firstMatch(sections['power'] ?? '');
  final power = switch (wakefulness?.group(1)) {
    'Awake' || 'Dreaming' => 'on',
    'Asleep' || 'Dozing' => 'asleep',
    _ => null,
  };
  String? app;
  String? activity;
  final focus = sections['focus'] ?? '';
  for (final prefix in ['mCurrentFocus=', 'mFocusedApp=']) {
    final line = focus
        .split('\n')
        .where((l) => l.trim().startsWith(prefix))
        .firstOrNull;
    final match = line == null ? null : _window.firstMatch(line);
    if (match != null && adbPackagePattern.hasMatch(match.group(1)!)) {
      app = match.group(1);
      final name = match.group(2)!;
      activity = '$app/${name.startsWith('.') ? '$app$name' : name}';
      break;
    }
  }
  final volume = _volume.firstMatch(sections['volume'] ?? '');
  final muted = _muted.firstMatch(sections['audio'] ?? '');
  return {
    'power': power ?? 'on',
    'app': app,
    'activity': activity,
    'playing': _playing(sections['media'] ?? ''),
    'volume': volume == null ? null : int.parse(volume.group(1)!),
    'volumeMax': volume == null ? null : int.parse(volume.group(3)!),
    if (muted != null) 'muted': muted.group(1) == 'true',
  };
}

/// The playback state of the active media session, or null when none is
/// active.
String? _playing(String media) {
  var active = false;
  for (final line in media.split('\n').map((l) => l.trim())) {
    if (line.startsWith('package=')) {
      active = false;
    } else if (line.startsWith('active=')) {
      active = line == 'active=true';
    } else if (active) {
      final state = _playbackState.firstMatch(line)?.group(1);
      if (state == null) continue;
      return switch (state) {
        'PLAYING' ||
        'BUFFERING' ||
        'FAST_FORWARDING' ||
        'REWINDING' => 'playing',
        'PAUSED' => 'paused',
        'STOPPED' || 'NONE' || 'ERROR' => 'stopped',
        _ => null,
      };
    }
  }
  return null;
}

/// The reads behind `tv.apps`: every package with its version, flags and
/// state for user 0, and the activities the TV and phone launchers list.
final Map<String, String> tvAppsCommands = {
  'packages':
      "dumpsys package packages | grep -E '^Hidden system packages|"
      r"^  Package \[|^    versionName=|^    versionCode=|^    pkgFlags=|"
      "^    User 0:'",
  'leanback':
      'cmd package query-activities --brief -a android.intent.action.MAIN '
      '-c android.intent.category.LEANBACK_LAUNCHER',
  'launcher':
      'cmd package query-activities --brief -a android.intent.action.MAIN '
      '-c android.intent.category.LAUNCHER',
};

/// Names for apps the package name does not make plain.
const _knownLabels = {
  'com.netflix.ninja': 'Netflix',
  'com.google.android.youtube.tv': 'YouTube',
  'com.google.android.youtube.tvmusic': 'YouTube Music',
  'com.google.android.youtube.tvkids': 'YouTube Kids',
  'com.amazon.amazonvideo.livingroom': 'Prime Video',
  'com.graymatrix.did': 'ZEE5',
  'in.startv.hotstar': 'JioHotstar',
  'com.sonyliv': 'Sony LIV',
  'com.jio.media.jiotvplus': 'JioTV+',
  'com.mxtech.videoplayer.television': 'MX Player',
  'com.shemaroo.shemarootv': 'ShemarooMe',
  'com.spotify.tv.android': 'Spotify',
  'com.disney.disneyplus': 'Disney+',
  'com.android.vending': 'Google Play Store',
  'com.android.tv.settings': 'Settings',
  'com.google.android.apps.tv.launcherx': 'Google TV Home',
  'com.google.android.katniss': 'Google Assistant',
  'com.google.android.videos': 'Google TV',
  'com.google.android.play.games': 'Google Play Games',
};

final _packageLine = RegExp(r'^  Package \[([^\]]+)\]');
final _versionName = RegExp(r'^    versionName=(.*)$');
final _versionCode = RegExp(r'^    versionCode=(\d+)');
final _userState = RegExp(r'installed=(true|false).*?enabled=(\d)');
final _component = RegExp(r'^\s+([A-Za-z][\w.]*)/\S+$');

/// The packages that list an activity in [output] of
/// `cmd package query-activities --brief`.
Set<String> parseLaunchable(String output) => {
  for (final line in output.split('\n'))
    if (_component.firstMatch(line) case final m?) m.group(1)!,
};

/// What [tvAppsCommands] printed, as app entries. Packages not installed
/// for user 0 are left out, and a package's first entry wins, so an updated
/// system app reports its update and not the factory copy.
List<Map<String, Object?>> parseTvApps(Map<String, String> sections) {
  final launchable = {
    ...parseLaunchable(sections['leanback'] ?? ''),
    ...parseLaunchable(sections['launcher'] ?? ''),
  };
  final apps = <String, Map<String, Object?>>{};
  Map<String, Object?>? current;
  for (final line in (sections['packages'] ?? '').split('\n')) {
    if (line.startsWith('Hidden system packages')) break;
    final package = _packageLine.firstMatch(line)?.group(1);
    if (package != null) {
      current = apps.containsKey(package)
          ? null
          : (apps[package] = {
              'package': package,
              'label': ?_knownLabels[package],
              'versionName': null,
              'versionCode': null,
              'system': false,
              'enabled': true,
              'launchable': launchable.contains(package),
              'installed': true,
            });
      continue;
    }
    final app = current;
    if (app == null) continue;
    if (_versionName.firstMatch(line) case final m?) {
      app['versionName'] = m.group(1)!.trim();
    } else if (_versionCode.firstMatch(line) case final m?) {
      app['versionCode'] = int.parse(m.group(1)!);
    } else if (line.startsWith('    pkgFlags=')) {
      app['system'] = RegExp(r'\bSYSTEM\b').hasMatch(line);
    } else if (line.startsWith('    User 0:')) {
      final m = _userState.firstMatch(line);
      if (m != null) {
        app['installed'] = m.group(1) == 'true';
        // 0 is the manifest default, 1 enabled; 2, 3 and 4 are disabled.
        app['enabled'] = int.parse(m.group(2)!) < 2;
      }
    }
  }
  return [
    for (final a in apps.values)
      if (a['installed'] == true) ({...a}..remove('installed')),
  ]..sort((a, b) => _sortName(a).compareTo(_sortName(b)));
}

String _sortName(Map<String, Object?> app) =>
    ((app['label'] ?? app['package']) as String).toLowerCase();

/// The details `tv.app info` adds, from `dumpsys package <package>`: the
/// first package block, which is the installed copy.
Map<String, Object?> parseTvAppInfo(String dumpsys) {
  final out = <String, Object?>{};
  var inPackages = false;
  var inBlock = false;
  for (final line in dumpsys.split('\n')) {
    if (line.startsWith('Packages:')) {
      inPackages = true;
      continue;
    }
    if (!inPackages) continue;
    if (line.startsWith('  Package [')) {
      if (inBlock) break;
      inBlock = true;
      continue;
    }
    if (inBlock && line.isNotEmpty && !line.startsWith('   ')) break;
    final text = line.trim();
    for (final (key, pattern) in _infoFields) {
      if (out.containsKey(key)) continue;
      final m = pattern.firstMatch(text);
      if (m != null) out[key] = m.group(1);
    }
  }
  for (final key in ['minSdk', 'targetSdk']) {
    if (out[key] is String) out[key] = int.tryParse(out[key] as String);
  }
  return out;
}

final _infoFields = [
  ('codePath', RegExp(r'^codePath=(.+)$')),
  ('dataDir', RegExp(r'^dataDir=(.+)$')),
  ('minSdk', RegExp(r'minSdk=(\d+)')),
  ('targetSdk', RegExp(r'targetSdk=(\d+)')),
  ('firstInstallTime', RegExp(r'^firstInstallTime=(.+)$')),
  ('lastUpdateTime', RegExp(r'^lastUpdateTime=(.+)$')),
  ('installerPackageName', RegExp(r'installerPackageName=(\S+)')),
];

/// `settings list <namespace>` as key and value. A line without `=`
/// continues the value before it, which held a line break.
Map<String, String> parseSettingsList(String output) {
  final out = <String, String>{};
  String? last;
  for (final line in output.split('\n')) {
    if (line.isEmpty) continue;
    final eq = line.indexOf('=');
    if (eq > 0 && adbSettingKeyPattern.hasMatch(line.substring(0, eq))) {
      last = line.substring(0, eq);
      out[last] = line.substring(eq + 1);
    } else if (last != null) {
      out[last] = '${out[last]}\n$line';
    }
  }
  return out;
}
