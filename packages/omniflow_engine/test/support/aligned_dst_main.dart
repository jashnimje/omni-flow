/// Prints aligned interval times on the 2026 summer time changes, one per
/// line. `aligned_dst_test.dart` runs it with `TZ` set, since the local
/// zone of a Dart process is fixed when it starts.
library;

import 'package:omniflow_engine/omniflow_engine.dart';

String _hm(DateTime t) =>
    '${t.month}-${t.day} '
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';

void main() {
  final cases = [
    ('back', DateTime(2026, 11, 1, 14, 30), 900, 0, null),
    ('back window', DateTime(2026, 11, 1, 14, 30), 900, 0, ['09:00', '18:00']),
    ('back hour at 5', DateTime(2026, 11, 1, 14, 30), 3600, 300, null),
    ('normal', DateTime(2026, 11, 2, 14, 30), 900, 0, null),
    ('forward', DateTime(2026, 3, 8, 14, 30), 900, 0, null),
    ('forward hour at 5', DateTime(2026, 3, 8, 14, 30), 3600, 300, null),
  ];
  for (final (label, now, seconds, offset, between) in cases) {
    final next = nextAlignedTime(
      now,
      seconds: seconds,
      offsetSeconds: offset,
      between: between,
    );
    print('$label ${_hm(next)}');
  }
  for (final start in [DateTime(2026, 11, 1, 1, 50), DateTime(2026, 3, 8, 1)]) {
    var t = start;
    final chain = <String>[];
    for (var i = 0; i < 8; i++) {
      t = nextAlignedTime(t, seconds: 900, offsetSeconds: 300);
      chain.add(_hm(t).split(' ').last);
    }
    print('chain ${chain.join(',')}');
  }
}
