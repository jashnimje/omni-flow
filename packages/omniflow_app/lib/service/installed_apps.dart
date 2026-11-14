import 'package:flutter/services.dart';

/// An app on the phone's launcher.
typedef InstalledApp = ({String package, String label});

/// The launchable apps for the app picker, from the main activity's
/// omniflow/apps channel: sorted by name, without OmniFlow. Empty off the
/// phone (tests, the desktop) or when Android does not answer.
class InstalledApps {
  const InstalledApps({this.channel = const MethodChannel(name)});

  static const name = 'omniflow/apps';

  final MethodChannel channel;

  Future<List<InstalledApp>> list() async {
    final List<Object?>? raw;
    try {
      raw = await channel.invokeListMethod<Object?>('installedApps');
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
    return [
      for (final entry in raw ?? const [])
        if (entry
            case {'package': final String package, 'label': final String label}
            when package.isNotEmpty)
          (package: package, label: label.trim().isEmpty ? package : label),
    ];
  }
}
