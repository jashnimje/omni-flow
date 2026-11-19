@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/alerts.dart';
import 'package:omniflow_engine/src/api/room_control.dart';
import 'package:omniflow_engine/src/api/scene_capture.dart';
import 'package:omniflow_engine/src/api/mode_commands.dart' show HomeFile;
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';
import 'automation_harness.dart';
import 'things_test.dart' show until;

/// A light with no wire under it, so a command's optimistic state is its
/// state.
const _light = {
  'schemaVersion': 1,
  'id': 'test_bulb',
  'name': 'Test bulb',
  'category': 'lighting',
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
      'id': 'brightness',
      'type': 'level',
      'label': 'Brightness',
      'params': {
        'value': {
          'type': 'number',
          'integer': true,
          'min': 1,
          'max': 100,
          'unit': '%',
        },
      },
      'command': {'set': 'brightness', 'value': '{{value}}'},
      'stateJsonPath': r'$.brightness',
    },
    {
      'id': 'color_temp',
      'type': 'color_temp',
      'label': 'White',
      'params': {
        'value': {'type': 'number', 'integer': true, 'min': 2200, 'max': 6500},
      },
      'command': {'set': 'temp', 'value': '{{value}}'},
      'stateJsonPath': r'$.temp',
    },
  ],
};

/// A plug: it has power but is not a light.
const _plug = {
  'schemaVersion': 1,
  'id': 'test_plug',
  'name': 'Test plug',
  'category': 'power',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'set': 'power', 'value': '{{value}}'},
      'stateJsonPath': r'$.power',
    },
  ],
};

/// A light on its own scales, like Hue (1 to 254, white in mireds) or
/// Tuya (10 to 1000, white 0 to 1000), and with on and off words when
/// [words] is given.
Map<String, Object?> _scaledLight(
  String id,
  num min,
  num max, {
  Map<String, Object?>? white,
  List<String>? words,
}) => {
  'schemaVersion': 1,
  'id': id,
  'name': id,
  'category': 'lighting',
  'transport': {'type': 'virtual'},
  'capabilities': [
    {
      'id': 'power',
      'type': 'toggle',
      'label': 'Power',
      'command': {'set': 'power', 'value': '{{value}}'},
      'stateJsonPath': r'$.power',
      'onOff': ?words,
    },
    {
      'id': 'brightness',
      'type': 'level',
      'label': 'Brightness',
      'params': {
        'value': {'type': 'number', 'integer': true, 'min': min, 'max': max},
      },
      'command': {'set': 'brightness', 'value': '{{value}}'},
      'stateJsonPath': r'$.brightness',
    },
    if (white != null)
      {
        'id': 'color_temp',
        'type': 'level',
        'label': 'White',
        'params': {'value': white},
        'command': {'set': 'temp', 'value': '{{value}}'},
        'stateJsonPath': r'$.temp',
      },
  ],
};

