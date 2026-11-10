import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/design.dart';
import '../devices/device_text.dart';
import '../settings/phone_access.dart';

/// 8.1: what OmniFlow does, and the permissions it needs, each with why.
/// Get started asks for the ones left ticked, then Home looks for devices.
class FirstRunScreen extends ConsumerStatefulWidget {
  const FirstRunScreen({super.key, required this.onDone});

  final Future<void> Function() onDone;

  @override
  ConsumerState<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends ConsumerState<FirstRunScreen> {
  var _find = true;
  var _home = true;
  var _background = true;
  var _busy = false;

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
    if (_home) await access.askLocation();
    if (_background) {
      await access.askNotifications();
      await _backInFront();
      await access.fixBattery();
    }
    ref.invalidate(phoneAccessStateProvider);
    await widget.onDone();
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

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        key: const ValueKey('first-run'),
        padding: const EdgeInsets.fromLTRB(14, 40, 14, 24),
        children: [
          const OmniEmptyState(
            icon: AreaIcons.flash,
            title: 'Connect anything to anything',
            message:
                'OmniFlow runs on this phone. It finds your lights, plugs, '
                'TVs and boards on your Wi-Fi, and runs your automations even '
                'when the screen is off.',
            padding: EdgeInsets.fromLTRB(18, 30, 18, 24),
            iconColor: OmniColors.accent,
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
          const SizedBox(height: OmniSpace.lg),
          OmniButton(
            key: const ValueKey('first-run-start'),
            label: 'Get started',
            onPressed: _busy ? null : _start,
          ),
          const SizedBox(height: OmniSpace.sm),
          const Text(
            'You can change any of these later in Settings, This phone.',
            textAlign: TextAlign.center,
            style: OmniText.caption,
          ),
        ],
      ),
    ),
  );
}
