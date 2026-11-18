import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show DeviceView, Json;
import '../../state/house_providers.dart';
import '../../state/clock.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/device_text.dart' show iconOf, presenceDrivers, when;
import '../home/home_data.dart' show driversProvider;
import 'automations_state.dart';

/// The devices a scene can be saved from: not the phone, people, places
/// or tags.
List<DeviceView> captureDevices(List<Json> devices) => [
  for (final j in devices)
    if (j['driver'] != 'phone' &&
        j['driver'] != 'nfc_tag' &&
        !presenceDrivers.contains(j['driver']))
      DeviceView(j),
];

/// "Save how things are now" on the Scenes list, as a labelled button:
/// pick devices, and their state now becomes a scene.
class CaptureSceneAction extends ConsumerWidget {
  const CaptureSceneAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => OmniButton.ghost(
    key: const ValueKey('scene-capture'),
    icon: Icons.photo_camera_rounded,
    label: 'Save how things are now',
    expand: false,
    onPressed: () => showCaptureScene(context, ref),
  );
}

Future<void> showCaptureScene(BuildContext context, WidgetRef ref) async {
  final devices =
      captureDevices(
        await ref
            .read(devicesProvider.future)
            .catchError((Object _) => <Json>[]),
      )..sort(
        // Offline ones last: their state now is only the last one read.
        (a, b) => a.online == b.online
            ? a.name.compareTo(b.name)
            : (a.online ? -1 : 1),
      );
  final drivers = await ref
      .read(driversProvider.future)
      .catchError((Object _) => <String, Json>{});
  if (!context.mounted) return;
  final hour12 = ref.read(hour12Provider);
  final name = TextEditingController();
  final picked = <String>{};
  var stale = const <String>[];
  final saved = await showOmniSheet<bool>(
    context,
    builder: (context) => Owning(
      [name],
      child: StatefulBuilder(
        builder: (context, setState) {
          Future<void> save() async {
            final r = await ref
                .read(houseApiProvider)
                .captureScene(name.text.trim(), picked.toList());
            if (!context.mounted) return;
            if (r['ok'] != true) {
              showMessage(errorMessage(r));
              return;
            }
            stale = [
              for (final s in r['stale'] as List? ?? const [])
                if (s is Map) '${s['name'] ?? s['id']}',
            ];
            Navigator.of(context).pop(true);
          }

          return SheetTemplate(
            title: 'Save how things are now',
            subtitle:
                'The devices you pick keep their state now in a new scene.',
            primaryLabel: picked.isEmpty
                ? 'Save scene'
                : 'Save scene of ${picked.length} '
                      'device${picked.length == 1 ? '' : 's'}',
            primaryKey: const ValueKey('capture-save'),
            onPrimary: picked.isEmpty || name.text.trim().isEmpty ? null : save,
            missing: devices.isEmpty
                ? null
                : picked.isEmpty
                ? 'Pick at least one device.'
                : 'Give the scene a name first.',
            children: (context) => [
              TextField(
                key: const ValueKey('capture-name'),
                controller: name,
                // The same 60 as before, without a counter under the field.
                inputFormatters: [LengthLimitingTextInputFormatter(60)],
                decoration: const InputDecoration(labelText: 'Scene name'),
                onChanged: (_) => setState(() {}),
              ),
              if (devices.isEmpty)
                const OmniEmptyState(
                  icon: OmniIcons.devices,
                  title: 'Add a device first',
                  compact: true,
                )
              else ...[
                const OmniSectionHeader('Devices'),
                for (final d in devices)
                  // A device that is not answering has no state now to
                  // keep, so it cannot be picked.
                  OmniListRow(
                    key: ValueKey('capture-${d.id}'),
                    icon: iconOf(d, drivers),
                    iconForeground: d.online
                        ? null
                        : OmniPalette.of(context).muted,
                    title: d.name,
                    subtitle: switch (staleWords(d, hour12: hour12)) {
                      final stale? => 'Not answering. $stale',
                      null => d.room,
                    },
                    subtitleLines: 2,
                    dot: d.online ? null : StatusKind.offline,
                    selected: picked.contains(d.id),
                    enabled: d.online,
                    trailing: Checkbox(
                      value: picked.contains(d.id),
                      onChanged: d.online
                          ? (on) => setState(
                              () => on == true
                                  ? picked.add(d.id)
                                  : picked.remove(d.id),
                            )
                          : null,
                    ),
                    onTap: d.online
                        ? () => setState(
                            () => picked.contains(d.id)
                                ? picked.remove(d.id)
                                : picked.add(d.id),
                          )
                        : null,
                  ),
              ],
            ],
          );
        },
      ),
    ),
  );
  if (saved != true) return;
  showMessage(
    stale.isEmpty
        ? 'Scene saved'
        : 'Scene saved. ${stale.join(', ')} had not answered for a while, '
              'so the saved state may be old.',
  );
  await ref.read(automationsProvider.notifier).refresh();
}

/// "Last known 8 Nov, so it may have changed" for a device whose state is
/// older than its poll window (the engine counts it offline), else null.
String? staleWords(DeviceView d, {bool hour12 = false}) {
  if (d.online) return null;
  final seen = d.lastSeen?.toLocal();
  return seen == null
      ? 'Never read, so its state may be wrong'
      : 'Last known ${when(seen, hour12: hour12)}, so it may have changed';
}