void main() {
  late Directory home;
  late OmniEngine engine;
  late List<Map<String, Object?>> events;
  late StreamSubscription<Map<String, Object?>> sub;

  Future<OmniEngine> open() => OmniEngine.open(
    home: home,
    secrets: InMemorySecretStore(),
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  Future<Map<String, Object?>> ok(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command -> $result');
    return result;
  }

  Future<Map<String, Object?>> fails(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isFalse, reason: '$command -> $result');
    return Map<String, Object?>.from(result['error'] as Map);
  }

  Future<void> reopen() async {
    await sub.cancel();
    await engine.close();
    engine = await open();
    sub = engine.events.listen(events.add);
  }

  Future<Map<String, Object?>> saveRule(Map<String, Object?> rule) =>
      ok('automation.save', {'form': 'rule', 'spec': rule, 'trusted': true});

  List<String> announced() => [
    for (final e in events)
      if (e['event'] == 'flow.announce') '${e['title']}',
  ];

  Future<Map<String, Object?>> stateOf(String id) async =>
      Map<String, Object?>.from(
        ((await ok('device.get', {'id': id}))['device'] as Map)['state'] as Map,
      );

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_house');
    engine = await open();
    events = [];
    sub = engine.events.listen(events.add);
    await ok('driver.register', {'manifest': _light});
    await ok('driver.register', {'manifest': _plug});
    for (final (id, name, driver) in [
      ('lamp', 'Lamp', 'test_bulb'),
      ('ceiling', 'Ceiling', 'test_bulb'),
      ('heater', 'Heater', 'test_plug'),
    ]) {
      await ok('device.add', {
        'id': id,
        'name': name,
        'driver': driver,
        'room': 'Living room',
      });
    }
  });

  tearDown(() async {
    await sub.cancel();
    await engine.close();
    await home.delete(recursive: true);
  });

  group('house modes', () {
    test('Home to start with, the four built in plus your own, and a change '
        'is an event and lasts across a restart', () async {
      final start = await ok('home.mode');
      expect(start['mode'], 'home');
      expect(
        [for (final m in start['modes'] as List) (m as Map)['name']],
        ['Home', 'Away', 'Night', 'Vacation'],
      );
      final set = await ok('home.mode.set', {
        'modes': ['Movie night'],
        'mode': 'Movie night',
      });
      expect((set['mode'], set['name']), ('movie_night', 'Movie night'));
      await Future<void>.delayed(Duration.zero);
      final changed = events.lastWhere((e) => e['event'] == 'home.modeChanged');
      expect(changed, containsPair('previous', 'home'));
      expect(changed, containsPair('by', 'user'));
      expect(
        (await fails('home.mode.set', {'mode': 'Party'}))['type'],
        'not_found',
      );
      expect(
        (await fails('home.mode.set', {
          'modes': ['Night'],
        }))['type'],
        'exists',
      );
      await ok('home.location.set', {'latitude': 51.5, 'longitude': -0.1});
      await reopen();
      final again = await ok('home.mode');
      expect(again['mode'], 'movie_night');
      expect((await ok('home.location'))['location'], isNotNull);
      final file = jsonDecode(
        await File('${home.path}/home.json').readAsString(),
      );
      expect(file, containsPair('mode', 'movie_night'));
      expect(file, contains('location'));
    });

    test('a rule starts when the mode changes to Night, checks the mode is '
        'Away, and reads in plain words', () async {
      await saveRule({
        'name': 'Night lights',
        'when': [
          {
            'on': 'house_mode.changed',
            'event': true,
            'match': {'mode': 'night'},
          },
        ],
        'then': [
          {
            'notify': {'title': 'good night'},
          },
        ],
      });
      await saveRule({
        'name': 'Away check',
        'when': [
          {'manual': true},
        ],
        'onlyIf': [
          {'state': 'house_mode.mode', 'op': '==', 'value': 'away'},
        ],
        'then': [
          {
            'do': 'house_mode.set',
            'params': {'mode': 'vacation'},
          },
        ],
      });
      final list = (await ok('automation.list'))['automations'] as List;
      final sentences = {
        for (final a in list.cast<Map>()) a['id']: '${a['sentence']}',
      };
      expect(sentences['night_lights'], contains('the mode changes to Night'));
      expect(sentences['away_check'], contains('the mode is Away'));
      expect(sentences['away_check'], contains('set the mode to Vacation'));

      await ok('home.mode.set', {'mode': 'away'});
      await engine.flows.settle();
      expect(announced(), isNot(contains('good night')));
      await ok('automation.run', {'id': 'away_check'});
      await engine.flows.settle();
      expect((await ok('home.mode'))['mode'], 'vacation');

      await ok('home.mode.set', {'mode': 'night'});
      await until(() => announced().contains('good night'));
      await ok('automation.run', {'id': 'away_check'});
      await engine.flows.settle();
      expect((await ok('home.mode'))['mode'], 'night');
    });

    test('an event the mode thing does not raise is a save error', () async {
      final saved = await engine.handle('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Bad mode',
          'when': [
            {'on': 'house_mode.nothing', 'event': true},
          ],
          'then': [
            {'wait': 1},
          ],
        },
      });
      expect(saved['ok'], isFalse);
      expect('${saved['error']}', contains('house_mode has no event nothing'));
    });

    test('following presence: Away when the last person leaves, Home when '
        'someone is back', () async {
      await ok('device.add', {
        'id': 'jade',
        'name': 'Jade',
        'driver': 'person',
      });
      await ok('presence.set', {'home': true, 'person': 'jade'});
      await ok('home.mode.set', {'followPresence': true});
      await ok('home.mode.set', {'mode': 'night'});
      await ok('presence.set', {'home': false, 'person': 'jade'});
      await until(() async => (await ok('home.mode'))['mode'] == 'away');
      await ok('presence.set', {'home': true, 'person': 'jade'});
      await until(() async => (await ok('home.mode'))['mode'] == 'home');
      expect(
        events.lastWhere((e) => e['event'] == 'home.modeChanged')['by'],
        'presence',
      );
    });

    test('a backup keeps the mode and alerts, and an import brings them '
        'back', () async {
      await ok('home.mode.set', {
        'modes': ['Guests'],
        'mode': 'guests',
      });
      await ok('alerts.set', {'battery': false});
      final backup =
          (await ok('config.export'))['backup'] as Map<String, Object?>;
      expect(backup['home'], containsPair('mode', 'guests'));
      await ok('home.mode.set', {'mode': 'home', 'modes': <String>[]});
      await ok('alerts.set', {'battery': true});
      await ok('config.import', {'backup': backup});
      expect((await ok('home.mode'))['mode'], 'guests');
      expect((await ok('alerts.get'))['battery'], isFalse);
    });
  });

  group('timers', () {
    test('start, pause, resume and cancel, kept with their end time', () async {
      final started = await ok('timer.start', {'name': 'Pasta', 'ms': 1200000});
      final timer = started['timer'] as Map;
      expect((timer['id'], timer['state']), ('pasta', 'running'));
      expect(DateTime.parse('${timer['endsAt']}'), isA<DateTime>());
      await Future<void>.delayed(Duration.zero);
      expect(events.any((e) => e['event'] == 'timer.changed'), isTrue);
      final paused = (await ok('timer.pause', {'name': 'pasta'}))['timer'];
      expect((paused as Map)['state'], 'paused');
      expect(paused['endsAt'], isNull);
      await reopen();
      final listed = (await ok('timer.list'))['timers'] as List;
      expect((listed.single as Map)['state'], 'paused');
      final resumed = (await ok('timer.resume', {'name': 'Pasta'}))['timer'];
      expect((resumed as Map)['state'], 'running');
      await ok('timer.cancel', {'name': 'PASTA'});
      expect((await ok('timer.list'))['timers'], isEmpty);
      expect(
        (await fails('timer.cancel', {'name': 'Pasta'}))['type'],
        'not_found',
      );
      expect(
        (await fails('timer.start', {'name': 'x', 'ms': 10}))['type'],
        'invalid',
      );
    });

    test(
      'a step starts it and "when timer Pasta ends" runs when it does',
      () async {
        await saveRule({
          'name': 'Cook',
          'when': [
            {'manual': true},
          ],
          'then': [
            {
              'do': 'timers.start',
              'params': {'name': 'Pasta', 'ms': 1000},
            },
          ],
        });
        await saveRule({
          'name': 'Drain',
          'when': [
            {
              'on': 'timers.ended',
              'event': true,
              'match': {'timer': 'pasta'},
            },
          ],
          'then': [
            {
              'notify': {'title': 'drain the pasta'},
            },
          ],
        });
        final list = (await ok('automation.list'))['automations'] as List;
        final sentences = {
          for (final a in list.cast<Map>()) a['id']: '${a['sentence']}',
        };
        expect(sentences['cook'], contains('start a 1 s timer called Pasta'));
        expect(sentences['drain'], contains('timer Pasta ends'));
        await ok('automation.run', {'id': 'cook'});
        await engine.flows.settle();
        expect((await ok('timer.list'))['timers'], hasLength(1));
        await until(() => announced().contains('drain the pasta'));
        expect(announced(), contains('Pasta timer is done'));
        expect((await ok('timer.list'))['timers'], isEmpty);
      },
    );

    test('a timer that ended while the engine was closed ends when it '
        'opens', () async {
      await ok('timer.start', {'name': 'Tea', 'ms': 60000});
      await sub.cancel();
      await engine.close();
      final file = File('${home.path}/timers.json');
      final json = jsonDecode(await file.readAsString()) as Map;
      final t = Map<String, Object?>.from((json['timers'] as List).single);
      t['endsAt'] = DateTime.now()
          .subtract(const Duration(minutes: 1))
          .toUtc()
          .toIso8601String();
      await file.writeAsString(
        jsonEncode({
          'timers': [t],
        }),
      );
      engine = await open();
      sub = engine.events.listen(events.add);
      await until(
        () async => ((await ok('timer.list'))['timers'] as List).isEmpty,
      );
    });
  });

  group('a room as one light', () {
    test('room.invoke sends to every device with the capability, or only '
        'the lights', () async {
      final all = await ok('room.invoke', {
        'room': 'living room',
        'capability': 'power',
        'params': {'value': true},
      });
      expect(all['sent'], 3);
      expect((await stateOf('heater'))['power'], isTrue);
      final lights = await ok('room.invoke', {
        'room': 'living_room',
        'capability': 'power',
        'params': {'value': false},
        'only': 'lights',
      });
      expect([
        for (final r in lights['results'] as List) (r as Map)['id'],
      ], ['ceiling', 'lamp']..sort());
      expect((await stateOf('heater'))['power'], isTrue);
      expect((await stateOf('lamp'))['power'], isFalse);
      expect(
        (await fails('room.invoke', {
          'room': 'Living room',
          'capability': 'brightness',
          'params': {'value': 500},
        }))['type'],
        'invalid',
      );
      expect(
        (await fails('room.invoke', {
          'room': 'Kitchen',
          'capability': 'power',
        }))['type'],
        'not_found',
      );
      expect(
        (await fails('room.invoke', {
          'room': 'Living room',
          'capability': 'volume',
        }))['type'],
        'not_found',
      );
    });

    test('room.state: lights on and their average brightness', () async {
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'brightness',
        'params': {'value': 40},
      });
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'power',
        'params': {'value': true},
      });
      await ok('device.invoke', {
        'id': 'ceiling',
        'capability': 'brightness',
        'params': {'value': 80},
      });
      await ok('device.invoke', {
        'id': 'ceiling',
        'capability': 'power',
        'params': {'value': true},
      });
      final state = await ok('room.state', {'room': 'Living room'});
      expect(
        (state['lights'], state['lightsOn'], state['anyOn']),
        (2, 2, true),
      );
      expect(state['brightness'], 60);
      expect(state['devices'], 3);
    });
  });

  test('room.state leaves an offline light out of the lights on', () async {
    final dir = await Directory.systemTemp.createTemp('omni_room_offline');
    final harness = await AutomationHarness.open(dir, addThings: false);
    try {
      final now = DateTime.now();
      await DriftRoomStore(harness.db)
          .put(const Room(id: 'hall', name: 'Hall'));
      for (final (id, seen) in [
        ('near', now),
        ('gone', now.subtract(const Duration(hours: 2))),
      ]) {
        await DriftDeviceStore(harness.db).put(
          Device(
            id: id,
            name: id,
            driverId: 'philips_wiz_udp',
            host: '127.0.0.1',
            room: 'hall',
            lastSeen: seen,
            state: const {'state': true, 'dimming': 80},
          ),
        );
      }
      final state = await RoomControl(
        harness.core,
        harness.stored,
      ).state({'room': 'hall'});
      expect((state['lights'], state['lightsOn'], state['offline']), (2, 1, 1));
    } finally {
      await harness.close();
      await dir.delete(recursive: true);
    }
  });

  test('a room sends brightness and white in percent and kelvin through '
      'each light\'s own scale, and averages in percent', () async {
    await ok('driver.register', {
      'manifest': _scaledLight(
        'hue_like',
        1,
        254,
        white: {
          'type': 'number',
          'integer': true,
          'min': 153,
          'max': 500,
          'unit': 'mired',
        },
      ),
    });
    await ok('driver.register', {
      'manifest': _scaledLight(
        'tuya_like',
        10,
        1000,
        white: {'type': 'number', 'integer': true, 'min': 0, 'max': 1000},
      ),
    });
    for (final (id, driver) in [
      ('hue', 'hue_like'),
      ('tuya', 'tuya_like'),
      ('wiz', 'test_bulb'),
    ]) {
      await ok('device.add', {
        'id': id,
        'name': id,
        'driver': driver,
        'room': 'Bedroom',
      });
    }
    await ok('room.invoke', {
      'room': 'Bedroom',
      'capability': 'power',
      'params': {'value': true},
    });
    await ok('room.invoke', {
      'room': 'Bedroom',
      'capability': 'brightness',
      'params': {'value': 50},
    });
    expect(
      [
        for (final id in ['hue', 'tuya', 'wiz'])
          (await stateOf(id))['brightness'],
      ],
      [127, 500, 50],
    );
    await ok('room.invoke', {
      'room': 'Bedroom',
      'capability': 'color_temp',
      'params': {'value': 4000},
    });
    expect(
      [
        for (final id in ['hue', 'tuya', 'wiz']) (await stateOf(id))['temp'],
      ],
      [250, 342, 4000],
    );
    final state = await ok('room.state', {'room': 'Bedroom'});
    expect(state['brightness'], 50);
    expect([
      for (final t in (state['things'] as List).cast<Map>()) t['brightness'],
    ], everyElement(50));
  });

  test('a light with on and off words: room.state counts it, and a capture '
      'of it off keeps power only', () async {
    await ok('driver.register', {
      'manifest': _scaledLight('worded', 0, 100, words: ['ON', 'OFF']),
    });
    await ok('device.add', {
      'id': 'strip',
      'name': 'Strip',
      'driver': 'worded',
      'room': 'Study',
    });
    await ok('device.invoke', {
      'id': 'strip',
      'capability': 'brightness',
      'params': {'value': 40},
    });
    await ok('device.invoke', {
      'id': 'strip',
      'capability': 'power',
      'params': {'value': true},
    });
    expect((await ok('room.state', {'room': 'Study'}))['lightsOn'], 1);
    await ok('device.invoke', {
      'id': 'strip',
      'capability': 'power',
      'params': {'value': false},
    });
    final saved = await ok('scene.capture', {
      'name': 'Study off',
      'devices': ['strip'],
    });
    expect(saved['actions'], [
      {
        'do': 'strip.power',
        'params': {'value': false},
      },
    ]);
  });

  group('save how things are now', () {
    test('scene.capture keeps power, brightness and white, and only power '
        'for one that is off', () async {
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'brightness',
        'params': {'value': 30},
      });
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'color_temp',
        'params': {'value': 2700},
      });
      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'power',
        'params': {'value': true},
      });
      await ok('device.invoke', {
        'id': 'ceiling',
        'capability': 'power',
        'params': {'value': false},
      });
      final saved = await ok('scene.capture', {
        'name': 'Evening',
        'devices': ['lamp', 'ceiling'],
      });
      expect(saved['actions'], [
        {
          'do': 'lamp.power',
          'params': {'value': true},
        },
        {
          'do': 'lamp.brightness',
          'params': {'value': 30},
        },
        {
          'do': 'lamp.color_temp',
          'params': {'value': 2700},
        },
        {
          'do': 'ceiling.power',
          'params': {'value': false},
        },
      ]);
      final scenes = (await ok('scene.list'))['scenes'] as List;
      expect([for (final s in scenes.cast<Map>()) s['name']], ['Evening']);

      await ok('device.invoke', {
        'id': 'lamp',
        'capability': 'power',
        'params': {'value': false},
      });
      await ok('scene.run', {'id': 'evening'});
      await engine.flows.settle();
      expect((await stateOf('lamp'))['power'], isTrue);

      final room = await ok('scene.capture', {
        'name': 'Living',
        'room': 'Living room',
      });
      expect(room['skipped'], ['heater']);
      expect(
        (await fails('scene.capture', {
          'name': 'X',
          'devices': ['nope'],
        }))['type'],
        'not_found',
      );
      expect((await fails('scene.capture', {'name': 'X'}))['type'], 'invalid');
    });

    test('scene.capture names each device whose state is older than its '
        'poll window', () async {
      final dir = await Directory.systemTemp.createTemp('omni_capture_stale');
      final harness = await AutomationHarness.open(dir, addThings: false);
      try {
        final now = DateTime.now();
        final old = now.subtract(const Duration(days: 5));
        for (final (id, name, seen) in [
          ('near', 'Desk', now),
          ('gone', 'Hall light', old),
        ]) {
          await DriftDeviceStore(harness.db).put(
            Device(
              id: id,
              name: name,
              driverId: 'philips_wiz_udp',
              host: '127.0.0.1',
              lastSeen: seen,
              state: const {'state': true, 'dimming': 80},
            ),
          );
        }
        final saved =
            await SceneCapture(
              harness.core,
              harness.stored,
              harness.automations,
            ).capture({
              'name': 'Stale',
              'devices': ['near', 'gone'],
              'trusted': true,
            });
        final stale = (saved['stale'] as List).cast<Map>();
        expect(
          [for (final s in stale) (s['id'], s['name'])],
          [('gone', 'Hall light')],
        );
        expect(
          DateTime.parse('${stale.single['lastSeen']}')
              .difference(old)
              .inSeconds,
          0,
        );
      } finally {
        await harness.close();
        await dir.delete(recursive: true);
      }
    });
  });

  group('alerts', () {
    test('not answering off and battery on to start with, a switch lasts, '
        'and a low phone battery notifies once', () async {
      final start = await ok('alerts.get');
      expect((start['offline'], start['battery']), (false, true));
      await ok('phone.battery', {'level': 50});
      await ok('phone.battery', {'level': 12});
      await until(() => announced().any((t) => t.contains('battery is low')));
      await ok('phone.battery', {'level': 11});
      await engine.flows.settle();
      expect(
        announced().where((t) => t.contains('battery is low')),
        hasLength(1),
      );
      await ok('alerts.set', {'offline': true});
      await reopen();
      expect((await ok('alerts.get'))['offline'], isTrue);
      expect(
        (await fails('alerts.set', {'battery': 'yes'}))['type'],
        'invalid',
      );
    });

    test('a device offline for 10 minutes alerts once, and again when it is '
        'back', () async {
      final dir = await Directory.systemTemp.createTemp('omni_alerts');
      final harness = await AutomationHarness.open(dir, addThings: false);
      final seen = <Map<String, Object?>>[];
      final s = harness.core.events.listen(seen.add);
      try {
        final now = DateTime.now();
        await DriftDeviceStore(harness.db).put(
          Device(
            id: 'bulb',
            name: 'Hall bulb',
            driverId: 'philips_wiz_udp',
            host: '127.0.0.1',
            lastSeen: now.subtract(const Duration(minutes: 5)),
          ),
        );
        final alerts = HouseAlerts(harness.core, HomeFile(dir));
        await alerts.set({'offline': true});
        await alerts.check(at: now.subtract(const Duration(minutes: 5)));
        await alerts.check(at: now.add(const Duration(minutes: 9)));
        await alerts.check(at: now.add(const Duration(minutes: 10)));
        await Future<void>.delayed(Duration.zero);
        final titles = [
          for (final e in seen)
            if (e['event'] == 'flow.announce') e['title'],
        ];
        expect(titles, ['Hall bulb is not answering']);
        await DriftDeviceStore(harness.db).put(
          Device(
            id: 'bulb',
            name: 'Hall bulb',
            driverId: 'philips_wiz_udp',
            host: '127.0.0.1',
            lastSeen: now.add(const Duration(minutes: 11)),
          ),
        );
        await alerts.check(at: now.add(const Duration(minutes: 11)));
        await Future<void>.delayed(Duration.zero);
        expect(seen.last['title'], 'Hall bulb is answering again');
      } finally {
        await s.cancel();
        await harness.shutdown();
        await dir.delete(recursive: true);
      }
    });
  });

  test('alerts wait for the hub to poll, count from when it started, say '
      'how long, and are not told again after a restart', () async {
    final dir = await Directory.systemTemp.createTemp('omni_alerts_hub');
    final harness = await AutomationHarness.open(dir, addThings: false);
    final seen = <Map<String, Object?>>[];
    final s = harness.core.events.listen(seen.add);
    try {
      final now = DateTime.now();
      await DriftDeviceStore(harness.db).put(
        Device(
          id: 'bulb',
          name: 'Hall bulb',
          driverId: 'philips_wiz_udp',
          host: '127.0.0.1',
          lastSeen: now.subtract(const Duration(days: 3)),
        ),
      );
      var running = false;
      final alerts = HouseAlerts(
        harness.core,
        HomeFile(dir),
        hubRunning: () => running,
      );
      await alerts.open();
      await alerts.set({'offline': true});
      await alerts.check(at: now);
      running = true;
      await alerts.check(at: now.add(const Duration(minutes: 1)));
      await alerts.check(at: now.add(const Duration(minutes: 10)));
      await Future<void>.delayed(Duration.zero);
      expect(
        seen.where((e) => e['event'] == 'flow.announce'),
        isEmpty,
        reason: 'not offline until polled for its window and 10 minutes',
      );
      await alerts.check(at: now.add(const Duration(minutes: 16)));
      await Future<void>.delayed(Duration.zero);
      final told = [
        for (final e in seen)
          if (e['event'] == 'flow.announce') e['body'],
      ];
      expect(told, ['Not heard from for 3 days']);
      await alerts.close();

      final again = HouseAlerts(
        harness.core,
        HomeFile(dir),
        hubRunning: () => true,
      );
      await again.open();
      await again.check(at: now.add(const Duration(hours: 1)));
      await again.check(at: now.add(const Duration(hours: 2)));
      await Future<void>.delayed(Duration.zero);
      expect(
        seen.where((e) => e['event'] == 'flow.announce'),
        hasLength(1),
        reason: 'what was told is remembered',
      );
      await again.close();
      expect(durationWords(const Duration(minutes: 1)), '1 minute');
      expect(durationWords(const Duration(minutes: 90)), '90 minutes');
      expect(durationWords(const Duration(hours: 5)), '5 hours');
    } finally {
      await s.cancel();
      await harness.shutdown();
      await dir.delete(recursive: true);
    }
  });

  test('agents: room.state is a read, the rest need setup', () async {
    final refused = await engine.handle('agent.call', {
      'command': 'home.mode.set',
      'args': {'mode': 'night'},
    });
    expect((refused['error'] as Map)['type'], 'needs_user');
    final read = await engine.handle('agent.call', {
      'command': 'room.state',
      'args': {'room': 'Living room'},
    });
    expect(read['ok'], isTrue, reason: '$read');
  });
}
