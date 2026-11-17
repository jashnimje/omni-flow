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
  'com.google.android.as': 'Android System Intelligence',
  'com.google.android.googlequicksearchbox': 'Google',
  'com.google.android.apps.messaging': 'Messages',
  'com.google.android.dialer': 'Phone',
  'com.google.android.permissioncontroller': 'Permissions',
  'com.android.phone': 'Phone services',
  'com.jashnm.omniflow_app': 'OmniFlow',
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
  // System packages, by the application label their APK carries.
  'com.android.se': 'Secure Element',
  'com.android.dynsystem': 'Dynamic System Updates',
  'com.android.providers.media.module': 'Media picker',
  'com.google.android.providers.media.module': 'Media picker',
  'com.google.android.modulemetadata': 'Main components',
  'com.android.externalstorage': 'External Storage',
  'com.android.packageinstaller': 'Package installer',
  'com.google.android.packageinstaller': 'Package installer',
  'com.android.managedprovisioning': 'Work Setup',
  'com.android.shell': 'Shell',
  'com.android.providers.settings': 'Settings Storage',
  'com.android.providers.downloads': 'Download Manager',
  'com.android.providers.contacts': 'Contacts Storage',
  'com.android.providers.calendar': 'Calendar Storage',
  'com.android.providers.telephony': 'Phone and Messaging Storage',
  'com.android.providers.blockednumber': 'Blocked Numbers Storage',
  'com.android.providers.userdictionary': 'User Dictionary',
  'com.google.android.networkstack': 'Network manager',
  'com.android.keychain': 'Key Chain',
  'com.android.printspooler': 'Print Spooler',
  'com.android.bips': 'Default Print Service',
  'com.android.location.fused': 'Fused Location',
  'com.android.inputdevices': 'Input Devices',
  'com.android.vpndialogs': 'VPN dialogs',
  'com.android.proxyhandler': 'Proxy handler',
  'com.android.intentresolver': 'Intent resolver',
  'com.android.traceur': 'System Tracing',
  'com.android.companiondevicemanager': 'Companion Device Manager',
  'com.android.credentialmanager': 'Credential Manager',
  'com.android.storagemanager': 'Storage Manager',
  'com.android.mtp': 'MTP Host',
  'com.android.stk': 'SIM Toolkit',
  'com.google.android.cellbroadcastreceiver': 'Wireless emergency alerts',
  'com.google.android.ext.services': 'Android Services Library',
  'com.google.android.webview': 'Android System WebView',
  'com.google.android.tts': 'Speech Recognition and Synthesis from Google',
  'com.google.android.wifi.resources': 'System Wi-Fi Resources',
  'com.google.android.connectivity.resources': 'System Connectivity Resources',
  'com.google.android.healthconnect.controller': 'Health Connect',
  'com.google.android.adservices.api': 'Ad Privacy',
  'com.google.android.configupdater': 'Config updater',
  'com.google.android.rkpdapp': 'Remote provisioner',
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
  'module',
  'res',
  'resources',
  'api',
  'service',
  'services',
  'provider',
  'providers',
};

/// The packages Android itself ships under. One with no known name is
/// shown as a system package rather than as a word cut from its id.
const _systemPrefix = 'com.android.';

/// What an app is called: [label] when the device gave one, a known name,
/// else the last word of its package that names the app
/// (`com.example.omniflow` reads "Omniflow"). An Android system package
/// with no known name, or one with no such word, reads "System
/// (`<package>`)": a word cut from its id ("Se", "Module") names nothing.
String appLabelFor(String package, {String? label}) {
  if (label != null && label.trim().isNotEmpty) return label.trim();
  if (knownAppLabels[package] case final known?) return known;
  if (package.startsWith(_systemPrefix)) return systemAppLabel(package);
  final words = package.split('.').where((s) => s.isNotEmpty).toList();
  final word = words.reversed
      .where((s) => !_notTheName.contains(s.toLowerCase()))
      .firstOrNull;
  if (word == null && words.length > 1) return systemAppLabel(package);
  final name = word ?? (words.isEmpty ? package : words.last);
  return name.isEmpty
      ? package
      : '${name[0].toUpperCase()}${name.substring(1)}';
}

/// How a system package with no name of its own is shown.
String systemAppLabel(String package) => 'System ($package)';

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
