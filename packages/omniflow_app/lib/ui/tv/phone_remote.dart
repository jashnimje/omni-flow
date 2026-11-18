import 'package:flutter/material.dart';

import '../../api/tv_calls.dart';
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_remote.dart' show RemoteKey;
import 'tv_widgets.dart';

/// The keys another phone has, by Android key code.
abstract final class PhoneKeys {
  static const back = RemoteKey(4, 'Back', TvIcons.back, 'Back');
  static const home = RemoteKey(3, 'Home', OmniIcons.home, 'Home');
  static const recents = RemoteKey(187, 'Recents', TvIcons.recents, 'Recents');
  static const navigation = [back, home, recents];

  static const volumeDown = RemoteKey(25, 'Volume down', TvIcons.volumeDown);
  static const mute = RemoteKey(164, 'Mute', TvIcons.volumeOff);
  static const volumeUp = RemoteKey(24, 'Volume up', TvIcons.volumeUp);
  static const volume = [volumeDown, mute, volumeUp];

  static const power = RemoteKey(26, 'Power', OmniIcons.power, 'Power');
  static const lock = RemoteKey(223, 'Lock', TvIcons.sleep, 'Lock');
  static const wake = RemoteKey(224, 'Wake', TvIcons.wake, 'Wake');
  static const screen = [power, lock, wake];
}

/// The phone's keys (More, Remote): Back, Home and Recents, the volume,
/// the notification shade, and power, lock and wake.
class PhoneRemoteTab extends StatelessWidget {
  const PhoneRemoteTab({super.key, required this.tv});

  final TvController tv;

  Widget _key(RemoteKey k) => TvKeyButton(
    key: ValueKey('key-${k.keycode}'),
    label: k.label,
    icon: k.icon,
    showLabel: k.text != null,
    text: k.text,
    onTap: () => tv.key(k.keycode),
    onLongPress: () => tv.key(k.keycode, longPress: true),
  );

  Widget _shade(String key, String label, String action, IconData icon) =>
      TvKeyButton(
        key: ValueKey('phone-$key'),
        label: label,
        icon: icon,
        text: label,
        onTap: () => tv.call(
          TvCalls.notifications,
          TvCalls.notificationsArgs(tv.id, action: action),
        ),
      );

  @override
  Widget build(BuildContext context) => ListView(
    key: const ValueKey('phone-remote'),
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
    children: [
      const OmniSectionHeader('Move around'),
      TvKeyGrid(
        columns: 3,
        children: [for (final k in PhoneKeys.navigation) _key(k)],
      ),
      const OmniSectionHeader('Volume'),
      TvKeyGrid(
        columns: 3,
        children: [for (final k in PhoneKeys.volume) _key(k)],
      ),
      const OmniSectionHeader('Notifications'),
      TvKeyGrid(
        columns: 3,
        children: [
          _shade('notifications', 'Open', 'expand', OmniIcons.notifications),
          _shade(
            'quick-settings',
            'Quick settings',
            'settings',
            OmniIcons.settings,
          ),
          _shade('shade-close', 'Close', 'collapse', OmniIcons.close),
        ],
      ),
      const OmniSectionHeader('Screen and power'),
      TvKeyGrid(
        columns: 3,
        children: [for (final k in PhoneKeys.screen) _key(k)],
      ),
      const SizedBox(height: OmniSpace.sm),
      Text(
        'Power held down opens the power menu on most phones. Lock turns the '
        'screen off, and Wake turns it on again.',
        style: OmniText.captionOf(context),
      ),
    ],
  );
}
