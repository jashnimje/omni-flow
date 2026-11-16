import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show DeviceView, Json;
import '../../api/smart_home_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../home/home_data.dart' show roomsProvider;
import '../home/tile_look.dart' show whiteOf;
import '../settings/home_location_page.dart' show openHomeLocation;

/// `sunlight.get`. Null when the engine has no such command, or the agent
/// level hides it.
final sunlightProvider = FutureProvider.autoDispose<SunlightView?>((ref) async {
  try {
    final r = await ref
        .read(engineClientProvider)
        .call(SmartHomeCalls.sunlightGet, const {});
    return r['ok'] == true ? SunlightView.of(r) : null;
  } on Object {
    return null;
  }
});

Future<void> _setFollow(
  WidgetRef ref,
  List<String> targets,
  bool on, {
  SunCurveView? curve,
}) async {
  final r = await callEngine(
    ref,
    SmartHomeCalls.sunlightSet,
    SmartHomeCalls.sunlightSetArgs(targets, enabled: on, curve: curve),
  );
  if (r['ok'] == true) ref.invalidate(sunlightProvider);
}

void openSunLighting(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SunLightingPage()));

/// The "Follow the sun" switch on a light's page.
class FollowSunSwitch extends ConsumerWidget {
  const FollowSunSwitch({super.key, required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(sunlightProvider).value;
    if (view == null || !isSmartLight(device)) return const SizedBox.shrink();
    final own = view.follows(device.id);
    final viaRoom = !own && view.followsLight(device.id);
    final paused = view.paused.contains(device.id);
    final blocked = view.problem != null && !own && !viaRoom;
    return _FollowRow(
      key: ValueKey('follow-sun-${device.id}'),
      on: own || viaRoom,
      blocked: blocked,
      subtitle: blocked
          ? needsHomeWords
          : viaRoom
          ? 'Follows the sun with its room'
          : paused
          ? 'Paused for an hour after a change by hand'
          : 'Warm and dim at night, cool and bright at midday',
      onChanged: viaRoom || blocked
          ? null
          : (on) => _setFollow(ref, [device.id], on),
    );
  }
}

/// The "Follow the sun" switch for a room, from the ids of its devices.
class RoomFollowSunSwitch extends ConsumerWidget {
  const RoomFollowSunSwitch({super.key, required this.ids});

  final List<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(sunlightProvider).value;
    final devices = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        if (ids.contains(j['id'])) DeviceView(j),
    ];
    final room = devices.map((d) => d.roomId).whereType<String>().toSet();
    if (view == null || room.length != 1 || !devices.any(isSmartLight)) {
      return const SizedBox.shrink();
    }
    final id = room.single;
    final blocked = view.problem != null && !view.follows(id);
    return _FollowRow(
      key: ValueKey('follow-sun-room-$id'),
      on: view.follows(id),
      blocked: blocked,
      subtitle: blocked ? needsHomeWords : 'Every light in this room',
      onChanged: blocked ? null : (on) => _setFollow(ref, [id], on),
    );
  }
}

/// Why Follow the sun cannot be turned on yet.
const needsHomeWords =
    'Set where home is first: Settings, Your home, Home location. Tap to '
    'set it.';

class _FollowRow extends StatelessWidget {
  const _FollowRow({
    super.key,
    required this.on,
    required this.subtitle,
    required this.onChanged,
    this.blocked = false,
  });

  final bool on;
  final String subtitle;
  final ValueChanged<bool>? onChanged;

  /// No home location yet: a tap opens Home location instead.
  final bool blocked;

  @override
  Widget build(BuildContext context) => OmniListRow(
    icon: OmniIcons.sun,
    title: 'Follow the sun',
    subtitle: subtitle,
    subtitleLines: 3,
    onTap: () => blocked ? openHomeLocation(context) : openSunLighting(context),
    trailing: LabelledSwitch(
      value: on,
      onChanged: onChanged,
      label: 'Follow the sun',
    ),
  );
}

/// The follow-the-sun settings: which lights and rooms, the warmest and
/// coolest white, the dimmest and brightest, and today's curve.
class SunLightingPage extends ConsumerStatefulWidget {
  const SunLightingPage({super.key});

  @override
  ConsumerState<SunLightingPage> createState() => _SunLightingPageState();
}

