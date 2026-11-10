import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/device_controls.dart';
import '../devices/device_text.dart';
import '../devices/open_device.dart';
import 'home_data.dart';

/// 1.2: a long press on a tile. The device's name, driver and room, its
/// power switch, the controls its capabilities need, and "Open device".
/// [context] is the tab's, so the device page opens inside the tab.
Future<void> showQuickSheet(BuildContext context, String id) =>
    showOmniSheet<void>(
      context,
      builder: (_) => QuickSheet(id: id, onOpen: () => openDevice(context, id)),
    );

class QuickSheet extends ConsumerWidget {
  const QuickSheet({super.key, required this.id, required this.onOpen});

  final String id;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final json = ref
        .watch(devicesProvider)
        .value
        ?.where((d) => d['id'] == id)
        .firstOrNull;
    if (json == null) {
      return const OmniSheet(
        title: 'Not here any more',
        children: [Text('This device was removed.', style: OmniText.caption)],
      );
    }
    final d = DeviceView(json);
    final drivers = ref.watch(driversProvider).value ?? const {};
    final tv = kindOf(d) == DeviceKind.tv;
    final playing = tv ? TvState.ofDevice(json) : null;
    return OmniSheet(
      key: ValueKey('quick-sheet-$id'),
      title: d.name,
      subtitle: tv
          ? tvLine(d)
          : [
              shortDriverName(drivers[d.driver], d.driver),
              ?d.room,
            ].where((s) => s.isNotEmpty).join(' · '),
      trailing: d.hasPower || tv ? PowerSwitch(device: d) : null,
      children: [
        if (!d.online && !tv)
          OmniBanner.error(
            'Not answering. It may be switched off at the wall, or on '
            'another Wi-Fi.',
          ),
        if (tv) ...[
          if (playing?.app != null)
            Padding(
              padding: const EdgeInsets.only(bottom: OmniSpace.sm),
              child: Text(
                [
                  appName(playing!.app!),
                  if (playing.playing case final String p) p,
                ].join(' · '),
                key: ValueKey('tv-card-now-$id'),
                style: OmniText.caption,
              ),
            ),
          TvQuickControls(device: d),
        ] else
          LightControls(device: d),
        const SizedBox(height: OmniSpace.md),
        OmniButton.ghost(
          key: ValueKey('quick-open-$id'),
          label: 'Open device',
          onPressed: () {
            Navigator.of(context).pop();
            onOpen();
          },
        ),
      ],
    );
  }
}
