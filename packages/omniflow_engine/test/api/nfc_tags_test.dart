import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart' show UsageException;
import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import 'things_test.dart' show announceOn, until;

/// The tag registry, what the phone writes on a tag, and `nfc.scanned` from
/// the phone and from a board, through [OmniEngine.handle] and the CLI.
void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;
  final secrets = InMemorySecretStore();

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_tags');
    engine = await OmniEngine.open(home: home, secrets: secrets);
    events = [];
    sub = engine.events.listen(events.add);
  });

  tearDown(() async {
    await sub.cancel();
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command: $result');
    return result;
  }

  Future<Map<String, Object?>> err(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isFalse, reason: '$command: $result');
    return Map<String, Object?>.from(result['error'] as Map);
  }

  Future<Map<String, Object?>> stateOf(String id) async => Map.from(
    ((await ok('device.get', {'id': id}))['device'] as Map)['state'] as Map,
  );

  List<(Object?, Object?, Object?)> thingEvents() => [
    for (final e in events)
      if (e['event'] == 'thing.event') (e['thing'], e['key'], e['payload']),
  ];

  List<Map<String, Object?>> unknowns() => [
    for (final e in events)
      if (e['event'] == 'tag.unknown') e,
  ];

  Map<String, Object?> link(String id) => uriRecord('$tagUriPrefix$id');

  group('tag.save, tag.list and tag.remove', () {
    test('adds a tag, renames it and sets or clears its UID', () async {
      final made = await ok('tag.save', {
        'id': 'front_door',
        'name': 'Front door',
        'uid': '04:a2:2b:1c',
      });
      expect(made['created'], isTrue);
      expect(made['tag'], {
        'id': 'front_door',
        'name': 'Front door',
        'uid': '04A22B1C',
      });

      final renamed = await ok('tag.save', {
        'id': 'front_door',
        'name': 'Door',
      });
      expect(renamed['created'], isFalse);
      expect(renamed['tag'], containsPair('uid', '04A22B1C'));
      expect(renamed['tag'], containsPair('name', 'Door'));

      await ok('tag.save', {'id': 'front_door', 'name': 'Door', 'uid': null});
      expect((await ok('tag.list', {}))['tags'], [
        {'id': 'front_door', 'name': 'Door'},
      ]);
    });

    test(
      'refuses a bad id, a bad UID, a shared UID and a non-tag id',
      () async {
        await ok('tag.save', {'id': 'a', 'name': 'A', 'uid': '04A22B1C'});
        await ok('device.add', {'id': 'lamp', 'driver': 'phone'});
        for (final (args, type) in [
          ({'id': 'Bad', 'name': 'x'}, 'invalid'),
          ({'id': 'a' * 65, 'name': 'x'}, 'invalid'),
          ({'id': 'b', 'name': 'x', 'uid': 'xyz'}, 'invalid'),
          ({'id': 'b', 'name': 'x', 'uid': '04A2'}, 'invalid'),
          ({'id': 'b', 'name': 'x', 'uid': 7}, 'invalid'),
          ({'id': 'b'}, 'invalid'),
          ({'id': 'b', 'name': 'x', 'uid': '04-a2-2b-1c'}, 'exists'),
          ({'id': 'lamp', 'name': 'x'}, 'exists'),
        ]) {
          expect((await err('tag.save', args))['type'], type, reason: '$args');
        }
        expect(((await ok('tag.list', {}))['tags'] as List).length, 1);
      },
    );

    test(
      'device.add and thing.add keep UIDs unique and normalized too',
      () async {
        await ok('device.add', {
          'id': 'a',
          'driver': 'nfc_tag',
          'settings': {'uid': '04:a2:2b:1c'},
        });
        expect(((await ok('tag.list', {}))['tags'] as List).single, {
          'id': 'a',
          'name': 'a',
          'uid': '04A22B1C',
        });
        final shared = {
          'driver': 'nfc_tag',
          'settings': {'uid': '04A22B1C'},
        };
        expect(
          (await err('device.add', {'id': 'b', ...shared}))['type'],
          'exists',
        );
        expect(
          (await err('thing.add', {'candidate': shared, 'name': 'B'}))['type'],
          'exists',
        );
        expect(
          (await err('device.add', {
            'id': 'c',
            'driver': 'nfc_tag',
            'settings': {'uid': 'nope'},
          }))['type'],
          'invalid',
        );
        await ok('device.add', {'id': 'a', 'replace': true, ...shared});
      },
    );

    test('thing.configure keeps UIDs unique and normalized too', () async {
      await ok('tag.save', {
        'id': 'front_door',
        'name': 'F',
        'uid': '04A1B2C3',
      });
      await ok('tag.save', {'id': 'back_door', 'name': 'B'});
      expect(
        (await err('thing.configure', {
          'id': 'back_door',
          'settings': {'uid': '04:a1:b2:c3'},
        }))['type'],
        'exists',
      );
      await ok('thing.configure', {
        'id': 'back_door',
        'settings': {'uid': '04:a1:b2:c4'},
      });
      await ok('thing.configure', {
        'id': 'front_door',
        'settings': {'uid': '04a1b2c3'},
      });
      final uids = {
        for (final t in (await ok('tag.list', {}))['tags'] as List)
          (t as Map)['id']: t['uid'],
      };
      expect(uids, {'front_door': '04A1B2C3', 'back_door': '04A1B2C4'});
    });

    test('remove disables the flows that name the tag', () async {
      await ok('tag.save', {'id': 'desk', 'name': 'Desk'});
      await ok('flow.save', {
        'flow': announceOn('desk_flow', {
          'thing': 'desk',
          'key': 'scanned',
          'event': true,
        }, 'desk'),
        'trusted': true,
      });
      final removed = await ok('tag.remove', {'id': 'desk'});
      expect(removed['removed'], isTrue);
      expect(removed['flows'], ['desk_flow']);
      final again = await err('flow.enable', {'id': 'desk_flow'});
      expect(again['type'], 'invalid', reason: 'its tag is gone');
      expect((await ok('tag.list', {}))['tags'], isEmpty);
      expect((await err('tag.remove', {'id': 'desk'}))['type'], 'not_found');
      await ok('device.add', {'id': 'lamp', 'driver': 'phone'});
      expect((await err('tag.remove', {'id': 'lamp'}))['type'], 'invalid');
    });
  });

  group('tag.write_payload', () {
    test(
      'a link to the tag id and an Application Record for the app',
      () async {
        await ok('tag.save', {'id': 'front_door', 'name': 'Front door'});
        final payload = await ok('tag.write_payload', {'id': 'front_door'});
        expect(payload['uri'], 'omniflow://tag/front_door');
        expect(payload['androidPackage'], 'com.jashnm.omniflow_app');
        final decoded = decodeNdef(payload['records'])!;
        expect(decoded.map((r) => (r['tnf'], r['type'])), [
          (tnfWellKnown, 'U'),
          (tnfExternal, 'android.com:pkg'),
        ]);
        expect(tagIdFromNdef(decoded), 'front_door');
      },
    );

    test(
      'refuses a missing tag, a non-tag and an id no link can carry',
      () async {
        expect(
          (await err('tag.write_payload', {'id': 'nope'}))['type'],
          'not_found',
        );
        await ok('device.add', {'id': 'lamp', 'driver': 'phone'});
        expect(
          (await err('tag.write_payload', {'id': 'lamp'}))['type'],
          'invalid',
        );
        final long = 'a' * 70;
        await ok('device.add', {'id': long, 'driver': 'nfc_tag'});
        expect(
          (await err('tag.write_payload', {'id': long}))['type'],
          'invalid',
        );
      },
    );
  });

  group('nfc.scanned from the phone', () {
    setUp(() async {
      await ok('tag.save', {
        'id': 'front_door',
        'name': 'Front door',
        'uid': '04A22B1C',
      });
      await ok('tag.save', {'id': 'desk', 'name': 'Desk', 'uid': '04112233'});
    });

    test(
      'finds the tag by UID and raises scanned on it and the phone',
      () async {
        final scan = await ok('nfc.scanned', {
          'uid': '04:a2:2b:1c',
          'source': 'phone',
          'at': '2026-11-08T08:00:00Z',
        });
        expect(scan, {
          'ok': true,
          'tag': 'front_door',
          'uid': '04A22B1C',
          'source': 'phone',
        });
        expect(await stateOf('front_door'), {
          'last_scanned': '2026-11-08T08:00:00.000Z',
          'last_source': 'phone',
        });
        await until(() => thingEvents().length == 2);
        expect(thingEvents().map((e) => (e.$1, e.$2)), [
          ('front_door', 'scanned'),
          ('phone', 'nfc_scanned'),
        ]);
        expect(thingEvents()[0].$3, {
          'uid': '04A22B1C',
          'source': 'phone',
          'at': '2026-11-08T08:00:00.000Z',
        });
        expect(thingEvents()[1].$3, {
          'uid': '04A22B1C',
          'at': '2026-11-08T08:00:00.000Z',
          'tag': 'front_door',
        });
        expect(unknowns(), isEmpty);
      },
    );

    test('the written id wins over the UID of another tag, which stays '
        'that tag\'s alone', () async {
      await ok('tag.save', {'id': 'hall', 'name': 'Hall'});
      final scan = await ok('nfc.scanned', {
        'uid': '04112233',
        'ndef': [link('hall')],
        'source': 'phone',
      });
      expect(scan['tag'], 'hall');
      expect(scan['ndefId'], 'hall');
      expect((await stateOf('desk')), isNot(contains('last_scanned')));
      expect(
        ((await ok('tag.list', {}))['tags'] as List).firstWhere(
          (t) => t['id'] == 'hall',
        ),
        isNot(contains('uid')),
        reason: 'two tags never share a UID, so hall is not pinned to it',
      );
    });

    test('a written id that names no tag falls back to the UID, and never '
        'reaches a thing that is not a tag', () async {
      await ok('device.add', {'id': 'lamp', 'driver': 'phone'});
      for (final id in ['gone', 'lamp']) {
        final scan = await ok('nfc.scanned', {
          'uid': '04112233',
          'ndef': [link(id)],
          'source': 'phone',
        });
        expect(scan['tag'], 'desk');
        expect(scan['ndefId'], id);
      }
      await until(() => thingEvents().length == 4);
      expect(thingEvents().map((e) => (e.$1, e.$2)), [
        ('desk', 'scanned'),
        ('phone', 'nfc_scanned'),
        ('desk', 'scanned'),
        ('phone', 'nfc_scanned'),
      ]);
    });

    test(
      'an unknown tag raises tag.unknown with the candidate that names it',
      () async {
        await ok('device.add', {'id': 'lamp', 'driver': 'phone'});
        final byUid = await ok('nfc.scanned', {
          'uid': 'DEADBEEF',
          'source': 'phone',
        });
        final carried = await ok('nfc.scanned', {
          'uid': 'DEADBEEF01',
          'ndef': [link('garage')],
          'source': 'phone',
        });
        final taken = await ok('nfc.scanned', {
          'uid': 'DEADBEEF02',
          'ndef': [link('lamp')],
          'source': 'phone',
        });
        expect(byUid['tag'], isNull);
        expect(byUid['add'], {
          'driver': 'nfc_tag',
          'settings': {'uid': 'DEADBEEF'},
        });
        expect(carried['add'], {
          'driver': 'nfc_tag',
          'id': 'garage',
          'settings': {'uid': 'DEADBEEF01'},
        });
        expect(taken['add'], isNot(contains('id')));
        await until(() => unknowns().length == 3);
        expect(unknowns()[1], {
          'event': 'tag.unknown',
          'uid': 'DEADBEEF01',
          'ndefId': 'garage',
          'source': 'phone',
          'add': carried['add'],
        });
        expect(unknowns().first, isNot(contains('ndefId')));
        await until(() => thingEvents().length == 3);
        expect(thingEvents().map((e) => e.$1).toSet(), {'phone'});

        final added = await ok('thing.add', {
          'candidate': carried['add'],
          'name': 'Garage',
        });
        expect(added['id'], 'garage');
        expect(
          (await ok('nfc.scanned', {
            'uid': 'DEADBEEF01',
            'ndef': [link('garage')],
            'source': 'phone',
          }))['tag'],
          'garage',
        );
      },
    );

    test('untrusted input is checked strictly', () async {
      final crafted = [
        {
          'uid': '04112233',
          'ndef': [link('../front_door')],
        },
        {
          'uid': '04112233',
          'ndef': [uriRecord('omniflow://tag/front_door?x=1')],
        },
        {
          'uid': '04112233',
          'ndef': [link('front_door'), link('desk')],
        },
        {
          'uid': '04112233',
          'ndef': [
            {'tnf': 'wellKnown', 'type': 'U', 'payload': '00'},
          ],
        },
        {'uid': '04112233', 'ndef': 'omniflow://tag/front_door'},
        {'uid': '04112233', 'ndef': List.filled(17, link('desk'))},
        {'uid': '0411'},
        {'uid': '04' * 11},
        {'uid': 'not hex'},
        {'uid': 4},
        {
          'ndef': [link('desk')],
        },
        {'uid': '04112233', 'at': 'yesterday'},
      ];
      for (final args in crafted) {
        expect(
          (await err('nfc.scanned', {...args, 'source': 'phone'}))['type'],
          'invalid',
          reason: '$args',
        );
      }
      expect(
        (await err('nfc.scanned', {'uid': '04112233'}))['type'],
        'invalid',
      );
      expect(thingEvents(), isEmpty);
      expect(unknowns(), isEmpty);
      expect(await stateOf('front_door'), isEmpty);
    });
  });

  group('a link is trusted on first use', () {
    Future<Map<String, Object?>> scanLinked(String uid, String id) =>
        ok('nfc.scanned', {
          'uid': uid,
          'ndef': [link(id)],
          'source': 'phone',
          'at': '2026-11-08T08:00:00Z',
        });

    Future<Object?> pinOf(String id) async =>
        ((await ok('tag.list', {}))['tags'] as List).cast<Map>().firstWhere(
          (t) => t['id'] == id,
        )['uid'];

    List<Map<String, Object?>> mismatches() => [
      for (final e in events)
        if (e['event'] == 'tag.mismatch') e,
    ];

    setUp(() => ok('tag.save', {'id': 'shelf', 'name': 'Shelf'}));

    test('the first scan by link pins the card\'s UID', () async {
      expect(await pinOf('shelf'), isNull);
      final scan = await scanLinked('04:aa:bb:cc', 'shelf');
      expect(scan['tag'], 'shelf');
      expect(scan, isNot(contains('mismatch')));
      expect(await pinOf('shelf'), '04AABBCC');
      await until(() => thingEvents().length == 2);
      expect(thingEvents().first.$1, 'shelf');
    });

    test('a card with the link and another UID is refused and raises '
        'tag.mismatch', () async {
      await scanLinked('04AABBCC', 'shelf');
      await until(() => thingEvents().length == 2);
      events.clear();
      final forged = await scanLinked('04DDEEFF', 'shelf');
      expect(forged, {
        'ok': true,
        'tag': null,
        'uid': '04DDEEFF',
        'ndefId': 'shelf',
        'source': 'phone',
        'mismatch': 'shelf',
      });
      await until(() => mismatches().isNotEmpty);
      expect(mismatches().single, {
        'event': 'tag.mismatch',
        'tag': 'shelf',
        'expectedUid': '04AABBCC',
        'uid': '04DDEEFF',
        'source': 'phone',
      });
      await until(() => thingEvents().isNotEmpty);
      expect(thingEvents().map((e) => (e.$1, e.$2)), [
        ('phone', 'nfc_scanned'),
      ], reason: 'the tag does not fire, the reader still saw a card');
      expect(thingEvents().single.$3, isNot(contains('tag')));
      expect(unknowns(), isEmpty);
      expect(await pinOf('shelf'), '04AABBCC');
    });

    test('clearing the pin lets the next card re-pin it', () async {
      await scanLinked('04AABBCC', 'shelf');
      await ok('tag.save', {'id': 'shelf', 'name': 'Shelf', 'uid': null});
      expect(await pinOf('shelf'), isNull);
      expect((await scanLinked('04DDEEFF', 'shelf'))['tag'], 'shelf');
      expect(await pinOf('shelf'), '04DDEEFF');
      expect(
        (await scanLinked('04AABBCC', 'shelf'))['mismatch'],
        'shelf',
        reason: 'the old card is now the one that differs',
      );
    });

    test('a scan by UID alone is unaffected', () async {
      await ok('tag.save', {
        'id': 'front_door',
        'name': 'Front door',
        'uid': '04A22B1C',
      });
      await scanLinked('04AABBCC', 'shelf');
      final byUid = await ok('nfc.scanned', {
        'uid': '04AABBCC',
        'source': 'phone',
      });
      expect(byUid['tag'], 'shelf');
      expect(byUid, isNot(contains('mismatch')));
      expect(
        (await ok('nfc.scanned', {
          'uid': '04A22B1C',
          'source': 'phone',
        }))['tag'],
        'front_door',
      );
      final unknown = await ok('nfc.scanned', {
        'uid': '04DDEEFF',
        'source': 'phone',
      });
      expect(unknown['tag'], isNull);
      expect(unknown['add'], isNotNull);
      expect(mismatches(), isEmpty);
      expect(await pinOf('shelf'), '04AABBCC');
    });
  });

  group('nfc.scanned from a board', () {
    setUp(() async {
      await ok('device.add', {
        'id': 'desk_board',
        'driver': 'omniflow_board',
        'host': '192.0.2.30',
        'provision': false,
      });
      await ok('tag.save', {
        'id': 'desk',
        'name': 'Desk',
        'uid': '04a1b2c3d4e5f6',
      });
    });

    test('raises scanned on the tag and nfc.scanned on the board', () async {
      final scan = await ok('nfc.scanned', {
        'uid': '04a1b2c3d4e5f6',
        'source': 'desk_board',
      });
      expect(scan['tag'], 'desk');
      expect(scan['source'], 'desk_board');
      expect(await stateOf('desk'), containsPair('last_source', 'desk_board'));
      await until(() => thingEvents().length == 2);
      expect(thingEvents()[0].$3, containsPair('source', 'desk_board'));
      expect(thingEvents().map((e) => (e.$1, e.$2)), [
        ('desk', 'scanned'),
        ('desk_board', 'nfc.scanned'),
      ]);
      await ok('nfc.scanned', {'uid': '04010203', 'source': 'desk_board'});
      await until(() => unknowns().length == 1);
      expect(unknowns().single, containsPair('source', 'desk_board'));
    });

    test('a UDP nfc.scanned line counts only from a board', () async {
      final socket = await UdpTransport.bind();
      addTearDown(socket.close);
      socket.incoming.listen((d) {
        final cmd = jsonDecode(d.text) as Map;
        void reply(Map<String, Object?> m) =>
            socket.send(d.address, d.port, utf8.encode(jsonEncode(m)));
        reply({'node': 'deskb', 'event': 'ack', 'id': cmd['id']});
        reply({'node': 'x', 'event': 'nfc.scanned', 'uid': '04a1b2c3d4e5f6'});
        reply({'node': 'x', 'event': 'boot_done'});
      });
      await ok('device.add', {
        'id': 'local_board',
        'driver': 'omniflow_board',
        'host': '127.0.0.1',
        'port': socket.localPort,
        'stableId': 'deskb',
        'provision': false,
      });
      await ok('device.add', {
        'id': 'lamp',
        'driver': 'philips_wiz_udp',
        'host': '127.0.0.1',
      });
      await ok('device.invoke', {
        'id': 'local_board',
        'capability': 'ir_nec',
        'params': {'address': 4, 'command': 8},
      });
      await until(() => thingEvents().any((e) => e.$2 == 'boot_done'));
      expect(thingEvents().map((e) => (e.$1, e.$2)), [('lamp', 'boot_done')]);
      expect(await stateOf('desk'), isEmpty);
    });

    test('the source is the phone or a board', () async {
      await ok('tag.save', {'id': 'other', 'name': 'Other'});
      for (final source in ['nowhere', 'other', '', 7]) {
        expect(
          (await err('nfc.scanned', {
            'uid': '04a1b2c3d4e5f6',
            'source': source,
          }))['type'],
          'invalid',
          reason: '$source',
        );
      }
    });
  });

  test('the CLI adds, lists, writes, scans and removes tags', () async {
    await engine.close();
    await sub.cancel();
    Future<(int, Map<String, Object?>)> omni(List<String> args) async {
      final out = StringBuffer();
      final code = await OmniCommandRunner(
        out: out,
        engineFactory: (h, {tap}) =>
            OmniEngine.open(home: h, secrets: secrets, tap: tap),
      ).run(['--home', home.path, ...args]);
      return (code, jsonDecode(out.toString()) as Map<String, Object?>);
    }

    var (code, out) = await omni([
      'tag',
      'add',
      'front_door',
      'Front door',
      '--uid',
      '04:A2:2B:1C',
    ]);
    expect(code, 0);
    expect(out['tag'], containsPair('uid', '04A22B1C'));
    (code, out) = await omni(['tag', 'list']);
    expect((out['tags'] as List).single, containsPair('id', 'front_door'));
    (code, out) = await omni(['tag', 'payload', 'front_door']);
    expect(out['uri'], 'omniflow://tag/front_door');
    (code, out) = await omni(['tag', 'scan', '04A22B1C']);
    expect((code, out['tag'], out['source']), (0, 'front_door', 'phone'));
    (code, out) = await omni([
      'tag',
      'scan',
      '04999999',
      '--uri',
      'omniflow://tag/front_door',
    ]);
    expect((code, out['tag'], out['mismatch']), (0, null, 'front_door'));
    (code, out) = await omni(['phone', 'nfc', '04A22B1C', 'front_door']);
    expect(out['tag'], 'front_door');
    (code, out) = await omni(['tag', 'scan', '04A22B1C', '--source', 'desk']);
    expect(code, 1);
    expect(out['error'], containsPair('type', 'invalid'));
    (code, out) = await omni(['tag', 'remove', 'front_door']);
    expect((code, out['removed']), (0, true));
    expect(
      () => omni(['tag', 'add', 'only_id']),
      throwsA(isA<UsageException>()),
    );

    (code, out) = await omni(['phone', 'wifi', 'HomeNet']);
    expect(code, 0);
    (code, out) = await omni(['phone', 'ble', 'OMNI_PICO_DESK', '-55']);
    expect(code, 0);
    (code, out) = await omni(['device', 'get', 'phone']);
    expect(
      (out['device'] as Map)['state'],
      containsPair('wifi_ssid', 'HomeNet'),
    );

    engine = await OmniEngine.open(home: home, secrets: secrets);
    sub = engine.events.listen(events.add);
  });
}
