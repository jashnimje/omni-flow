/// Names for apps whose package does not make them plain, and system
/// packages people meet in the running list.
const knownAppLabels = {
  'com.netflix.ninja': 'Netflix',
  'com.google.android.youtube': 'YouTube',
  'com.google.android.youtube.tv': 'YouTube',
  'com.google.android.youtube.tvmusic': 'YouTube Music',
  'com.google.android.youtube.tvkids': 'YouTube Kids',
  'com.google.android.apps.youtube.music': 'YouTube Music',
  'com.amazon.amazonvideo.livingroom': 'Prime Video',
  'com.amazon.avod.thirdpartyclient': 'Prime Video',
  'com.graymatrix.did': 'ZEE5',
  'in.startv.hotstar': 'JioHotstar',
  'com.sonyliv': 'Sony LIV',
  'com.jio.media.jiotvplus': 'JioTV+',
  'com.mxtech.videoplayer.television': 'MX Player',
  'com.shemaroo.shemarootv': 'ShemarooMe',
  'com.spotify.tv.android': 'Spotify',
  'com.spotify.music': 'Spotify',
  'com.disney.disneyplus': 'Disney+',
  'com.android.vending': 'Google Play Store',
  'com.android.tv.settings': 'Settings',
  'com.android.settings': 'Settings',
  'com.android.chrome': 'Chrome',
  'com.android.systemui': 'System UI',
  'com.google.android.gms': 'Google Play services',
  'com.google.android.gsf': 'Google Services Framework',
  'com.google.android.inputmethod.latin': 'Gboard',
  'com.android.inputmethod.latin': 'Keyboard',
  'com.google.android.tvkeyboard': 'Keyboard',
  'com.google.android.leanbacklauncher': 'Home',
  'com.google.android.tvlauncher': 'Home',
  'com.google.android.apps.tv.launcherx': 'Google TV Home',
  'com.google.android.apps.nexuslauncher': 'Home',
  'com.google.android.katniss': 'Google Assistant',
  'com.google.android.videos': 'Google TV',
  'com.google.android.play.games': 'Google Play Games',
  'com.amazon.tv.launcher': 'Home',
  'com.amazon.firebat': 'Prime Video',
};

/// Package words that say what kind of app it is or who makes it, not
/// which app: they are skipped when a name is made from the package.
const _notTheName = {
  'com',
  'org',
  'net',
  'in',
  'co',
  'io',
  'tv',
  'android',
  'google',
  'apps',
  'app',
  'mobile',
  'amazon',
  'client',
  'thirdpartyclient',
  'television',
  'launcher',
  'main',
  'release',
  'prod',
};

/// What an app is called: [label] when the device gave one, a known name,
/// else the last word of its package that names the app
/// (`com.example.omniflow` reads "Omniflow"), never the bare package.
String appLabelFor(String package, {String? label}) {
  if (label != null && label.trim().isNotEmpty) return label.trim();
  if (knownAppLabels[package] case final known?) return known;
  final words = package.split('.').where((s) => s.isNotEmpty).toList();
  final word =
      words.reversed
          .where((s) => !_notTheName.contains(s.toLowerCase()))
          .firstOrNull ??
      (words.isEmpty ? package : words.last);
  return word.isEmpty
      ? package
      : '${word[0].toUpperCase()}${word.substring(1)}';
}

final _labelPackage = RegExp(r'^\s*packageName=([A-Za-z][\w.]*)\s*$');
final _labelLine = RegExp(r'nonLocalizedLabel=(.*?)\s+icon=');

/// The labels a launcher query printed in full (`cmd package
/// query-activities` without `--brief`, cut to its `packageName=` and
/// `nonLocalizedLabel=` lines). An app whose label is a resource prints
/// `null` there, and is left out.
Map<String, String> parseActivityLabels(String output) {
  final labels = <String, String>{};
  String? package;
  for (final line in output.split('\n')) {
    if (_labelPackage.firstMatch(line) case final m?) {
      package = m.group(1);
      continue;
    }
    final label = _labelLine.firstMatch(line)?.group(1)?.trim();
    if (package == null || label == null) continue;
    if (label.isEmpty || label == 'null') continue;
    labels.putIfAbsent(package, () => label);
  }
  return labels;
}
