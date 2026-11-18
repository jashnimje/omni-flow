import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../../state/pending_power.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../tv/tv_page.dart' show Keycodes;
import 'device_text.dart';
import 'light_panels.dart';

export 'light_panels.dart' show ColourSwatches;

/// The controls a device's capability types need, shared by the quick
/// sheet and the device page: sliders for levels and warmth, colour
/// swatches, and for a TV its volume, mute and a five-key remote.

/// Whether [d] shows as on, counting a switch the user just flipped that
/// the device has not confirmed yet.
bool shownOn(WidgetRef ref, DeviceView d) =>
    ref.watch(pendingPowerProvider)[d.id]?.on ?? isLit(d);

/// Whether a switch of [d] is still on its way to the device.
bool powerPending(WidgetRef ref, DeviceView d) =>
    ref.watch(pendingPowerProvider)[d.id]?.sending ?? false;

/// Switches [d] on or off through its first toggle capability. The tile
/// flips at once and shimmers until the engine answers. When the call
/// fails it flips back and says why, with Try again.
Future<void> togglePower(WidgetRef ref, DeviceView d) async {
  final cap = d.capabilityOf('toggle');
  if (cap == null) return;
  final pending = ref.read(pendingPowerProvider.notifier);
  final want = !(ref.read(pendingPowerProvider)[d.id]?.on ?? isLit(d));
  unawaited(HapticFeedback.lightImpact());
  pending.sending(d.id, want);
  final reply = await EngineApi(ref.read(engineClientProvider))
      .invoke(d.id, '${cap['id']}', {'value': want});
  if (reply.ok) {
    pending.accepted(d.id);
    return;
  }
  pending.clear(d.id);
  unawaited(HapticFeedback.heavyImpact());
  showMessage(
    'Could not turn ${d.name} ${want ? 'on' : 'off'}. '
            '${reply.failure?.message ?? ''}'
        .trim(),
    action: 'Try again',
    onAction: () => togglePower(ref, d),
  );
}

/// Wakes a TV that is not on, and puts one that is on to sleep.
Future<void> toggleTv(WidgetRef ref, DeviceView d) {
  unawaited(HapticFeedback.lightImpact());
  return callEngine(
    ref,
    TvCalls.key,
    TvCalls.keyArgs(
      d.id,
      keycode: TvState.ofDevice(d.json).isOn ? Keycodes.sleep : Keycodes.wakeup,
    ),
  );
}

/// The power switch of a sheet header: a toggle, or a TV's sleep and wake.
class PowerSwitch extends ConsumerWidget {
  const PowerSwitch({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = kindOf(device) == DeviceKind.tv;
    return Semantics(
      label: '${device.name} power',
      child: Switch(
        key: ValueKey(
          tv ? 'tv-card-power-${device.id}' : 'quick-power-${device.id}',
        ),
        value: shownOn(ref, device),
        onChanged: device.online || tv
            ? (_) => tv ? toggleTv(ref, device) : togglePower(ref, device)
            : null,
      ),
    );
  }
}

const _warmth = LightWhite.kelvin;
const _cool = LightWhite.mired;
const _onWarmth = LightWhite.onWarm;

/// Sliders for every level and warmth, then the colour swatches. With
/// [modes] (the device page) the levels, then the light's white, colour
/// and scenes under one segmented control ([LightModePanel]).
class LightControls extends ConsumerWidget {
  const LightControls({super.key, required this.device, this.modes = false});

  final DeviceView device;
  final bool modes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = device;
    final api = ref.read(engineApiProvider);
    final children = <Widget>[];
    for (final cap in d.capabilities) {
      final type = cap['type'];
      if (type != 'level' && (type != 'color_temp' || modes)) continue;
      final range = rangeOf(cap);
      final value = d.state[cap['stateKey']];
      final warmth = type == 'color_temp';
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: OmniSpace.xs),
          child: OmniLabelledSlider(
            key: ValueKey('slider-${d.id}.${cap['id']}'),
            label: warmth ? 'Warmth' : '${cap['label']}',
            value: value is num ? value.toDouble() : range.min,
            min: range.min,
            max: range.max,
            step: 1,
            format: (v) => value is! num
                ? '-'
                : warmth && range.unit == 'mired'
                ? formatValue(kelvinOf(v, 'mired') ?? v, 'K')
                : formatValue(v.round(), range.unit),
            fill: warmth ? (range.unit == 'mired' ? _cool : _warmth) : null,
            labelOnFill: warmth ? _onWarmth : null,
            onChangeEnd: d.online
                ? (v) => api.invoke(d.id, '${cap['id']}', {'value': v.round()})
                : null,
          ),
        ),
      );
    }
    if (modes) {
      children.add(LightModePanel(device: d));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    final colour = d.capabilityOf('color_rgb');
    if (colour != null) {
      children.addAll([
        const OmniSectionHeader('Colour'),
        ColourSwatches(
          onPick: d.online
              ? (rgb) => api.invoke(d.id, '${colour['id']}', rgb)
              : null,
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// A TV's volume, mute and the five keys of a mini remote.
class TvQuickControls extends ConsumerWidget {
  const TvQuickControls({super.key, required this.device});

  final DeviceView device;

  static const up = 19;
  static const down = 20;
  static const left = 21;
  static const right = 22;
  static const ok = 23;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = device.id;
    final s = TvState.ofDevice(device.json);
    final max = s.volumeMax <= 0 ? 100 : s.volumeMax;
    final palette = OmniPalette.of(context);
    Future<void> key(int code) =>
        callEngine(ref, TvCalls.key, TvCalls.keyArgs(id, keycode: code));
    Widget remoteKey(int code, IconData icon, String label) => OmniIconAction(
      key: ValueKey('tv-mini-$code'),
      icon: icon,
      label: label,
      color: palette.text,
      onPressed: () => key(code),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OmniLabelledSlider(
                key: ValueKey('tv-card-volume-$id'),
                label: 'Volume',
                value: (s.volume ?? 0).toDouble(),
                max: max.toDouble(),
                step: 1,
                onChangeEnd: (v) => callEngine(
                  ref,
                  TvCalls.volume,
                  TvCalls.volumeArgs(id, v.round()),
                ),
              ),
            ),
            OmniIconAction(
              key: ValueKey('tv-mute-$id'),
              icon: s.muted == true ? AreaIcons.mute : AreaIcons.volume,
              label: s.muted == true ? 'Unmute' : 'Mute',
              color: palette.text,
              onPressed: () => key(Keycodes.mute),
            ),
          ],
        ),
        const SizedBox(height: OmniSpace.sm),
        Center(
          child: Container(
            padding: const EdgeInsets.all(OmniSpace.xs),
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(OmniRadii.card),
              border: Border.all(color: palette.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                remoteKey(up, AreaIcons.up, 'Up'),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    remoteKey(left, AreaIcons.left, 'Left'),
                    Semantics(
                      button: true,
                      label: 'OK',
                      excludeSemantics: true,
                      onTap: () => key(ok),
                      child: OmniTapTarget(
                        key: ValueKey('tv-mini-$ok'),
                        onTap: () => key(ok),
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: palette.raised,
                            shape: BoxShape.circle,
                          ),
                          child: const Text('OK', style: OmniText.label),
                        ),
                      ),
                    ),
                    remoteKey(right, AreaIcons.right, 'Right'),
                  ],
                ),
                remoteKey(down, AreaIcons.down, 'Down'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
