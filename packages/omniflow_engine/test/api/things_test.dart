import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

/// Waits until [done] holds, failing after five seconds.
Future<void> until(FutureOr<bool> Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Map<String, Object?> edge(String from, String port, String to) => {
  'id': '$from-$to',
  'from': {'node': from, 'port': port},
  'to': {'node': to, 'port': 'in'},
};

/// A flow that announces [title] when [trigger] fires.
Map<String, Object?> announceOn(
  String id,
  Map<String, Object?> trigger,
  String title,
) => {
  'schemaVersion': 1,
  'id': id,
  'name': id,
  'mode': 'parallel',
  'nodes': [
    {'id': 't', 'type': 'on', 'config': trigger},
    {
      'id': 'say',
      'type': 'notify',
      'config': {'title': title},
    },
  ],
  'edges': [edge('t', 'out', 'say')],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  Future<void> open() async {
    engine = await OmniEngine.open(home: home, secrets: InMemorySecretStore());
    events = [];
    sub = engine.events.listen(events.add);
  }

  Future<void> close() async {
    await sub.cancel();
    await engine.close();
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_things');
    await open();
  });

  tearDown(() async {
    await close();
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

  /// What automations announced. The built-in alerts are left out.
  List<String> announced() => [
    for (final e in events)
      if (e['event'] == 'flow.announce' && e['alert'] == null)
        e['title'] as String,
  ];

  List<(Object?, Object?)> thingEvents() => [
    for (final e in events)
      if (e['event'] == 'thing.event') (e['thing'], e['key']),
  ];

  test(
    'a restart while home is not an arrival, and leaving still is',
    () async {
      await ok('zone.save', {
        'zone': {
          'id': 'home',
          'name': 'Home',
          'wifi': {
            'ssids': ['HomeNet'],
            'awayAfterMs': 0,
          },
        },
      });
      await ok('device.add', {'id': 'jade', 'driver': 'person'});
      await ok('flow.save', {
        'flow': announceOn('arrive', {
          'thing': 'jade',
          'key': 'home',
          'change': {'to': true},
        }, 'welcome'),
      });
      await ok('flow.save', {
        'flow': announceOn('leave', {
          'thing': 'jade',
          'key': 'home',
          'change': {'to': false},
        }, 'bye'),
      });
      await ok('phone.wifi', {'ssid': 'HomeNet'});
      await until(() => announced().contains('welcome'));

      await close();
      await open();
      expect((await stateOf('jade'))['home'], isTrue);
      await ok('phone.wifi', {'ssid': 'HomeNet'});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(announced(), isEmpty, reason: 'the restart is not an arrival');

      await ok('phone.wifi', {'ssid': 'Cafe'});
      await until(() => announced().contains('bye'));
    },
  );

  test('jade.home turns true on arrival and false on leaving', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'home',
        'name': 'Home',
        'wifi': {
          'ssids': ['HomeNet'],
          'awayAfterMs': 0,
        },
      },
    });
    await ok('device.add', {'id': 'jade', 'driver': 'person'});
    await ok('flow.save', {
      'flow': announceOn('arrive', {
        'thing': 'jade',
        'key': 'home',
        'change': {'to': true},
      }, 'welcome'),
    });
    await ok('flow.save', {
      'flow': announceOn('leave', {
        'thing': 'jade',
        'key': 'home',
        'change': {'to': false},
      }, 'bye'),
    });
    expect(await stateOf('jade'), {'home': false, 'place': null});

    await ok('phone.wifi', {'ssid': 'HomeNet', 'bssid': 'aa:bb'});
    await until(() => announced().contains('welcome'));
    expect(await stateOf('jade'), {
      'home': true,
      'place': 'home',
      'homeSource': 'wifi',
      'homeSince': isA<String>(),
    });
    expect(await stateOf('home'), {
      'inside': true,
      'people': ['jade'],
    });
    expect(await stateOf('phone'), {
      'wifi_ssid': 'HomeNet',
      'wifi_bssid': 'aa:bb',
    });

    await ok('phone.wifi', {'ssid': 'Cafe'});
    await until(() => announced().contains('bye'));
    expect(await stateOf('jade'), {
      'home': false,
      'place': null,
      'homeSource': 'wifi',
      'homeSince': isA<String>(),
    });
    expect(announced(), ['welcome', 'bye']);
  });

  test('editing a place while inside fires no exit or entry', () async {
    final office = {
      'id': 'office',
      'name': 'Office',
      'wifi': {
        'ssids': ['OfficeNet'],
      },
    };
    await ok('zone.save', {'zone': office});
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'name': 'Desk',
        'ble': {'matchName': 'OMNI_DESK'},
      },
    });
    for (final (id, place, to) in [
      ('left', 'office', false),
      ('came', 'office', true),
      ('left_desk', 'desk', false),
    ]) {
      await ok('flow.save', {
        'flow': announceOn(id, {
          'thing': place,
          'key': 'inside',
          'change': {'to': to},
        }, id),
      });
    }
    await ok('phone.wifi', {'ssid': 'OfficeNet'});
    final at = DateTime.utc(2026, 1, 1);
    for (var s = 0; s <= 3; s++) {
      await ok('phone.ble', {
        'name': 'OMNI_DESK',
        'rssi': -50,
        'at': at.add(Duration(seconds: s)).toIso8601String(),
      });
    }
    await until(() => announced().contains('came'));
    expect((await stateOf('desk'))['inside'], isTrue);
    events.clear();

    Future<Object?> zoneGlobal(String id) async =>
        ((await ok('var.list', {}))['variables'] as Map)['Zone_$id'];

    await ok('zone.save', {
      'zone': {...office, 'name': 'Office 2'},
    });
    await ok('zone.save', {
      'zone': {
        ...office,
        'wifi': {
          'ssids': ['OfficeNet', 'Office5G'],
        },
      },
    });
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'name': 'Desk 3',
        'ble': {'matchName': 'OMNI_DESK'},
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await stateOf('office'))['inside'], isTrue);
    expect((await stateOf('desk'))['inside'], isTrue);
    expect(await zoneGlobal('office'), isTrue);

    await ok('zone.save', {
      'zone': {
        ...office,
        'wifi': {
          'ssids': ['Elsewhere'],
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await stateOf('office'))['inside'], isFalse);
    expect(await zoneGlobal('office'), isFalse);
    expect(announced(), isEmpty);
    expect(events.where((e) => e['event'] == 'zone.changed'), isEmpty);
  });

  test('a person takes the place they reached last, and homePlace', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'flat',
        'wifi': {
          'ssids': ['HomeNet'],
          'awayAfterMs': 0,
        },
      },
    });
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'ble': {'matchName': 'OMNI_DESK', 'enterDwellMs': 0},
      },
    });
    await ok('device.add', {
      'id': 'jade',
      'driver': 'person',
      'settings': {'homePlace': 'flat'},
    });
    await ok('sensor.wifi', {'ssid': 'HomeNet'});
    expect(await stateOf('jade'), {
      'home': true,
      'place': 'flat',
      'homeSource': 'wifi',
      'homeSince': isA<String>(),
    });
    final start = DateTime(2026, 11, 7, 9);
    for (var i = 0; i < 4; i++) {
      await ok('sensor.ble', {
        'name': 'OMNI_DESK',
        'rssi': -50,
        'at': start.add(Duration(milliseconds: 250 * i)).toIso8601String(),
      });
    }
    expect(await stateOf('jade'), {
      'home': true,
      'place': 'desk',
      'homeSource': 'wifi',
      'homeSince': isA<String>(),
    });
    final zones = (await ok('zone.list', {}))['zones'] as List;
    expect(
      {for (final z in zones.cast<Map>()) z['id']: z['inside']},
      {'flat': true, 'desk': true},
    );
  });

  test('sensor.wifi and sensor.ble feed the phone thing', () async {
    final listed = (await ok('device.list', {}))['devices'] as List;
    expect(listed, isEmpty);
    final reply = await ok('sensor.wifi', {'ssid': 'HomeNet'});
    expect(reply['zones'], isEmpty);
    expect((await stateOf('phone'))['wifi_ssid'], 'HomeNet');
    final vars = (await ok('var.list', {}))['variables'] as Map;
    expect(vars['WifiSsid'], 'HomeNet');
    final phone =
        ((await ok('device.list', {'withCapabilities': true}))['devices']
                as List)
            .cast<Map>()
            .single;
    expect(phone['driver'], 'phone');
    expect(phone['host'], 'virtual');
    final caps = {
      for (final c in (phone['capabilities'] as List).cast<Map>())
        c['id']: c['type'],
    };
    expect(caps['nfc_scanned'], 'event');
    expect(caps['battery'], 'sensor');
    expect(
      (await err('device.invoke', {
        'id': 'phone',
        'capability': 'nfc_scanned',
      }))['type'],
      'invalid',
    );
  });

  test('the battery feeds the phone, and a crossing fires once', () async {
    await ok('phone.battery', {'level': 50, 'charging': false});
    await ok('flow.save', {
      'flow': announceOn('low', {
        'thing': 'phone',
        'key': 'battery',
        'crosses': {'below': 20},
      }, 'charge me'),
    });
    for (final level in [30, 15, 12, 25, 10]) {
      await ok('phone.battery', {'level': level});
    }
    await until(() => announced().length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(announced(), ['charge me', 'charge me']);
    expect(await stateOf('phone'), {'battery': 10, 'charging': false});
    expect((await err('phone.battery', {'level': 120}))['type'], 'invalid');
    expect((await err('phone.battery', {}))['type'], 'invalid');
  });

  test(
    'an NFC scan raises scanned on the matching tag and the phone',
    () async {
      await ok('tag.save', {
        'id': 'front_door',
        'name': 'Front door',
        'uid': '04:A2:2B:1C',
      });
      await ok('tag.save', {'id': 'desk_tag', 'name': 'Desk'});
      await ok('flow.save', {
        'flow': announceOn('door', {
          'thing': 'front_door',
          'key': 'scanned',
          'event': true,
        }, 'door tag'),
      });
      await ok('flow.save', {
        'flow': announceOn('any_tag', {
          'thing': 'phone',
          'key': 'nfc_scanned',
          'event': true,
          'match': {'tag': 'desk_tag'},
        }, 'desk tag'),
      });

      final scan = await ok('nfc.scanned', {
        'uid': '04a22b1c',
        'source': 'phone',
        'at': '2026-11-07T09:00:00Z',
      });
      expect(scan['tag'], 'front_door');
      expect(await stateOf('front_door'), {
        'last_scanned': '2026-11-07T09:00:00.000Z',
        'last_source': 'phone',
      });
      expect(
        (await ok('nfc.scanned', {
          'uid': '04112233',
          'source': 'phone',
          'ndef': [uriRecord('omniflow://tag/desk_tag')],
        }))['tag'],
        'desk_tag',
      );
      expect(
        (await ok('nfc.scanned', {
          'uid': 'FFEEDDCC',
          'source': 'phone',
        }))['tag'],
        isNull,
      );
      await until(() => announced().length == 2);
      await until(() => thingEvents().length == 5);
      expect(announced(), unorderedEquals(['door tag', 'desk tag']));
      expect(thingEvents(), [
        ('front_door', 'scanned'),
        ('phone', 'nfc_scanned'),
        ('desk_tag', 'scanned'),
        ('phone', 'nfc_scanned'),
        ('phone', 'nfc_scanned'),
      ]);
      expect(
        (await err('nfc.scanned', {
          'uid': 'not hex',
          'source': 'phone',
        }))['type'],
        'invalid',
      );
      expect(
        (await err('nfc.scanned', {'source': 'phone'}))['type'],
        'invalid',
      );
      expect(
        (await err('device.add', {
          'id': 'bad_tag',
          'driver': 'nfc_tag',
          'settings': {'uid': 'xyz'},
        }))['type'],
        'invalid',
      );
    },
  );

  test('a flow saved with old types is stored migrated', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'ble': {'matchName': 'OMNI_DESK'},
      },
    });
    await ok('flow.save', {
      'flow': {
        'schemaVersion': 1,
        'id': 'old_style',
        'name': 'Old style',
        'nodes': [
          {
            'id': 't',
            'type': 'wifi_change',
            'config': {'ssid': 'HomeNet'},
          },
          {
            'id': 'c',
            'type': 'var_equals',
            'config': {'name': r'$Mode', 'value': 'home'},
          },
          {
            'id': 'say',
            'type': 'notify',
            'config': {'title': 'hi'},
          },
        ],
        'edges': [edge('t', 'out', 'c'), edge('c', 'true', 'say')],
      },
    });
    final flow = (await ok('flow.get', {'id': 'old_style'}))['flow'] as Map;
    final nodes = (flow['nodes'] as List).cast<Map>();
    expect(nodes.map((n) => n['type']), ['on', 'compare', 'notify']);
    expect(nodes.first['config'], {
      'thing': 'phone',
      'key': 'wifi_ssid',
      'change': {'to': 'HomeNet'},
    });
    expect(engine.flows.loadedFlows, contains('old_style'));
    await ok('var.set', {'name': 'Mode', 'value': 'home'});
    await ok('phone.wifi', {'ssid': 'HomeNet'});
    await until(() => announced().contains('hi'));
  });

  test('stored zones become places and old flows migrate at open', () async {
    await ok('device.add', {
      'id': 'office',
      'driver': 'philips_wiz_udp',
      'host': '192.0.2.10',
    });
    await close();
    final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
    await DriftZoneStore(db).put('desk', {
      'id': 'desk',
      'name': 'Desk',
      'ble': {'matchName': 'OMNI_DESK'},
    });
    await DriftZoneStore(db).put('office', {
      'id': 'office',
      'wifi': {
        'ssids': ['Work'],
      },
    });
    await DriftZoneStore(db).put('broken', {'id': 'broken'});
    final at = DateTime.utc(2026);
    Future<void> putFlow(String id, Map<String, Object?> trigger) =>
        DriftFlowStore(db).put(
          id,
          {
            'schemaVersion': 1,
            'id': id,
            'name': id,
            'nodes': [
              trigger,
              {
                'id': 'c',
                'type': 'device_state_is',
                'config': {
                  'deviceId': 'office',
                  'key': 'state',
                  'value': false,
                },
              },
              {
                'id': 'say',
                'type': 'notify',
                'config': {'title': id},
              },
            ],
            'edges': [edge('t', 'out', 'c'), edge('c', 'true', 'say')],
          },
          enabled: true,
          approved: true,
          trusted: true,
          at: at,
        );
    await putFlow('at_work', {
      'id': 't',
      'type': 'zone_change',
      'config': {'zoneId': 'office', 'transition': 'entered'},
    });
    await putFlow('any_board', {
      'id': 't',
      'type': 'board_event',
      'config': {'event': 'boot'},
    });
    await db.close();

    await open();
    final devices = {
      for (final d
          in ((await ok('device.list', {}))['devices'] as List).cast<Map>())
        d['id']: d,
    };
    expect(devices['desk']!['driver'], 'place');
    expect(devices['desk']!['name'], 'Desk');
    expect(devices['office']!['driver'], 'philips_wiz_udp');
    expect(devices['office_place']!['settings'], {
      'wifi': {
        'ssids': ['Work'],
        'bssids': <String>[],
        'required': false,
      },
      'zone': 'office',
    });
    final zones = (await ok('zone.list', {}))['zones'] as List;
    expect(zones.cast<Map>().map((z) => (z['id'], z['place'])), [
      ('desk', 'desk'),
      ('office', 'office_place'),
    ]);

    final flow = (await ok('flow.get', {'id': 'at_work'}))['flow'] as Map;
    final nodes = (flow['nodes'] as List).cast<Map>();
    expect(nodes.first['config'], {
      'thing': 'office_place',
      'key': 'inside',
      'change': {'to': true},
    });
    expect(nodes[1]['type'], 'compare');
    expect(engine.flows.loadedFlows, ['at_work']);
    final issues = engine.loadIssues;
    expect(issues.where((i) => i['kind'] == 'zone').map((i) => i['id']), [
      'broken',
    ]);
    expect(
      issues.firstWhere((i) => i['id'] == 'any_board')['error'],
      contains('cannot be migrated'),
    );

    await engine.devices.mergeState('office', {'state': false});
    await ok('sensor.wifi', {'ssid': 'Work'});
    await until(() => announced().contains('at_work'));
    expect(
      ((await ok('var.list', {}))['variables'] as Map)['Zone_office'],
      isTrue,
    );
    expect(
      events.where((e) => e['event'] == 'zone.changed').single,
      allOf(
        containsPair('zone', 'office'),
        containsPair('place', 'office_place'),
      ),
    );

    await close();
    final after = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
    expect((await DriftZoneStore(after).all()).map((z) => z['id']), ['broken']);
    await after.close();
    await open();
  });

  test('zone.remove removes the place and disables its flows', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'desk',
        'ble': {'matchName': 'OMNI_DESK'},
      },
    });
    await ok('flow.save', {
      'flow': announceOn('at_desk', {
        'thing': 'desk',
        'key': 'inside',
        'change': {'to': true},
      }, 'desk'),
    });
    final removed = await ok('zone.remove', {'id': 'desk'});
    expect(removed['removed'], isTrue);
    expect(removed['flows'], ['at_desk']);
    expect((await ok('zone.list', {}))['zones'], isEmpty);
    expect((await ok('zone.remove', {'id': 'desk'}))['removed'], isFalse);
    await ok('sensor.wifi', {'ssid': 'x'});
    final phoneZone = {
      'id': 'phone',
      'wifi': {
        'ssids': ['x'],
      },
    };
    final saved = await ok('zone.save', {'zone': phoneZone});
    expect(saved, containsPair('place', 'phone_place'));
    expect(saved, containsPair('id', 'phone'));
    expect(
      (await ok('zone.save', {'zone': phoneZone}))['place'],
      'phone_place',
    );
    final listed = (await ok('zone.list', {}))['zones'] as List;
    expect(listed.single, containsPair('id', 'phone'));
    expect(listed.single, containsPair('place', 'phone_place'));
    expect(listed.single, containsPair('inside', true));
    expect(
      ((await ok('device.get', {'id': 'phone'}))['device'] as Map)['driver'],
      'phone',
    );
  });

  test('a board button press is an event on the board', () async {
    final board = await UdpTransport.bind();
    addTearDown(board.close);
    board.incoming.listen((d) {
      final cmd = jsonDecode(d.text) as Map;
      void reply(Map<String, Object?> m) =>
          board.send(d.address, d.port, utf8.encode(jsonEncode(m)));
      reply({'node': 'deskb', 'event': 'ack', 'id': cmd['id']});
      reply({'node': 'deskb', 'event': 'pin.changed', 'pin': 0, 'value': 0});
    });
    await ok('device.add', {
      'id': 'desk_board',
      'driver': 'omniflow_board',
      'host': '127.0.0.1',
      'port': board.localPort,
      'stableId': 'deskb',
      'provision': false,
      'settings': {
        'pins': {
          'button': {'pin': 0, 'mode': 'in_pullup'},
        },
      },
    });
    await ok('flow.save', {
      'flow': announceOn('press', {
        'thing': 'desk_board',
        'key': 'button.pressed',
        'event': true,
      }, 'pressed'),
    });
    await ok('device.invoke', {
      'id': 'desk_board',
      'capability': 'ir_nec',
      'params': {'address': 4, 'command': 8},
    });
    await until(() => announced().contains('pressed'));
    expect(
      thingEvents(),
      containsAll([
        ('desk_board', 'button.changed'),
        ('desk_board', 'button.pressed'),
      ]),
    );
    expect(thingEvents(), isNot(contains(('desk_board', 'button.released'))));
    expect((await stateOf('desk_board'))['button'], isTrue);
    expect(events.where((e) => e['event'] == 'board.event'), isNotEmpty);
  });
}
