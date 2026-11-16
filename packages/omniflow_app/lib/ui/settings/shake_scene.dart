import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart';
import '../../state/hub_mode.dart';
import '../../state/providers.dart';
import '../design/design.dart';

/// The phone thing this phone is: its own id on a hub, `phone` on a phone
/// that runs its own home.
final thisPhoneIdProvider = FutureProvider<String>((ref) async {
  final mode = await ref.watch(homeModeProvider.future);
  if (mode == HomeMode.hub) {
    final settings = await ref.watch(hubSettingsProvider.future);
    if (settings != null) return settings.phone;
  }
  return 'phone';
});

/// The scene this phone runs when shaken, or null for none.
final shakeSceneProvider = FutureProvider<String?>((ref) async {
  final phone = await ref.watch(thisPhoneIdProvider.future);
  final client = ref.watch(engineClientProvider);
  final got = await client.call(EngineCalls.deviceGet, {'id': phone});
  final settings = (got['device'] as Map?)?['settings'];
  final scene = settings is Map ? settings['shake_scene'] : null;
  return scene is String && scene.trim().isNotEmpty ? scene : null;
});

/// A scene's name by its id, for the row's words.
final _sceneNameProvider = FutureProvider.family<String?, String>((
  ref,
  id,
) async {
  final scenes = await EngineApi(ref.watch(engineClientProvider)).scenes();
  return scenes.or(const <Scene>[]).where((s) => s.id == id).firstOrNull?.name;
});

/// Settings, This phone: shake the phone to run a favourite scene. Off by
/// default. The engine runs the scene when the phone reports a shake, and
/// the phone reads its motion sensor only while this is on or an
/// automation uses a shake.
class ShakeSceneRow extends ConsumerWidget {
  const ShakeSceneRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scene = ref.watch(shakeSceneProvider);
    final id = scene.value;
    return OmniListRow(
      key: const ValueKey('settings-shake-scene'),
      icon: Symbols.vibration_rounded,
      title: 'Shake to run a scene',
      subtitle: switch (scene) {
        AsyncData() when id == null => 'Off',
        AsyncData() => 'Runs ${ref.watch(_sceneNameProvider(id!)).value ?? id}',
        AsyncError() => 'Not available',
        _ => 'Checking',
      },
      chevron: true,
      onTap: () => _pick(context, ref, id),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final client = ref.read(engineClientProvider);
    final api = EngineApi(client);
    final scenes = (await api.scenes()).or(const <Scene>[]);
    if (!context.mounted) return;
    const why =
        'Shake the phone firmly twice to run it. OmniFlow uses the motion '
        'sensor only while this is on.';
    final picked = await showPickerSheet<String>(
      context,
      title: 'Shake to run a scene',
      subtitle: scenes.isEmpty
          ? '$why No scenes yet. Make one in Automations, then come back.'
          : why,
      selected: current ?? '',
      sections: [
        const PickerSection([
          PickerItem(
            key: ValueKey('shake-scene-off'),
            value: '',
            title: 'Off',
            icon: Symbols.block_rounded,
          ),
        ]),
        if (scenes.isNotEmpty)
          PickerSection(title: 'Scenes', [
            for (final s in scenes)
              if (s.id case final sid?)
                PickerItem(
                  key: ValueKey('shake-scene-$sid'),
                  value: sid,
                  title: s.name,
                  icon: OmniIcons.automations,
                ),
          ]),
      ],
    );
    if (picked == null) return;
    final phone = await ref.read(thisPhoneIdProvider.future);
    final reply = await api.configureThing(phone, {'shake_scene': picked});
    if (!reply.ok) {
      showMessage('Could not save it. ${reply.failure?.message ?? ''}'.trim());
    }
    ref.invalidate(shakeSceneProvider);
  }
}
