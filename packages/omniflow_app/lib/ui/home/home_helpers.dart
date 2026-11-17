import 'package:flutter/material.dart';

import 'room_tile.dart';
import 'timer_strip.dart';

export '../../state/house_providers.dart' show houseModeProvider;

/// Under Home's status chips: the running timers, and one tile
/// per room with lights. Each part shows only when it has something.
class HomeHelpers extends StatelessWidget {
  const HomeHelpers({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [TimerStrip(), RoomTileRow()],
  );
}
