@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import '../devices/http_hubs_test.dart' show FakeHueBridge;
import '../support/virtual_board.dart';
import 'things_test.dart' show edge, until;

/// A light with no wire under it: the engine's optimistic state becomes its
/// state, so a rule's steps can be checked by reading it back.
const _testLight = {
  'schemaVersion': 1,
  'id': 'test_light',
  'name': 'Test light',
  'category': 'light',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'set': 'power', 'value': '{{value}}'},
      'stateJsonPath': r'$.power',
    },
    {
      'id': 'temp',
      'type': 'sensor',
      'label': 'Temperature',
      'stateJsonPath': r'$.temp',
    },
  ],
};

/// A light behind a bridge that pairs with its link button, then takes a
/// scene key the user pastes, then needs its light number: every setup
/// step there is, in that order.
const _bridgeLight = {
  'schemaVersion': 1,
  'id': 'bridge_light',
  'name': 'Bridge light',
  'category': 'lighting',
  'transport': {
    'type': 'http',
    'port': 80,
    'authErrorTypes': [1],
  },
  'pairing': {'method': 'hue_bridge'},
  'settings': [
    {'key': 'lightId', 'label': 'Light number'},
    {'key': 'username', 'label': 'Bridge username', 'secret': true},
    {'key': 'sceneKey', 'label': 'Scene key', 'secret': true},
  ],
  'setup': ['pair', 'secret:sceneKey', 'configure:lightId'],
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {
        'method': 'PUT',
        'path': '/api/:secret:username/lights/{{device.lightId}}/state',
        'body': {'on': '{{value}}'},
      },
      'stateJsonPath': r'$.on',
    },
  ],
};

