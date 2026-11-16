import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../design/design.dart';
import 'settings_screen.dart' show engineStatusProvider;

/// The hub on this phone: what runs automations on their own (triggers,
/// timers, device pushes). It can be stopped and started again.
class HubsPage extends ConsumerWidget {
  const HubsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider).value;
    final hubError = ref.watch(hubErrorProvider);
    final running = status?['hubRunning'] == true;
    final loaded = (status?['flows'] as List?)?.length;
    final api = ref.read(engineApiProvider);
    return ListPage(
      title: 'Hubs',
      children: (context) => [
        if (hubError != null)
          OmniBanner.error(
            'The hub did not start, so automations only run when you run '
            'them. Try starting it again below.',
            key: const ValueKey('hubs-error'),
          ),
        OmniHeroCard(
          key: const ValueKey('hub-hero'),
          title: status == null
              ? 'Checking the hub'
              : running
              ? 'This phone runs the hub'
              : 'The hub is stopped',
          subtitle: loaded == null
              ? null
              : '$loaded automation${loaded == 1 ? '' : 's'} loaded',
          tone: running ? HeroTone.accent : HeroTone.plain,
        ),
        const Text(
          'The hub listens for your devices, keeps time and runs each '
          'automation when its trigger happens, with the screen off too.',
          style: OmniText.caption,
        ),
        const SizedBox(height: OmniSpace.lg),
        if (status != null && !running)
          OmniButton(
            key: const ValueKey('hub-start'),
            label: 'Start the hub',
            onPressed: () async {
              if ((await api.startHub()).ok) {
                ref.invalidate(engineStatusProvider);
              }
            },
          ),
        if (running)
          OmniButton.danger(
            key: const ValueKey('hub-stop'),
            label: 'Stop the hub',
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Stop the hub?',
                body:
                    'Automations stop running on their own until you start '
                    'it again. You can still run them by hand.',
                action: 'Stop',
                destructive: true,
              );
              if (!ok) return;
              if ((await api.stopHub()).ok) {
                ref.invalidate(engineStatusProvider);
              }
            },
          ),
      ],
    );
  }
}
