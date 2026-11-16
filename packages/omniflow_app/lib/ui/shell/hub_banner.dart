import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/hub_mode.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../settings/settings_screen.dart' show engineStatusProvider;

/// "Hub not reachable" above every tab while a hub-mode phone has lost the
/// Mac mini: what shows is the last the hub sent, and changes wait. On a
/// phone that runs its own home, "Automations are stopped" while its hub
/// is off, with Start. Null while everything runs.
Widget? hubBanner(WidgetRef ref) {
  final link = ref.watch(hubLinkProvider);
  if (link == null) return _stoppedBanner(ref);
  return switch (link.state) {
    HubLinkState.connected || HubLinkState.connecting => null,
    HubLinkState.versionMismatch => OmniBanner.error(
      link.reason ?? 'The hub and this app run different versions.',
      key: const ValueKey('hub-version-mismatch'),
    ),
    HubLinkState.unreachable => OmniBanner.warning(
      'Hub not reachable. You see what it last sent, and changes wait '
      'until it is back. Trying again.',
      key: const ValueKey('hub-unreachable'),
      actionLabel: 'Try now',
      onAction: () => ref.read(hubLinkProvider.notifier).reconnect(),
    ),
  };
}

/// This phone's own hub is off, so no automation runs on its own. A hub
/// that failed to start has its own banner from the app, with the reason.
Widget? _stoppedBanner(WidgetRef ref) {
  final status = ref.watch(engineStatusProvider).value;
  if (status?['hubRunning'] != false || ref.watch(hubErrorProvider) != null) {
    return null;
  }
  return OmniBanner.warning(
    'Automations are stopped. They run only when you run them, until the '
    'hub starts again.',
    key: const ValueKey('hub-stopped'),
    actionLabel: 'Start',
    onAction: () async {
      if ((await ref.read(engineApiProvider).startHub()).ok) {
        ref.invalidate(engineStatusProvider);
      }
    },
  );
}
