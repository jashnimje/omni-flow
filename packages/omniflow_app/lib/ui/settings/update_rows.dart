import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../service/app_update.dart';
import '../../state/app_update.dart';
import '../design/design.dart';

/// About's "Check for updates". On Android it checks GitHub and installs
/// the update. Elsewhere the app cannot install itself, so it opens the
/// release page.
class UpdateCheckRow extends ConsumerStatefulWidget {
  const UpdateCheckRow({super.key});

  @override
  ConsumerState<UpdateCheckRow> createState() => _UpdateCheckRowState();
}

class _UpdateCheckRowState extends ConsumerState<UpdateCheckRow> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from "Install unknown apps": carry on if it is now allowed.
    _lifecycle = AppLifecycleListener(
      onResume: () =>
          unawaited(ref.read(appUpdateProvider.notifier).recheckPermission()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final env = ref.watch(updateEnvProvider);
    if (!env.selfInstall) {
      return OmniListRow(
        key: const ValueKey('about-update'),
        icon: OmniIcons.openLink,
        title: 'Check for updates',
        subtitle: 'Opens the releases page on GitHub',
        onTap: () => unawaited(
          launchUrl(releasesPage, mode: LaunchMode.externalApplication),
        ),
      );
    }
    final status = ref.watch(appUpdateProvider);
    final notifier = ref.read(appUpdateProvider.notifier);
    final row = updateRowWords(status);
    return OmniListRow(
      key: const ValueKey('about-update'),
      icon: OmniIcons.update,
      title: row.title,
      subtitle: row.subtitle,
      subtitleLines: 4,
      dot: status is UpdateFailed
          ? StatusKind.problem
          : status is UpdateAvailable || status is UpdateNeedsPermission
          ? StatusKind.warning
          : null,
      trailing: switch (status) {
        UpdateChecking() => const _Spinner(),
        UpdateDownloading(:final progress) => _Spinner(value: progress),
        UpdateInstalling() => const _Spinner(),
        _ => null,
      },
      onTap: switch (status) {
        UpdateIdle() || UpdateUpToDate() => () => unawaited(notifier.check()),
        UpdateAvailable() => () => unawaited(notifier.update()),
        UpdateNeedsPermission() => () => unawaited(notifier.allowInstalls()),
        UpdateFailed(:final release) =>
          release == null
              ? () => unawaited(notifier.check())
              : () => unawaited(notifier.update()),
        UpdateChecking() || UpdateDownloading() || UpdateInstalling() => null,
      },
    );
  }
}

/// The row's words for each state.
({String title, String subtitle}) updateRowWords(
  UpdateStatus status,
) => switch (status) {
  UpdateIdle() => (
    title: 'Check for updates',
    subtitle: 'Looks for a newer OmniFlow on GitHub',
  ),
  UpdateChecking() => (
    title: 'Checking for updates',
    subtitle: 'Asking GitHub for the newest release',
  ),
  UpdateUpToDate(:final app, :final noRelease) => (
    title: noRelease ? 'No release published yet' : 'Up to date',
    subtitle: noRelease
        ? 'Tap to check again'
        : 'OmniFlow ${app.build > 0 ? '${app.version} (build ${app.build})' : app.version} '
              'is the newest. Tap to check again',
  ),
  UpdateAvailable(:final release) => (
    title: 'Update available: ${release.label}',
    subtitle: 'Tap to download and install it',
  ),
  UpdateDownloading(:final release, :final progress) => (
    title: 'Downloading ${release.label}',
    subtitle: progress == null
        ? 'Starting the download'
        : '${(progress * 100).round()}%, then the download is checked '
              'before it is installed',
  ),
  UpdateNeedsPermission() => (
    title: 'Allow OmniFlow to install updates',
    subtitle:
        'Android only installs apps from apps you allow. Tap, turn on '
        'Allow from this source, then come back',
  ),
  UpdateInstalling(:final release) => (
    title: 'Installing ${release.label}',
    subtitle: 'Confirm in the Android prompt. OmniFlow restarts after',
  ),
  UpdateFailed(:final message) => (
    title: 'Update failed',
    subtitle: '$message. Tap to try again',
  ),
};

/// "Check for updates automatically", Android only.
class UpdateAutoRow extends ConsumerWidget {
  const UpdateAutoRow({super.key});

  static const _words =
      'Once a day. When there is one, a row says so here. It never '
      'installs by itself';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(updateEnvProvider).selfInstall) {
      return const SizedBox.shrink();
    }
    final on = ref.watch(updateAutoProvider).value ?? true;
    final notifier = ref.read(updateAutoProvider.notifier);
    return OmniListRow(
      key: const ValueKey('about-update-auto'),
      icon: OmniIcons.time,
      title: 'Check for updates automatically',
      subtitle: _words,
      subtitleLines: 3,
      semanticLabel:
          'Check for updates automatically, ${on ? 'on' : 'off'}. $_words',
      onTap: () => unawaited(notifier.set(!on)),
      trailing: ExcludeSemantics(
        child: Switch(
          key: const ValueKey('about-update-auto-switch'),
          value: on,
          onChanged: (v) => unawaited(notifier.set(v)),
        ),
      ),
    );
  }
}

/// On the Settings page, only while an update is out.
class UpdateAvailableRow extends ConsumerWidget {
  const UpdateAvailableRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appUpdateProvider);
    final release = switch (status) {
      UpdateAvailable(:final release) ||
      UpdateNeedsPermission(:final release) ||
      UpdateDownloading(:final release) ||
      UpdateInstalling(:final release) => release,
      _ => null,
    };
    if (release == null) return const SizedBox.shrink();
    return OmniListRow(
      key: const ValueKey('settings-update-available'),
      icon: OmniIcons.update,
      title: 'Update available: ${release.label}',
      subtitle: 'Open About to install it',
      dot: StatusKind.warning,
      chevron: true,
      onTap: onTap,
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({this.value});

  final double? value;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: CircularProgressIndicator(strokeWidth: 3, value: value),
  );
}
