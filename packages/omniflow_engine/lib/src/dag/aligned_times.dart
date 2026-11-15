/// Interval triggers lined up on the clock: "every hour at :05", "every 15
/// min from 09:00 to 18:00".
///
/// An interval with neither an offset nor a window runs every N seconds
/// from when it was loaded. With either, its times are counted on the wall
/// clock: from midnight, or from the window's start when it has one, moved
/// by the offset. The window's start is inside and its end is not, as for
/// a `between` condition, and a window whose end is earlier than its start
/// runs across midnight.
library;

import '../manifest/validation.dart';

final _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// The problem with an aligned interval of [seconds] moved by [offset]
/// inside [between], or null. [between] and [offset] are as written.
String? alignedProblem(int seconds, Object? offset, Object? between) {
  if (offset != null && (offset is! int || offset < 0 || offset >= seconds)) {
    return 'offset must be whole seconds from 0 to ${seconds - 1}, less '
        'than the interval';
  }
  if (between != null) {
    if (between is! List ||
        between.length != 2 ||
        between.any((t) => t is! String || !_hhmm.hasMatch(t))) {
      return 'between must be ["HH:MM", "HH:MM"]';
    }
    if (between[0] == between[1]) {
      return 'between needs two different times';
    }
    final start = _minutes(between[0] as String) * 60;
    final end = _minutes(between[1] as String) * 60;
    final length = end > start ? end - start : end + 24 * 3600 - start;
    if ((offset as int? ?? 0) >= length) {
      return 'the offset is longer than the time between';
    }
  }
  return null;
}

/// Checks an interval node's `offsetSeconds` and `between`.
void checkAlignedInterval(Map<String, Object?> c, String p, IssueCollector i) {
  final seconds = c['seconds'];
  if (seconds is! int || seconds < 1) return;
  final problem = alignedProblem(seconds, c['offsetSeconds'], c['between']);
  if (problem != null) i.add(p, problem);
}

/// The first aligned time after [now] for every [seconds], moved by
/// [offsetSeconds], inside [between] (`[start, end]` as `HH:MM`) when
/// given. Built from local calendar fields, so a summer time change keeps
/// the times on the wall clock.
DateTime nextAlignedTime(
  DateTime now, {
  required int seconds,
  int offsetSeconds = 0,
  List<String>? between,
}) {
  final start = between == null ? 0 : _minutes(between[0]) * 60;
  final end = between == null ? 24 * 3600 : _minutes(between[1]) * 60;
  // The window's length; one that crosses midnight runs into the next day.
  final length = end > start ? end - start : end + 24 * 3600 - start;
  // Yesterday's window may still be open after midnight.
  for (var day = -1; day <= 2; day++) {
    DateTime at(int second) =>
        DateTime(now.year, now.month, now.day + day, 0, 0, second);
    final first = start + offsetSeconds;
    // The pass at or after now, counted from this day's first time.
    final since = now.difference(at(first)).inSeconds;
    var k = since < 0 ? 0 : since ~/ seconds;
    while (true) {
      final second = first + k * seconds;
      if (second - start >= length) break;
      final candidate = at(second);
      if (candidate.isAfter(now)) return candidate;
      k++;
    }
  }
  throw StateError('no aligned time after $now');
}

/// "every hour at :05", the words of an aligned interval after "every N".
String alignedWords(int seconds, int offsetSeconds, List<String>? between) {
  final parts = <String>[];
  if (offsetSeconds > 0) {
    if (seconds % 60 == 0 && offsetSeconds % 60 == 0 && 3600 % seconds == 0) {
      final minutes = [
        for (var m = offsetSeconds ~/ 60; m < 60; m += seconds ~/ 60)
          ':${m.toString().padLeft(2, '0')}',
      ];
      parts.add(
        minutes.length == 1
            ? 'at ${minutes.single}'
            : 'at ${minutes.sublist(0, minutes.length - 1).join(', ')} and '
                  '${minutes.last}',
      );
    } else {
      parts.add('starting ${_amount(offsetSeconds)} in');
    }
  }
  if (between != null) parts.add('from ${between[0]} to ${between[1]}');
  return parts.join(' ');
}

String _amount(int s) => s % 3600 == 0
    ? '${s ~/ 3600} h'
    : s % 60 == 0
    ? '${s ~/ 60} min'
    : '$s s';

int _minutes(String hhmm) {
  final parts = hhmm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}
