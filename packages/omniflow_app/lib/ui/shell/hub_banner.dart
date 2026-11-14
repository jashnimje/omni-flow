import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/hub_mode.dart';
import '../design/design.dart';

/// "Hub not reachable" above every tab while a hub-mode phone has lost the
/// Mac mini: what shows is the last the hub sent, and changes wait. Null
/// on a phone that runs its own home, and while the link is up.
Widget? hubBanner(WidgetRef ref) {
  final link = ref.watch(hubLinkProvider);
  if (link == null) return null;
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
