import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// A power switch the user asked for that the device has not confirmed.
@immutable
class PendingPower {
  const PendingPower({required this.on, required this.sending});

  /// What the user asked for.
  final bool on;

  /// True while the call is on its way. Once the engine accepts it, the
  /// tile keeps showing [on] until the device reports its state.
  final bool sending;
}

/// Power switches flipped on screen before the device answers, by device
/// id, so a tile flips the moment it is tapped. The live device list
/// clears an entry once the device reports, and a failed call rolls it
/// back.
class PendingPowerNotifier extends Notifier<Map<String, PendingPower>> {
  @override
  Map<String, PendingPower> build() {
    ref.listen(devicesProvider, (previous, next) {
      final before = {
        for (final d in previous?.value ?? const <Json>[]) d['id']: d,
      };
      final after = {for (final d in next.value ?? const <Json>[]) d['id']: d};
      final heard = [
        for (final e in state.entries)
          if (!e.value.sending && !identical(before[e.key], after[e.key]))
            e.key,
      ];
      if (heard.isEmpty) return;
      state = {...state}..removeWhere((id, _) => heard.contains(id));
    });
    return const {};
  }

  void sending(String id, bool on) =>
      state = {...state, id: PendingPower(on: on, sending: true)};

  void accepted(String id) {
    final p = state[id];
    if (p == null) return;
    state = {...state, id: PendingPower(on: p.on, sending: false)};
  }

  void clear(String id) {
    if (!state.containsKey(id)) return;
    state = {...state}..remove(id);
  }
}

final pendingPowerProvider =
    NotifierProvider<PendingPowerNotifier, Map<String, PendingPower>>(
      PendingPowerNotifier.new,
    );