/// Every source of the unified model, end to end through
/// [OmniEngine.handle]: a phone NFC scan, a board's NFC reader, arriving
/// home by Wi-Fi and by BLE, a sensor crossing a threshold, and flows
/// stored before the unification. Each one runs a rule saved with
/// `automation.save`.
Future<void> main() async {
  final noCompiler = await VirtualBoard.build() == null;
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;
  final boards = <VirtualBoard>[];

  Future<void> open() async {
    engine = await OmniEngine.open(
      home: home,
      secrets: InMemorySecretStore(),
      discoveryTargets: () async => [InternetAddress.loopbackIPv4],
      mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
    );
    events = [];
    sub = engine.events.listen(events.add);
  }

  Future<void> close() async {
    await sub.cancel();
    await engine.close();
  }

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command -> $result');
    return result;
  }

  Future<Map<String, Object?>> stateOf(String id) async =>
      Map<String, Object?>.from(
        ((await ok('device.get', {'id': id}))['device'] as Map)['state'] as Map,
      );

  List<Object?> announced() => [
    for (final e in events)
      if (e['event'] == 'flow.announce') e['title'],
  ];

  Future<Map<String, Object?>> saveRule(Map<String, Object?> rule) =>
      ok('automation.save', {'form': 'rule', 'spec': rule, 'trusted': true});

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_unified');
    await open();
    await ok('driver.register', {'manifest': _testLight});
    for (final id in ['lamp', 'fan', 'room']) {
      await ok('device.add', {'id': id, 'driver': 'test_light'});
    }
  });

  tearDown(() async {
    for (final b in boards) {
      await b.stop();
    }
    boards.clear();
    await close();
    await home.delete(recursive: true);
  });

  test('a phone NFC scan runs a rule across devices, by UID and by the id '
      'written on the tag', () async {
    await ok('device.add', {
      'id': 'front_door',
      'name': 'Front door',
      'driver': 'nfc_tag',
      'settings': {'uid': '04:A2:2B:1C'},
    });
    await saveRule({
      'name': 'Front door',
      'when': ['nfc:front_door'],
      'then': [
        'lamp.power=true',
        'wait:20ms',
        {
          'together': [
            ['fan.power=true'],
            ['notify:Door open'],
          ],
        },
        r'set:$Door=open',
      ],
      'mode': 'queued',
    });

    final scan = await ok('nfc.scanned', {
      'uid': '04a22b1c',
      'source': 'phone',
    });
    expect(scan['tag'], 'front_door');
    await until(() async => engine.flows.globals['Door'] == 'open');
    expect((await stateOf('lamp'))['power'], isTrue);
    expect((await stateOf('fan'))['power'], isTrue);
    expect(announced(), ['Door open']);
    final runs = (await ok('automation.log', {'id': 'front_door'}))['runs'];
    expect((runs as List).single, containsPair('outcome', 'completed'));

    // The phone writes the tag, then Android hands a later read of it to
    // the app as NDEF records. The link is pinned to the tag's UID, so the
    // same link copied onto another card does not run the rule.
    final written = await ok('tag.write_payload', {'id': 'front_door'});
    expect(written['uri'], 'omniflow://tag/front_door');
    expect(written['androidPackage'], omniflowApplicationId);
    final records = (written['records'] as List).cast<Map<String, Object?>>();
    expect(records.map((r) => r['tnf']), [tnfWellKnown, tnfExternal]);
    final again = await ok('nfc.scanned', {
      'uid': '04A22B1C',
      'ndef': records,
      'source': 'phone',
    });
    expect(again['tag'], 'front_door');
    expect(again['ndefId'], 'front_door');
    await until(() => announced().length == 2);
    final copied = await ok('nfc.scanned', {
      'uid': '0499AA01',
      'ndef': records,
      'source': 'phone',
    });
    expect((copied['tag'], copied['mismatch']), (null, 'front_door'));

    final unknown = engine.events.firstWhere(
      (e) => e['event'] == 'tag.unknown',
    );
    final stray = await ok('nfc.scanned', {
      'uid': 'DEADBEEF',
      'source': 'phone',
    });
    expect(stray['tag'], isNull);
    expect(stray['add'], {
      'driver': 'nfc_tag',
      'settings': {'uid': 'DEADBEEF'},
    });
    expect(
      await unknown,
      allOf(containsPair('source', 'phone'), containsPair('uid', 'DEADBEEF')),
    );
    final named = await ok('thing.add', {
      'candidate': stray['add'],
      'name': 'Desk drawer',
    });
    expect(named['id'], 'desk_drawer');
    expect(
      (await ok('nfc.scanned', {'uid': 'DEADBEEF', 'source': 'phone'}))['tag'],
      'desk_drawer',
    );
  });

  test('a board NFC reader set with periph.set runs a rule across the board '
      'and other devices', () async {
    final b = await VirtualBoard.start(node: 'desk_board', pty: true);
    boards.add(b);
    await ok('device.add', {
      'id': 'desk',
      'driver': 'omniflow_board',
      'host': b.tty,
      'settings': {
        'pins': {
          'relay': {'pin': 2, 'mode': 'out'},
        },
      },
    });
    await ok('device.add', {
      'id': 'desk_tag',
      'driver': 'nfc_tag',
      'settings': {'uid': '04a1b2c3d4e5f6'},
    });
    final byBoard = {
      'name': 'Seen at the desk',
      'when': ['event:desk.nfc.scanned'],
      'then': [r'set:$DeskReader=true'],
    };
    Future<List<Object?>> deskEvents() async => [
      for (final c
          in ((await ok('device.list', {'withCapabilities': true}))['devices']
                      as List)
                  .cast<Map>()
                  .firstWhere((d) => d['id'] == 'desk')['capabilities']
              as List)
        if ((c as Map)['type'] == 'event') c['id'],
    ];
    expect(await deskEvents(), isNot(contains('nfc.scanned')));

    final set = await ok('board.periph', {
      'id': 'desk',
      'type': 'nfc_rc522',
      'pins': {'ss': 8, 'rst': 9},
    });
    expect(set['periph'], [
      {
        'type': 'nfc_rc522',
        'pins': {'ss': 8, 'rst': 9, 'sck': 13, 'miso': 12, 'mosi': 11},
      },
    ]);
    expect(set['periphTypes'], containsAll(['nfc_rc522', 'nfc_pn532']));
    final desk = (await ok('device.get', {'id': 'desk'}))['device'] as Map;
    // The native board has IR and RF built in, so its describe flags add
    // them after the reader periph.set bound.
    expect((desk['settings'] as Map)['periph'], ['nfc_rc522', 'ir', 'rf']);
    expect(await deskEvents(), contains('nfc.scanned'));

    await saveRule(byBoard);
    await saveRule({
      'name': 'Desk tag',
      'when': ['nfc:desk_tag'],
      'then': [
        'desk.relay=true',
        'lamp.power=true',
        {
          'notify': {'title': 'Desk tag'},
        },
      ],
    });
    await engine.devices.sendCommand('desk', {
      'cmd': 'sim.nfc',
      'uid': '04a1b2c3d4e5f6',
      'ms': 300,
    });
    await until(() => announced().contains('Desk tag'));
    await until(() async => engine.flows.globals['DeskReader'] == true);
    expect((await stateOf('lamp'))['power'], isTrue);
    final relay = await engine.devices.sendCommand('desk', {
      'cmd': 'pin.read',
      'pin': 2,
    });
    expect(relay.json?['value'], 1);
    final thingEvents = [
      for (final e in events)
        if (e['event'] == 'thing.event') (e['thing'], e['key']),
    ];
    expect(
      thingEvents,
      containsAll([('desk', 'nfc.scanned'), ('desk_tag', 'scanned')]),
    );
    expect((await stateOf('desk_tag'))['last_scanned'], isA<String>());

    final unknown = engine.events.firstWhere(
      (e) => e['event'] == 'tag.unknown',
    );
    await engine.devices.sendCommand('desk', {
      'cmd': 'sim.nfc',
      'uid': 'deadbeef',
    });
    expect(
      await unknown.timeout(const Duration(seconds: 5)),
      allOf(containsPair('source', 'desk'), containsPair('uid', 'DEADBEEF')),
    );

    final cleared = await ok('board.periph', {
      'id': 'desk',
      'type': 'nfc_rc522',
      'clear': true,
    });
    expect(cleared['periph'], isEmpty);
    expect(await deskEvents(), isNot(contains('nfc.scanned')));
  }, skip: noCompiler ? 'no C++ compiler for the virtual board' : null);

  test('a board on Wi-Fi takes no peripheral', () async {
    await ok('device.add', {
      'id': 'shelf',
      'driver': 'omniflow_board',
      'host': '192.0.2.20',
      'provision': false,
    });
    final refused = await engine.handle('board.periph', {
      'id': 'shelf',
      'type': 'nfc_pn532',
    });
    expect(refused['error'], containsPair('type', 'invalid'));
    expect('${(refused['error'] as Map)['message']}', contains('USB'));
    final badType = await engine.handle('board.periph', {
      'port': '/dev/null',
      'type': 'laser',
    });
    expect(badType['error'], containsPair('type', 'invalid'));
  });

  test('arriving home by Wi-Fi or at a BLE zone runs a rule', () async {
    await ok('zone.save', {
      'zone': {
        'id': 'home',
        'name': 'Home',
        'wifi': {
          'ssids': ['HomeNet'],
        },
      },
    });
    await ok('zone.save', {
      'zone': {
        'id': 'study',
        'name': 'Study',
        'ble': {'matchName': 'OMNI_STUDY'},
      },
    });
    await ok('device.add', {'id': 'jade', 'driver': 'person'});
    await saveRule({
      'name': 'Welcome home',
      'when': ['home:entered'],
      'onlyIf': ['lamp.power!=true'],
      'then': ['lamp.power=true', 'notify:Welcome home'],
    });
    await saveRule({
      'name': 'Study',
      'when': ['study:entered'],
      'then': ['fan.power=true', 'notify:In the study'],
    });
    final rule =
        (await ok('automation.get', {'id': 'welcome_home'}))['spec'] as Map;
    expect(rule['when'], [
      {
        'on': 'jade.home',
        'change': {'to': true},
      },
    ]);

    await ok('phone.wifi', {'ssid': 'Cafe'});
    expect(announced(), isEmpty);
    await ok('phone.wifi', {'ssid': 'HomeNet', 'bssid': 'aa:bb'});
    await until(() => announced().contains('Welcome home'));
    expect((await stateOf('lamp'))['power'], isTrue);
    expect(await stateOf('jade'), {'home': true, 'place': 'home'});

    final start = DateTime.utc(2026, 11, 7, 18);
    for (var s = 0; s <= 4; s++) {
      await ok('phone.ble', {
        'name': 'OMNI_STUDY',
        'rssi': -50,
        'at': start.add(Duration(seconds: s)).toIso8601String(),
      });
    }
    await until(() => announced().contains('In the study'));
    expect((await stateOf('fan'))['power'], isTrue);
    expect((await stateOf('study'))['inside'], isTrue);
    expect(announced(), ['Welcome home', 'In the study']);
  });

  test('a sensor crossing a threshold runs a rule once per crossing', () async {
    await saveRule({
      'name': 'Too warm',
      'when': ['room.temp>28'],
      'then': ['fan.power=true', 'notify:Too warm'],
      'mode': 'queued',
    });
    await saveRule({
      'name': 'Low battery',
      'when': ['phone.battery<20'],
      'then': ['notify:Charge the phone', r'set:$Charge=true'],
      'mode': 'queued',
    });
    for (final t in [25, 27, 29, 31, 26, 30]) {
      await engine.devices.mergeState('room', {'temp': t});
    }
    await until(() => announced().where((a) => a == 'Too warm').length == 2);
    expect((await stateOf('fan'))['power'], isTrue);

    for (final level in [50, 15, 10, 30, 12]) {
      await ok('phone.battery', {'level': level});
    }
    await until(
      () => announced().where((a) => a == 'Charge the phone').length == 2,
    );
    expect(engine.flows.globals['Charge'], isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(announced().where((a) => a == 'Too warm'), hasLength(2));
  });

  test('thing.add walks pair, secret and configure to done, and the thing '
      'then works', () async {
    final bridge = await FakeHueBridge.start();
    addTearDown(bridge.close);
    await ok('driver.register', {'manifest': _bridgeLight});
    final added = await ok('thing.add', {
      'driver': 'bridge_light',
      'host': '127.0.0.1',
      'port': bridge.port,
      'name': 'Desk light',
    });
    final id = added['id'] as String;
    expect(id, 'desk_light');
    expect(
      added['next'],
      allOf(
        containsPair('step', 'pair'),
        containsPair('method', 'hue_bridge'),
        containsPair('command', 'device.pair'),
        containsPair('remaining', [
          'pair',
          'secret:sceneKey',
          'configure:lightId',
        ]),
      ),
    );

    final early = await engine.handle('device.pair', {'id': id});
    expect(early['error'], containsPair('type', 'pairing_failed'));
    expect(
      ((await ok('thing.next', {'id': id}))['next'] as Map)['step'],
      'pair',
    );
    bridge.linkButtonPressed = true;
    await ok('device.pair', {'id': id});

    final secret = (await ok('thing.next', {'id': id}))['next'] as Map;
    expect(secret['step'], 'secret');
    expect(secret['command'], 'secret.set');
    expect(secret['keys'], [
      {'step': 'secret', 'key': 'sceneKey', 'label': 'Scene key'},
    ]);
    await ok('secret.set', {
      'deviceId': id,
      'key': 'sceneKey',
      'value': 'fixture-scene-key',
    });

    final configure = (await ok('thing.next', {'id': id}))['next'] as Map;
    expect(configure['step'], 'configure');
    expect(configure['command'], 'thing.configure');
    expect(
      [for (final k in configure['keys'] as List) (k as Map)['key']],
      ['lightId'],
    );
    final done = await ok('thing.configure', {
      'id': id,
      'settings': {'lightId': '3'},
    });
    expect(done['next'], {
      'step': 'done',
      'instruction': 'Desk light is ready',
    });

    await ok('device.invoke', {
      'id': id,
      'capability': 'power',
      'params': {'value': true},
    });
    expect(bridge.lights['3']!['on'], isTrue);
    final json = '${await ok('device.get', {'id': id})}';
    expect(json, isNot(contains(bridge.issued)));
    expect(json, isNot(contains('fixture-scene-key')));
  });

  test('flows and links stored before the unification migrate and run, and '
      'reopen in the form they were written', () async {
    await ok('device.add', {'id': 'jade', 'driver': 'person'});
    await close();
    final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
    final at = DateTime.utc(2026);
    await DriftZoneStore(db).put('home', {
      'id': 'home',
      'name': 'Home',
      'wifi': {
        'ssids': ['HomeNet'],
      },
    });
    await DriftFlowStore(db).put(
      'arrive',
      {
        'schemaVersion': 1,
        'id': 'arrive',
        'name': 'Arrive',
        'nodes': [
          {
            'id': 't',
            'type': 'zone_change',
            'config': {'zoneId': 'home', 'transition': 'entered'},
          },
          {
            'id': 'c',
            'type': 'device_state_is',
            'config': {'deviceId': 'lamp', 'key': 'power', 'value': false},
          },
          {
            'id': 'on',
            'type': 'device_capability',
            'config': {
              'deviceId': 'lamp',
              'capabilityId': 'power',
              'params': {'value': true},
            },
          },
        ],
        'edges': [edge('t', 'out', 'c'), edge('c', 'true', 'on')],
      },
      enabled: true,
      approved: true,
      trusted: true,
      at: at,
    );
    await DriftFlowStore(db).put(
      'link_lamp_power_fan_power',
      {
        'schemaVersion': 1,
        'id': 'link_lamp_power_fan_power',
        'name': 'lamp.power -> fan.power',
        'enabled': true,
        'mode': 'queued',
        'cooldownSeconds': 0,
        'nodes': [
          {
            'id': 'source',
            'type': 'device_state',
            'config': {'deviceId': 'lamp', 'key': 'power'},
          },
          {
            'id': 'pressed',
            'type': 'var_equals',
            'config': {'name': 'msg.value', 'value': true},
          },
          {
            'id': 'flip',
            'type': 'device_toggle',
            'config': {'deviceId': 'fan', 'capabilityId': 'power'},
          },
        ],
        'edges': [
          edge('source', 'out', 'pressed'),
          edge('pressed', 'true', 'flip'),
        ],
      },
      enabled: true,
      approved: true,
      trusted: true,
      at: at,
      source: FlowRecord.link,
    );
    await db.close();

    await open();
    final list = {
      for (final a
          in ((await ok('automation.list', {}))['automations'] as List)
              .cast<Map>())
        a['id']: a,
    };
    expect(list['arrive'], containsPair('source', 'graph'));
    expect(list['link_lamp_power_fan_power'], containsPair('source', 'link'));
    expect(
      engine.flows.loadedFlows,
      containsAll(['arrive', 'link_lamp_power_fan_power']),
    );
    final link = await ok('automation.get', {
      'id': 'link_lamp_power_fan_power',
    });
    expect(
      link['spec'],
      allOf(
        containsPair('from', 'lamp.power'),
        containsPair('to', 'fan.power'),
        containsPair('mode', 'toggle'),
      ),
    );
    final arrive =
        (await ok('automation.get', {'id': 'arrive'}))['flow'] as Map;
    final types = [for (final n in arrive['nodes'] as List) (n as Map)['type']];
    expect(types, ['on', 'compare', 'device_capability']);

    await engine.devices.mergeState('lamp', {'power': false});
    await engine.devices.mergeState('fan', {'power': false});
    await ok('phone.wifi', {'ssid': 'HomeNet'});
    await until(() async => (await stateOf('lamp'))['power'] == true);
    await until(() async => (await stateOf('fan'))['power'] == true);
  });

  test(
    'a migrated zone flow whose notify read msg.zone names the place',
    () async {
      await close();
      final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
      await DriftZoneStore(db).put('home', {
        'id': 'home',
        'name': 'Home',
        'wifi': {
          'ssids': ['HomeNet'],
        },
      });
      await DriftFlowStore(db).put(
        'arrive_note',
        {
          'schemaVersion': 1,
          'id': 'arrive_note',
          'name': 'Arrive note',
          'nodes': [
            {
              'id': 't',
              'type': 'zone_change',
              'config': {'zoneId': 'home', 'transition': 'entered'},
            },
            {
              'id': 'at_home',
              'type': 'var_equals',
              'config': {'name': 'msg.zone', 'value': 'home'},
            },
            {
              'id': 'note',
              'type': 'notify',
              'config': {'title': 'Arrived at {{msg.zone}}'},
            },
          ],
          'edges': [
            edge('t', 'out', 'at_home'),
            edge('at_home', 'true', 'note'),
          ],
        },
        enabled: true,
        approved: true,
        trusted: true,
        at: DateTime.utc(2026),
      );
      await db.close();

      await open();
      final flow =
          (await ok('automation.get', {'id': 'arrive_note'}))['flow'] as Map;
      final place =
          ((flow['nodes'] as List).first as Map)['config']['thing'] as String;
      expect(
        ((await ok('device.get', {'id': place}))['device'] as Map)['driver'],
        'place',
      );
      await ok('phone.wifi', {'ssid': 'HomeNet'});
      await until(() async => announced().isNotEmpty);
      expect(announced(), ['Arrived at $place']);
    },
  );
}
