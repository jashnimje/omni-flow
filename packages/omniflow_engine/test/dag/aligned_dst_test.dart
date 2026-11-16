@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('aligned intervals stay on the wall clock across both summer time '
      'changes', () async {
    final run = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'test/support/aligned_dst_main.dart'],
      environment: {'TZ': 'America/New_York'},
    );
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final lines = [
      for (final l
          in '${run.stdout}'
              .replaceAll('Running build hooks...', '')
              .split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    expect(lines, [
      'back 11-1 14:45',
      'back window 11-1 14:45',
      'back hour at 5 11-1 15:05',
      'normal 11-2 14:45',
      'forward 3-8 14:45',
      'forward hour at 5 3-8 15:05',
      'chain 02:05,02:20,02:35,02:50,03:05,03:20,03:35,03:50',
      'chain 01:05,01:20,01:35,01:50,03:05,03:20,03:35,03:50',
    ]);
  });
}
