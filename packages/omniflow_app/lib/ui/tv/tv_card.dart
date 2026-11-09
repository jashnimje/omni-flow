import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import 'tv_page.dart';

/// The dashboard card of a TV: power, what is playing, volume, and the way
/// into the control centre. The state comes from the hub's tv.state poll.
class TvCardBody extends ConsumerStatefulWidget {
  const TvCardBody({super.key, required this.device});

  final Json device;

  @override
  ConsumerState<TvCardBody> createState() => _TvCardBodyState();
}

class _TvCardBodyState extends ConsumerState<TvCardBody> {
  double? _dragging;

  String get id => '${widget.device['id']}';

  Future<void> _key(int keycode) =>
      callEngine(ref, TvCalls.key, TvCalls.keyArgs(id, keycode: keycode));

  @override
  Widget build(BuildContext context) {
    final s = TvState.ofDevice(widget.device);
    final theme = Theme.of(context);
    final max = s.volumeMax <= 0 ? 100 : s.volumeMax;
    final volume = _dragging ?? (s.volume ?? 0).clamp(0, max).toDouble();
    final playing = playingLabel(s.playing);
    return Column(
      children: [
        Row(
          children: [
            IconButton.filledTonal(
              key: ValueKey('tv-card-power-$id'),
              tooltip: s.isOn ? 'Put the TV to sleep' : 'Wake the TV',
              onPressed: () => _key(s.isOn ? Keycodes.sleep : Keycodes.wakeup),
              icon: Icon(
                Icons.power_settings_new,
                color: s.isOn ? Colors.greenAccent : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    powerLabel(s.power),
                    key: ValueKey('tv-card-power-state-$id'),
                    style: theme.textTheme.labelMedium,
                  ),
                  Text(
                    [
                      s.app ?? 'Nothing in front',
                      if (playing.isNotEmpty) playing,
                    ].join('  '),
                    key: ValueKey('tv-card-now-$id'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              key: ValueKey('tv-open-$id'),
              onPressed: () => openTv(context, widget.device),
              icon: const Icon(Icons.settings_remote),
              label: const Text('Open'),
            ),
          ],
        ),
        Row(
          children: [
            const Icon(Icons.volume_up, size: 20),
            Expanded(
              child: Slider(
                key: ValueKey('tv-card-volume-$id'),
                min: 0,
                max: max.toDouble(),
                divisions: max.clamp(1, 100),
                value: volume.clamp(0, max.toDouble()),
                label: '${volume.round()}',
                semanticFormatterCallback: (v) => 'Volume ${v.round()}',
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) async {
                  await callEngine(
                    ref,
                    TvCalls.volume,
                    TvCalls.volumeArgs(id, v.round()),
                  );
                  if (mounted) setState(() => _dragging = null);
                },
              ),
            ),
            SizedBox(
              width: 32,
              child: Text(
                s.volume == null && _dragging == null
                    ? '-'
                    : '${volume.round()}',
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
