import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show DeviceView, Json;
import '../../state/house_providers.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/device_text.dart' show presenceDrivers, when;
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

/// "Save how things are now" on the Scenes list: pick devices, and their
/// state now becomes a scene.
class CaptureSceneAction extends ConsumerWidget {
  const CaptureSceneAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => OmniIconAction(
    key: const ValueKey('scene-capture'),
    icon: Icons.photo_camera_rounded,
    label: 'Save how things are now',
    onPressed: () => showCaptureScene(context, ref),
  );
}

Future<void> showCaptureScene(BuildContext context, WidgetRef ref) async {
  final devices = captureDevices(
    await ref.read(devicesProvider.future).catchError((Object _) => <Json>[]),
  )..sort((a, b) => a.name.compareTo(b.name));
  if (!context.mounted) return;
  final name = TextEditingController();
  final picked = <String>{};
  var stale = const <String>[];
  final saved = await showOmniSheet<bool>(
    context,
    builder: (context) => Owning(
      [name],
      child: StatefulBuilder(
        builder: (context, setState) => OmniSheet(
          title: 'Save how things are now',
          subtitle: 'The devices you pick keep their state now in a new scene.',
          children: [
            TextField(
              key: const ValueKey('capture-name'),
              controller: name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Scene name'),
              onChanged: (_) => setState(() {}),
            ),
            if (devices.isEmpty)
              const Text('Add a device first.', style: OmniText.caption)
            else
              for (final d in devices)
                CheckboxListTile(
                  key: ValueKey('capture-${d.id}'),
                  value: picked.contains(d.id),
                  title: Text(d.name),
                  subtitle: switch (staleWords(d)) {
                    final stale? => Text(
                      stale,
                      style: const TextStyle(color: OmniColors.warn),
                    ),
                    null => d.room == null ? null : Text(d.room!),
                  },
                  onChanged: (on) => setState(
                    () => on == true ? picked.add(d.id) : picked.remove(d.id),
                  ),
                ),
            const SizedBox(height: OmniSpace.md),
            if (devices.any((d) => picked.contains(d.id) && !d.online))
              const OmniBanner.warning(
                'Some devices you picked have not answered for a while. The '
                'scene keeps their last known state, which may be old.',
                key: ValueKey('capture-stale'),
              ),
            OmniButton(
              key: const ValueKey('capture-save'),
              label: picked.isEmpty
                  ? 'Pick at least one device'
                  : 'Save scene of ${picked.length} '
                        'device${picked.length == 1 ? '' : 's'}',
              onPressed: picked.isEmpty || name.text.trim().isEmpty
                  ? null
                  : () async {
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
                    },
            ),
          ],
        ),
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
String? staleWords(DeviceView d) {
  if (d.online) return null;
  final seen = d.lastSeen?.toLocal();
  return seen == null
      ? 'Never read, so its state may be wrong'
      : 'Last known ${when(seen)}, so it may have changed';
}
