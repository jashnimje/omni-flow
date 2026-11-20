/// The four tabs, in the order of the navigation bar.
enum ShellTab { home, automations, devices, settings }

/// A place in the app a notification, a deep link or another screen can
/// open. Each has a location (`/device/desk_lamp`) that survives an Android
/// intent: a notification launches the app with it as the route, through
/// `FlutterForegroundTask.launchApp(link.location)`.
sealed class ShellLink {
  const ShellLink();

  /// The tab it opens on.
  ShellTab get tab;

  String get location;

  /// [location] as a link: a path (`/automation/arrive/run/r1`) or the same
  /// path under `omniflow://open`. Null for anything else, including the
  /// `omniflow://tag/` links written on NFC tags.
  static ShellLink? parse(String? location) {
    if (location == null || location.isEmpty) return null;
    final uri = Uri.tryParse(location);
    if (uri == null) return null;
    if (uri.hasScheme && !(uri.scheme == 'omniflow' && uri.host == 'open')) {
      return null;
    }
    final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return switch (parts) {
      [] || ['home'] => const TabLink(ShellTab.home),
      ['automations'] => const TabLink(ShellTab.automations),
      ['devices'] => const TabLink(ShellTab.devices),
      ['settings'] => const TabLink(ShellTab.settings),
      ['search'] => const SearchLink(),
      ['add'] => const AddLink(),
      ['add', 'wiz'] => const WizImportLink(),
      ['settings', 'developer'] => const DeveloperLink(),
      ['automation', final id] => AutomationLink(id),
      ['automation', final id, 'run', final run] => RunLink(id, run),
      ['review', final id] => ReviewLink(id),
      ['device', final id] => DeviceLink(id),
      _ => null,
    };
  }

  static String _seg(String s) => Uri.encodeComponent(s);

  @override
  bool operator ==(Object other) =>
      other is ShellLink &&
      other.runtimeType == runtimeType &&
      other.location == location;

  @override
  int get hashCode => location.hashCode;

  @override
  String toString() => location;
}

/// A tab's root.
class TabLink extends ShellLink {
  const TabLink(this.tab);

  @override
  final ShellTab tab;

  @override
  String get location => '/${tab.name}';
}

/// Search and commands, on Home.
class SearchLink extends ShellLink {
  const SearchLink();

  @override
  ShellTab get tab => ShellTab.home;

  @override
  String get location => '/search';
}

/// The add flow, opened on the tab the user is on.
class AddLink extends ShellLink {
  const AddLink();

  @override
  ShellTab get tab => ShellTab.devices;

  @override
  String get location => '/add';
}

/// Add, From the WiZ app, as a share from the WiZ app opens it.
class WizImportLink extends ShellLink {
  const WizImportLink();

  @override
  ShellTab get tab => ShellTab.devices;

  @override
  String get location => '/add/wiz';
}

/// Settings, Developer (packets, run log, drivers, engine).
class DeveloperLink extends ShellLink {
  const DeveloperLink();

  @override
  ShellTab get tab => ShellTab.settings;

  @override
  String get location => '/settings/developer';
}

/// One automation.
class AutomationLink extends ShellLink {
  const AutomationLink(this.id);

  final String id;

  @override
  ShellTab get tab => ShellTab.automations;

  @override
  String get location => '/automation/${ShellLink._seg(id)}';
}

/// One run of an automation, as a failed-run notification opens it.
class RunLink extends ShellLink {
  const RunLink(this.automationId, this.runId);

  final String automationId;
  final String runId;

  @override
  ShellTab get tab => ShellTab.automations;

  @override
  String get location =>
      '/automation/${ShellLink._seg(automationId)}/run/${ShellLink._seg(runId)}';
}

/// The review of an agent-made automation, as an approval request opens it.
class ReviewLink extends ShellLink {
  const ReviewLink(this.id);

  final String id;

  @override
  ShellTab get tab => ShellTab.automations;

  @override
  String get location => '/review/${ShellLink._seg(id)}';
}

/// One device's page.
class DeviceLink extends ShellLink {
  const DeviceLink(this.id);

  final String id;

  @override
  ShellTab get tab => ShellTab.devices;

  @override
  String get location => '/device/${ShellLink._seg(id)}';
}
