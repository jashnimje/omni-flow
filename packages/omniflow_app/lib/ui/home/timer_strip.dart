import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/house_calls.dart';
import '../../state/house_providers.dart';
import '../../state/providers.dart';
import '../design/design.dart';

/// The running and paused timers on Home, each counting down from its end
/// time once a second, with Pause or Resume and Cancel.
class TimerStrip extends ConsumerStatefulWidget {
  const TimerStrip({super.key, this.now = DateTime.now});

  /// The clock the countdown reads, for tests.
  final DateTime Function() now;

  @override
  ConsumerState<TimerStrip> createState() => _TimerStripState();
}

class _TimerStripState extends ConsumerState<TimerStrip> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _ticking(bool on) {
    if (on && _tick == null) {
      _tick = Timer.periodic(
        const Duration(seconds: 1),
        (_) => mounted ? setState(() {}) : null,
      );
    } else if (!on) {
      _tick?.cancel();
      _tick = null;
    }
  }

  Future<void> _act(Future<Map<String, Object?>> Function() call) async {
    final r = await call();
    if (r['ok'] != true) showMessage(errorMessage(r));
  }

  @override
  Widget build(BuildContext context) {
    final timers = ref.watch(timersProvider).value ?? const <HouseTimer>[];
    _ticking(timers.any((t) => !t.paused));
    if (timers.isEmpty) return const SizedBox.shrink();
    final api = ref.read(houseApiProvider);
    final now = widget.now();
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpace.sm),
      child: Column(
        key: const ValueKey('timer-strip'),
        children: [
          for (final t in timers)
            OmniCard(
              child: OmniListRow(
                key: ValueKey('timer-${t.id}'),
                icon: OmniIcons.wait,
                title: t.name,
                subtitle: t.paused ? 'Paused' : null,
                value: countdownText(t.left(now)),
                semanticLabel:
                    '${t.name} timer, ${countdownText(t.left(now))} left'
                    '${t.paused ? ', paused' : ''}',
                divider: false,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OmniIconAction(
                      key: ValueKey('timer-pause-${t.id}'),
                      icon: t.paused ? OmniIcons.play : Icons.pause_rounded,
                      label: t.paused ? 'Resume ${t.name}' : 'Pause ${t.name}',
                      onPressed: () => _act(
                        () => t.paused
                            ? api.resumeTimer(t.name)
                            : api.pauseTimer(t.name),
                      ),
                    ),
                    OmniIconAction(
                      key: ValueKey('timer-cancel-${t.id}'),
                      icon: OmniIcons.close,
                      label: 'Cancel ${t.name}',
                      onPressed: () => _act(() => api.cancelTimer(t.name)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
