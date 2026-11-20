import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../state/reload_home.dart';
import '../design/design.dart';
import '../devices/device_text.dart';
import '../onboarding/home_setup.dart' show SetupStep;
import '../settings/phone_access.dart';
import '../settings/restore_flow.dart';

/// A yes or no the first run keeps outside its screen, so the screen
/// being rebuilt (the device list reloading) does not take it back.
class FirstRunFlag extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Whether a backup came back during the first run, which then still asks
/// for this phone's permissions though the home is no longer empty.
final firstRunRestoredProvider = NotifierProvider<FirstRunFlag, bool>(
  FirstRunFlag.new,
);

/// Whether the first run's backup question is answered: a restore, or
/// Start fresh.
final firstRunAnsweredProvider = NotifierProvider<FirstRunFlag, bool>(
  FirstRunFlag.new,
);

/// 8.1: first whether there is a backup to restore, then what OmniFlow
/// does and the permissions it needs, each with why. Get started asks for
/// the ones left ticked, then [onDone] gets the setup steps a restored
/// backup already answers, empty for a fresh start.
class FirstRunScreen extends ConsumerStatefulWidget {
  const FirstRunScreen({super.key, required this.onDone});

  final Future<void> Function(Set<SetupStep> covered) onDone;

  @override
  ConsumerState<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends ConsumerState<FirstRunScreen> {
  var _find = true;
  var _home = true;
  var _background = true;
  var _busy = false;

  FoundBackup? _found;
  String? _error;
  Json? _restored;
  var _covered = <SetupStep>{};

  @override
  void initState() {
    super.initState();
    newestBackup(ref.read(phoneFilesProvider)).then((found) {
      if (mounted && found != null) setState(() => _found = found);
    }, onError: (Object _) {});
  }

  Future<void> _restoreFrom(Json? backup) async {
    if (backup == null || !mounted) return;
    // The dry run writes and rolls back, and the device list can see the
    // home full for a moment. Holding the first run keeps this screen and
    // its dialog in place until the restore is done or called off.
    final hold = ref.read(firstRunRestoredProvider.notifier)..set(true);
    final done = await restoreBackup(
      context,
      ref,
      backup,
      onBusy: (busy) {
        if (mounted) setState(() => _busy = busy);
      },
      onError: (message) {
        if (mounted) setState(() => _error = message);
      },
    );
    if (done == null) {
      hold.set(false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _restored = done;
      _covered = stepsCoveredBy(backup);
    });
    ref.read(firstRunAnsweredProvider.notifier).set(true);
    await reloadHome(ref);
  }

  Future<void> _pick() async {
    setState(() => _error = null);
    final backup = await pickBackup(
      ref,
      onError: (message) {
        if (mounted) setState(() => _error = message);
      },
    );
    await _restoreFrom(backup);
  }

  /// Android drops an activity started while the previous permission
  /// dialog is still closing, which lost the battery prompt on first run.
  static Future<void> _backInFront() async {
    final binding = WidgetsBinding.instance;
    final state = binding.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) {
      final resumed = Completer<void>();
      final listener = AppLifecycleListener(
        onResume: () {
          if (!resumed.isCompleted) resumed.complete();
        },
      );
      await resumed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      listener.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    final access = ref.read(phoneAccessProvider);
    if (_find) await access.askLocalNetwork();
    if (_home && await access.askLocation()) await access.askLocationAlways();
    if (_background) {
      await access.askNotifications();
      await _backInFront();
      await access.fixBattery();
    }
    ref.invalidate(phoneAccessStateProvider);
    await widget.onDone(_covered);
    if (mounted) setState(() => _busy = false);
  }

  Widget _choice({
    required String id,
    required IconData icon,
    required String title,
    required String why,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => OmniListRow(
    key: ValueKey('first-run-$id'),
    icon: icon,
    title: title,
    subtitle: why,
    subtitleLines: 2,
    onTap: () => onChanged(!value),
    trailing: Checkbox(
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      semanticLabel: title,
    ),
  );

  /// The first question: restore a backup, or start fresh. One tap on
  /// Start fresh moves on. A backup this install wrote is offered by its
  /// date, and any other through the system file picker.
  List<Widget> _backupQuestion(BuildContext context) => [
    OmniEmptyState(
      icon: OmniIcons.backup,
      title: 'Have a backup?',
      message:
          'Restore your home from a backup file, from this phone, Drive or '
          'another app, and skip setting it up again.',
      padding: const EdgeInsets.fromLTRB(
        OmniSpace.lg,
        OmniSpace.xl,
        OmniSpace.lg,
        OmniSpace.xl,
      ),
      iconColor: OmniPalette.of(context).accent,
      large: true,
    ),
    if (_found case final found?)
      OmniListRow(
        key: const ValueKey('first-run-restore-found'),
        icon: OmniIcons.download,
        title: 'Restore the latest backup',
        subtitle: foundBackupWords(found),
        subtitleLines: 2,
        chevron: true,
        onTap: _busy ? null : () => _restoreFrom(found.backup),
      ),
    OmniListRow(
      key: const ValueKey('first-run-restore'),
      icon: OmniIcons.download,
      title: 'Restore from a backup',
      subtitle: 'pick the file in Download/OmniFlow, Drive or any app',
      subtitleLines: 2,
      chevron: true,
      onTap: _busy ? null : _pick,
    ),
    if (_busy)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: OmniSpace.lg),
        child: OmniProgressBar(
          key: ValueKey('first-run-busy'),
          semanticLabel: 'Restoring the backup',
        ),
      ),
    if (_error case final e?)
      OmniBanner.error(e, key: const ValueKey('first-run-error')),
  ];

  /// A full screen with no way back: the intro step of the first run.
  /// The choices scroll, and Get started stays pinned above the system
  /// bar, so it is never below the fold.
  @override
  Widget build(BuildContext context) {
    final asked = ref.watch(firstRunAnsweredProvider);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: omniSystemBarsOf(context),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  key: const ValueKey('first-run'),
                  padding: const EdgeInsets.fromLTRB(
                    OmniSpace.screen,
                    OmniSpace.xxl,
                    OmniSpace.screen,
                    OmniSpace.lg,
                  ),
                  children: !asked
                      ? _backupQuestion(context)
                      : [
                          if (_restored case final done?) RestoreResult(done),
                          OmniEmptyState(
                            icon: AreaIcons.flash,
                            title: 'Connect anything to anything',
                            message:
                                'OmniFlow runs on this phone. It finds your lights, '
                                'plugs, TVs and boards on your Wi-Fi, and runs your '
                                'automations even when the screen is off.',
                            padding: const EdgeInsets.fromLTRB(
                              OmniSpace.lg,
                              OmniSpace.xl,
                              OmniSpace.lg,
                              OmniSpace.xl,
                            ),
                            iconColor: OmniPalette.of(context).accent,
                            large: true,
                          ),
                          _choice(
                            id: 'find',
                            icon: OmniIcons.wifi,
                            title: 'Find devices on Wi-Fi',
                            why: 'needs nearby devices and location',
                            value: _find,
                            onChanged: (v) => setState(() => _find = v),
                          ),
                          _choice(
                            id: 'home',
                            icon: OmniIcons.home,
                            title: 'Know when I am home',
                            why: 'uses your home Wi-Fi name',
                            value: _home,
                            onChanged: (v) => setState(() => _home = v),
                          ),
                          _choice(
                            id: 'background',
                            icon: OmniIcons.notifications,
                            title: 'Keep running in the background',
                            why: 'a small notification shows it is on',
                            value: _background,
                            onChanged: (v) => setState(() => _background = v),
                          ),
                          const SizedBox(height: OmniSpace.sm),
                          Text(
                            'You can change any of these later in Settings, This '
                            'phone.',
                            textAlign: TextAlign.center,
                            style: OmniText.captionOf(context),
                          ),
                        ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OmniSpace.screen,
                  OmniSpace.sm,
                  OmniSpace.screen,
                  OmniSpace.md,
                ),
                child: OmniActionBar(
                  primary: !asked
                      ? OmniButton(
                          key: const ValueKey('first-run-fresh'),
                          label: 'Start fresh',
                          onPressed: _busy
                              ? null
                              : () {
                                  setState(() => _error = null);
                                  ref
                                      .read(firstRunAnsweredProvider.notifier)
                                      .set(true);
                                },
                        )
                      : OmniButton(
                          key: const ValueKey('first-run-start'),
                          label: _restored == null ? 'Get started' : 'Continue',
                          onPressed: _busy ? null : _start,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
