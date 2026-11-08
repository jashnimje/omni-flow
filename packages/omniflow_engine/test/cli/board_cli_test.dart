@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../support/virtual_board.dart';

/// A new board from USB to a named pin, the way a user does it: set it up
/// over USB, add it at the Wi-Fi address it reports, then name pins one by one.
void main() {
  late Directory home;
  final secrets = InMemorySecretStore();
  final boards = <VirtualBoard>[];

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_board_cli');
  });

  tearDown(() async {
    for (final b in boards) {
      await b.stop();
    }
    boards.clear();
    await home.delete(recursive: true);
  });

  Future<(int, Map<String, Object?>)> omni(
    List<String> args, {
    String input = '',
  }) async {
    final out = StringBuffer();
    final code = await OmniCommandRunner(
      out: out,
      input: Stream.value(utf8.encode(input)),
      engineFactory: (h, {tap}) =>
          OmniEngine.open(home: h, secrets: secrets, tap: tap),
    ).run(['--home', home.path, ...args]);
    return (code, jsonDecode(out.toString()) as Map<String, Object?>);
  }

  test('setup over USB, add over Wi-Fi, then name pins', () async {
    if (await VirtualBoard.build() == null) {
      markTestSkipped('no C++ compiler for the virtual board');
      return;
    }
    final usb = await VirtualBoard.start(node: 'fresh', pty: true);
    final wifi = await VirtualBoard.start(node: 'desk_board', udp: true);
    boards.addAll([usb, wifi]);

    final (setupCode, setup) = await omni([
      'board',
      'setup',
      usb.tty!,
      '--ssid',
      'HomeNet',
      '--name',
      'desk_board',
    ], input: 'secret-password\n');
    expect(setupCode, 0, reason: '$setup');
    expect(setup['node'], 'desk_board');
    expect(setup['wifi'], {
      'configured': true,
      'connected': true,
      'ip': '127.0.0.1',
    });

    final (addCode, added) = await omni([
      'device',
      'add',
      'desk',
      '--driver',
      'omniflow_board',
      '--host',
      '127.0.0.1',
      '--port',
      '${wifi.udpPort}',
    ]);
    expect(addCode, 0, reason: '$added');
    expect((added['device'] as Map)['stableId'], 'desk_board');

    final (pinCode, pinned) = await omni([
      'board',
      'pin',
      'desk',
      'relay',
      '2',
      'out',
    ]);
    expect(pinCode, 0, reason: '$pinned');
    expect((pinned['board'] as Map)['pins'], ['relay']);
    await omni([
      'board',
      'pin',
      'desk',
      'button',
      '3',
      'in_pullup',
      '--watch-ms',
      '20',
    ]);

    final (invokeCode, _) = await omni([
      'device',
      'invoke',
      'desk',
      'relay',
      'value=true',
    ]);
    expect(invokeCode, 0);

    final (badCode, bad) = await omni([
      'board',
      'pin',
      'desk',
      'level',
      '3',
      'adc',
    ]);
    expect(badCode, 1);
    expect('${bad['error']}', contains('pin 3 is already "button"'));

    final (linkCode, linked) = await omni([
      'link',
      'add',
      'desk.button',
      'desk.relay',
      '--toggle',
    ]);
    expect(linkCode, 0, reason: '$linked');
    expect(linked['name'], 'desk.button toggles desk.relay');
    final (_, links) = await omni(['link', 'list']);
    final toggleId = linked['id'] as String;
    expect((links['links'] as List).single['id'], toggleId);
    final (againCode, again) = await omni([
      'link',
      'add',
      'desk.button',
      'desk.relay',
      '--toggle',
    ]);
    expect(againCode, 1);
    expect((again['error'] as Map)['type'], 'exists');

    // An on/off button never crosses a number, so a threshold on it is refused.
    final (onOffCode, onOff) = await omni([
      'link',
      'add',
      'desk.button',
      'desk.relay',
      '--below',
      '1',
      '--set',
      'false',
    ]);
    expect(onOffCode, 1);
    expect((onOff['error'] as Map)['type'], 'invalid');
    expect('${onOff['error']}', contains('Use a toggle or follow link'));

    await omni(['board', 'pin', 'desk', 'knob', '16', 'adc']);
    Future<(int, Map<String, Object?>)> threshold(String flag, String limit) =>
        omni([
          'link',
          'add',
          'desk.knob',
          'desk.relay',
          '--$flag',
          limit,
          '--set',
          flag == 'below' ? 'true' : 'false',
        ]);
    final (belowCode, below) = await threshold('below', '30');
    expect(belowCode, 0, reason: '$below');
    final (aboveCode, above) = await threshold('above', '60');
    expect(aboveCode, 0, reason: '$above');
    expect(below['id'], isNot(above['id']));

    final (_, after) = await omni(['link', 'remove', toggleId]);
    expect(after['removed'], isTrue);
    final (_, left) = await omni(['link', 'list']);
    expect(
      [for (final l in left['links'] as List) (l as Map)['id']]..sort(),
      [below['id'], above['id']]..sort(),
    );

    final (_, removed) = await omni([
      'board',
      'pin',
      'desk',
      'relay',
      '--remove',
    ]);
    expect((removed['board'] as Map)['pins'], ['button', 'knob']);
  });
}
