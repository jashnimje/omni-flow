import 'package:flutter/material.dart';

import '../design/design.dart';
import '../settings/backup_page.dart';
import '../settings/hub_page.dart';
import 'home_setup.dart';

/// The other ways to start on an empty home: bring a home over from a
/// backup, use the home a hub already runs, or walk through the setup.
class StartOptions extends StatelessWidget {
  const StartOptions({super.key});

  static Future<void> _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('start-options'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const OmniSectionHeader('Start here'),
      OmniListRow(
        key: const ValueKey('empty-setup'),
        icon: OmniIcons.home,
        title: 'Set up your home',
        subtitle: 'Who you are, where home is, how the phone knows',
        chevron: true,
        onTap: () => openHomeSetup(context),
      ),
      const OmniSectionHeader('Moving from another phone?'),
      OmniListRow(
        key: const ValueKey('empty-restore'),
        icon: OmniIcons.download,
        title: 'Restore a backup',
        subtitle: 'From a file you saved on the old phone, or from Drive',
        chevron: true,
        onTap: () => _push(context, const BackupPage()),
      ),
      OmniListRow(
        key: const ValueKey('empty-hub'),
        icon: OmniIcons.hub,
        title: 'Connect to a hub',
        subtitle: 'Use the home a computer at home already runs',
        chevron: true,
        onTap: () => _push(context, const HubSetupPage()),
      ),
    ],
  );
}