class _SunLightingPageState extends ConsumerState<SunLightingPage> {
  SunCurveView? _curve;

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(sunlightProvider).value;
    final rooms = ref.watch(roomsProvider).value ?? const [];
    final lights = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        if (isSmartLight(DeviceView(j))) DeviceView(j),
    ];
    final saved = view?.targets.firstOrNull?.curve ?? view?.curve;
    final curve = _curve ?? saved ?? const SunCurveView();
    final targets = <String>[for (final t in view?.targets ?? const []) t.id];
    final noHome = view?.problem != null;
    return OmniPage(
      title: 'Follow the sun',
      body: ListView(
        key: const ValueKey('sun-lighting-page'),
        children: [
          if (view?.problem case final p?)
            OmniBanner.info(
              p,
              key: const ValueKey('sun-problem'),
              actionLabel: 'Set home location',
              onAction: () => openHomeLocation(context),
            ),
          if (view != null && view.preview.isNotEmpty) ...[
            const OmniSectionHeader('Today'),
            SunCurvePreview(points: view.preview),
            if (view.nowKelvin != null)
              Padding(
                padding: const EdgeInsets.only(top: OmniSpace.xs),
                child: Text(
                  'Now: ${view.nowKelvin} K at ${view.nowBrightness}% '
                  'brightness. Lights that are on move every 5 minutes.',
                  style: OmniText.caption,
                ),
              ),
          ],
          const OmniSectionHeader('Range'),
          _RangeRow(
            key: const ValueKey('sun-kelvin'),
            label: 'White',
            values: RangeValues(curve.minK.toDouble(), curve.maxK.toDouble()),
            min: 2000,
            max: 6500,
            divisions: 45,
            words: (v) => '${v.round()} K',
            onChanged: (v) => setState(
              () => _curve = curve.copyWith(
                minK: v.start.round(),
                maxK: v.end.round(),
              ),
            ),
          ),
          _RangeRow(
            key: const ValueKey('sun-brightness'),
            label: 'Brightness',
            values: RangeValues(
              curve.minBrightness.toDouble(),
              curve.maxBrightness.toDouble(),
            ),
            min: 1,
            max: 100,
            divisions: 99,
            words: (v) => '${v.round()}%',
            onChanged: (v) => setState(
              () => _curve = curve.copyWith(
                minBrightness: v.start.round(),
                maxBrightness: v.end.round(),
              ),
            ),
          ),
          if (_curve != null && targets.isNotEmpty)
            OmniButton(
              key: const ValueKey('sun-save'),
              label: 'Save the range',
              onPressed: () async {
                await _setFollow(ref, targets, true, curve: _curve);
                if (mounted) setState(() => _curve = null);
              },
            ),
          if (rooms.isNotEmpty) ...[
            const OmniSectionHeader('Rooms'),
            for (final r in rooms)
              OmniListRow(
                key: ValueKey('sun-room-${r.id}'),
                icon: OmniIcons.room,
                title: r.name,
                trailing: LabelledSwitch(
                  value: targets.contains(r.id),
                  label: '${r.name} follows the sun',
                  onChanged: noHome && !targets.contains(r.id)
                      ? null
                      : (on) => _setFollow(
                          ref,
                          [r.id],
                          on,
                          curve: on ? curve : null,
                        ),
                ),
              ),
          ],
          const OmniSectionHeader('Lights'),
          if (lights.isEmpty)
            const Text(
              'No light with a brightness or white setting yet.',
              style: OmniText.caption,
            ),
          for (final l in lights)
            OmniListRow(
              key: ValueKey('sun-light-${l.id}'),
              icon: OmniIcons.light,
              title: l.name,
              subtitle: view?.paused.contains(l.id) == true
                  ? 'Paused for an hour after a change by hand'
                  : !targets.contains(l.id) && view?.followsLight(l.id) == true
                  ? 'Follows with its room'
                  : null,
              trailing: LabelledSwitch(
                value: targets.contains(l.id),
                label: '${l.name} follows the sun',
                onChanged: noHome && !targets.contains(l.id)
                    ? null
                    : (on) =>
                          _setFollow(ref, [l.id], on, curve: on ? curve : null),
              ),
            ),
        ],
      ),
    );
  }
}

class _RangeRow extends StatelessWidget {
  const _RangeRow({
    super.key,
    required this.label,
    required this.values,
    required this.min,
    required this.max,
    required this.divisions,
    required this.words,
    required this.onChanged,
  });

  final String label;
  final RangeValues values;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) words;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$label: ${words(values.start)} at night to ${words(values.end)} '
        'at midday',
        style: OmniText.body,
      ),
      RangeSlider(
        values: values,
        min: min,
        max: max,
        divisions: divisions,
        labels: RangeLabels(words(values.start), words(values.end)),
        semanticFormatterCallback: words,
        onChanged: onChanged,
      ),
    ],
  );
}

/// Today's curve: each half hour as a bar, its height the brightness and
/// its colour the white.
class SunCurvePreview extends StatelessWidget {
  const SunCurvePreview({super.key, required this.points});

  final List<SunPoint> points;

  @override
  Widget build(BuildContext context) {
    final brightest = points.reduce(
      (a, b) => b.brightness > a.brightness ? b : a,
    );
    final dimmest = points.reduce(
      (a, b) => b.brightness < a.brightness ? b : a,
    );
    String time(DateTime t) => TimeOfDay.fromDateTime(t).format(context);
    return Semantics(
      label:
          'Today\'s curve. Dimmest and warmest ${dimmest.kelvin} K at '
          '${dimmest.brightness}%, brightest ${brightest.kelvin} K at '
          '${brightest.brightness}% around ${time(brightest.at)}',
      excludeSemantics: true,
      child: SizedBox(
        key: const ValueKey('sun-curve'),
        height: 80,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final p in points)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 0.5),
                  child: Container(
                    height: 6 + 74 * p.brightness / 100,
                    decoration: BoxDecoration(
                      color: whiteOf(p.kelvin.toDouble()),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A switch that a screen reader names, since Switch takes no label.
class LabelledSwitch extends StatelessWidget {
  const LabelledSwitch({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Switch(value: value, onChanged: onChanged),
  );
}
