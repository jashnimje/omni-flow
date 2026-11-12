import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../add/add_page.dart';
import '../automations/automations.dart';
import '../design/design.dart';
import '../devices/devices_screen.dart';
import '../devices/open_device.dart';
import '../home/home_screen.dart';
import '../home/search_page.dart';
import '../settings/developer_page.dart';
import '../settings/settings_screen.dart';
import 'links.dart';

/// What each tab shows and which pages links open. Screen builders change
/// this file only: point a tab's [ShellTabSpec.root] at the new screen, and
/// [shellPageFor] at the new page for each link.

/// The floating button of a tab root. [onPressed] gets a context inside the
/// tab's navigator, so a page it pushes keeps the tab bar.
class ShellFab {
  const ShellFab({
    required this.key,
    required this.label,
    required this.onPressed,
    this.icon = OmniIcons.add,
    this.hiddenWhen,
  });

  final Key key;
  final String label;
  final IconData icon;
  final void Function(BuildContext tabContext) onPressed;

  /// True while the root shows a screen with its own add action (first
  /// run, an empty home), so the button would only repeat it.
  final bool Function(WidgetRef ref)? hiddenWhen;
}

class ShellTabSpec {
  const ShellTabSpec({
    required this.label,
    required this.icon,
    required this.root,
    this.fab,
    this.fullScreenWhen,
  });

  final String label;
  final IconData icon;
  final WidgetBuilder root;

  /// Shown only while the tab is at its root.
  final ShellFab? fab;

  /// True while the root is a screen that stands alone (the first run),
  /// so the tab bar is hidden until it is done.
  final bool Function(WidgetRef ref)? fullScreenWhen;
}

const _addFab = ShellFab(
  key: ValueKey('add-device'),
  label: 'Add',
  onPressed: openAddThing,
);

final Map<ShellTab, ShellTabSpec> shellTabs = {
  ShellTab.home: ShellTabSpec(
    label: 'Home',
    icon: OmniIcons.home,
    root: (_) => const HomeScreen(),
    fab: const ShellFab(
      key: ValueKey('add-device'),
      label: 'Add',
      onPressed: openAddThing,
      hiddenWhen: homeIsEmpty,
    ),
    fullScreenWhen: homeShowsFirstRun,
  ),
  ShellTab.automations: ShellTabSpec(
    label: 'Automations',
    icon: OmniIcons.automations,
    root: (_) => const AutomationsScreen(),
    fab: const ShellFab(
      key: ValueKey('new-rule'),
      label: 'New',
      onPressed: openNewAutomation,
      hiddenWhen: automationsAreEmpty,
    ),
  ),
  ShellTab.devices: ShellTabSpec(
    label: 'Devices',
    icon: OmniIcons.devices,
    root: (_) => const DevicesScreen(),
    fab: _addFab,
  ),
  ShellTab.settings: ShellTabSpec(
    label: 'Settings',
    icon: OmniIcons.settings,
    root: (_) => const SettingsScreen(),
  ),
};

/// The page [link] opens on top of its tab's root, or null when the root
/// is the place (a [TabLink], or a page that does not exist yet).
/// [AddLink] is not a page: the shell runs [openAddThing] for it.
Widget? shellPageFor(ShellLink link) => switch (link) {
  TabLink() || AddLink() => null,
  SearchLink() => const SearchScreen(),
  DeveloperLink() => const DeveloperScreen(),
  AutomationLink(:final id) => AutomationPage(id: id),
  RunLink(:final automationId, :final runId) => RunPage(
    automationId: automationId,
    runId: runId,
  ),
  ReviewLink(:final id) => ReviewPage(id: id),
  DeviceLink(:final id) => DeviceRoute(id: id),
};
