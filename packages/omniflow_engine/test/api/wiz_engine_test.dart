import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/wiz_pilot.dart';
import 'package:omniflow_engine/src/devices/wiz_scenes.dart';
import 'package:test/test.dart';

import '../support/fake_wiz_bulb.dart';

const _key = '00112233445566778899aabbccddeeff';

void main() {
  late Directory home;
  late InMemorySecretStore secrets;
  late OmniEngine engine;
  final bulbs = <FakeWizBulb>[];

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_wiz');
    secrets = InMemorySecretStore();
    engine = await OmniEngine.open(home: home, secrets: secrets);
  });
  tearDown(() async {
    await engine.close();
    for (final b in bulbs) {
      b.close();
    }
    bulbs.clear();
    await home.delete(recursive: true);
  });

  Future<FakeWizBulb> add(
    String id, {
    String module = 'ESP25_SHRGB_01',
    List<int>? range = const [2200, 6500],
    String? key,
    String room = 'Lounge',
  }) async {
    final b = await FakeWizBulb.start(module: module, range: range, key: key);
    bulbs.add(b);
    final added = await engine.handle('device.add', {
      'id': id,
      'name': id[0].toUpperCase() + id.substring(1),
      'driver': 'philips_wiz_udp',
      'host': b.host,
      'port': b.port,
      'room': room,
    });
    expect(added['ok'], isTrue, reason: '$added');
    return b;
  }

  Future<Map<String, Object?>> device(String id) async =>
      (await engine.handle('device.get', {'id': id}))['device']
          as Map<String, Object?>;

  test('a refused unsigned write asks for the key, and the setup step for it '
      'becomes required with the other bulb offered', () async {
    await add('kitchen', key: _key);
    await add('lamp', key: _key);
    await engine.handle('secret.set', {
      'deviceId': 'kitchen',
      'key': 'signingKey',
      'value': ' $_key ',
    });
    final refused = await engine.handle('device.invoke', {
      'id': 'lamp',
      'capability': 'power',
      'params': {'value': true},
    });
    expect((refused['error'] as Map)['type'], 'needs_user');
    expect(
      ((await device('lamp'))['problem'] as Map)['message'],
      'Lamp does not take commands until you add its WiZ home key',
    );
    final next = await engine.handle('thing.next', {'id': 'lamp'});
    final step = next['next'] as Map;
    expect(step['step'], 'secret');
    expect(((step['keys'] as List).single as Map)['sameAs'], [
      {'id': 'kitchen', 'name': 'Kitchen'},
    ]);
    final copied = await engine.handle('secret.set', {
      'deviceId': 'lamp',
      'key': 'signingKey',
      'from': 'kitchen',
    });
    expect(copied['ok'], isTrue, reason: '$copied');
    expect((await device('lamp')).containsKey('problem'), isFalse);
    final on = await engine.handle('device.invoke', {
      'id': 'lamp',
      'capability': 'power',
      'params': {'value': true},
    });
    expect(on['ok'], isTrue, reason: '$on');
    expect(bulbs[1].pilot['state'], true);
  });

  test('a home key that is not 32 hex characters is refused', () async {
    await add('lamp');
    final bad = await engine.handle('secret.set', {
      'deviceId': 'lamp',
      'key': 'signingKey',
      'value': 'not-a-key',
    });
    expect((bad['error'] as Map)['type'], 'invalid');
    expect(
      (bad['error'] as Map)['message'],
      'WiZ home key must be 32 characters, the digits 0 to 9 and the letters '
      'a to f',
    );
  });

  test('a room at 0 % turns its WiZ lights off, and 5 % is the lowest they '
      'take', () async {
    final a = await add('lamp');
    final b = await add(
      'kitchen',
      module: 'ESP56_SHTW3_01',
      range: [2700, 6500],
    );
    final off = await engine.handle('room.invoke', {
      'room': 'Lounge',
      'capability': 'brightness',
      'params': {'value': 0},
    });
    expect(off['sent'], 2, reason: '$off');
    expect([a.pilot['state'], b.pilot['state']], [false, false]);
    await engine.handle('room.invoke', {
      'room': 'Lounge',
      'capability': 'brightness',
      'params': {'value': 5},
    });
    expect([a.pilot['dimming'], b.pilot['dimming']], [10, 10]);
    Future<Map<String, Object?>> warm() => engine.handle('room.invoke', {
      'room': 'Lounge',
      'capability': 'color_temp',
      'params': {'value': 2000},
    });
    // Before the 2700 K bulb has said its range, it refuses 2200 K, in
    // plain words and without a retry.
    final before = await warm();
    expect(before['sent'], 1);
    expect(
      ((before['results'] as List).cast<Map>().firstWhere(
            (r) => r['id'] == 'kitchen',
          )['error']
          as Map)['message'],
      startsWith('Kitchen did not take brightness 10 %, white 2200 K'),
    );
    // Once each bulb has reported its state, it is asked what it is, and
    // white is sent inside its own range.
    await engine.devices.refreshState('kitchen');
    await engine.devices.refreshState('lamp');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final after = await warm();
    expect(after['sent'], 2, reason: '$after');
    expect([a.pilot['temp'], b.pilot['temp']], [2200, 2700]);
  });

  test(
    'a heartbeat push changes state but only light keys reach history',
    () async {
      await add('lamp');
      final devices = engine.devices;
      for (var i = 0; i < 3; i++) {
        await devices.applyPush('lamp', {
          'method': 'syncPilot',
          'params': {
            'mac': 'a8bb50aabbcc',
            'rssi': -60 - i,
            'sigTs': 1763380000 + i,
            'ts': 1763380000 + i,
            'state': true,
            'dimming': 50,
            'temp': 2700,
          },
        });
      }
      await devices.applyPush('lamp', {
        'method': 'syncPilot',
        'params': {'state': true, 'dimming': 50, 'r': 255, 'g': 0, 'b': 0},
      });
      final state = (await device('lamp'))['state'] as Map;
      expect(state['rssi'], -62);
      expect(state.containsKey('temp'), isFalse);
      final history = await engine.handle('device.history', {'id': 'lamp'});
      final keys = {
        for (final e in history['entries'] as List) (e as Map)['key'],
      };
      expect(keys, isNot(contains('rssi')));
      expect(keys, isNot(contains('sigTs')));
      expect(keys, containsAll(['dimming', 'temp', 'r']));
    },
  );

  test('a captured scene keeps a light on its white channels alone', () async {
    await add('lamp');
    await engine.devices.applyPush('lamp', {
      'method': 'syncPilot',
      'params': {
        'state': true,
        'dimming': 70,
        'r': 0,
        'g': 0,
        'b': 0,
        'c': 0,
        'w': 255,
      },
    });
    final scene = await engine.handle('scene.capture', {
      'name': 'Evening',
      'devices': ['lamp'],
    });
    expect(scene['ok'], isTrue, reason: '$scene');
    expect(
      [for (final a in scene['actions'] as List) (a as Map)['do']],
      ['lamp.power', 'lamp.brightness', 'lamp.rgb'],
    );
    expect((scene['actions'] as List).last, {
      'do': 'lamp.rgb',
      'params': {'r': 0, 'g': 0, 'b': 0, 'c': 0, 'w': 255},
    });
  });

  test('a bulb that reports its state is asked once what it is', () async {
    await add('lamp', module: 'ESP06_SHDW9_01', range: [2700, 2700]);
    await engine.devices.refreshState('lamp');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final d = await device('lamp');
    expect((d['settings'] as Map)[wizBulbSetting], {
      'module': 'ESP06_SHDW9_01',
      'kind': 'dimmable',
      'minDim': 10,
    });
    final listed = await engine.handle('device.list', {
      'withCapabilities': true,
    });
    final caps = (listed['devices'] as List).cast<Map>().single;
    expect(
      [for (final c in caps['capabilities'] as List) (c as Map)['id']],
      ['power', 'brightness', 'scene'],
    );
  });

  group('scenes, colours and whites', () {
    Future<Map<String, Object?>> invoke(
      String id,
      String capability,
      Map<String, Object?> params,
    ) => engine.handle('device.invoke', {
      'id': id,
      'capability': capability,
      'params': params,
    });

    Future<void> learned(String id) async {
      await engine.devices.refreshState(id);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    test('a scene goes by its id at its speed, and the device says which '
        'scene it is in', () async {
      final b = await add('lamp');
      await learned('lamp');
      final r = await invoke('lamp', 'scene', {'scene': 'ocean', 'speed': 150});
      expect(r['ok'], isTrue, reason: '$r');
      expect(b.requests.last['params'], {
        'state': true,
        'sceneId': 1,
        'speed': 150,
        'dimming': 100,
      });
      expect((await device('lamp'))['mode'], {
        'kind': 'scene',
        'label': 'Ocean',
        'scene': 'ocean',
        'sceneId': 1,
        'dynamic': true,
        'speed': 150,
      });
      await invoke('lamp', 'scene', {'scene': 'focus'});
      expect(b.requests.last['params'], {
        'state': true,
        'sceneId': 15,
        'dimming': 100,
      });
      await invoke('lamp', 'rgb', {'r': 0, 'g': 0, 'b': 0, 'w': 180});
      expect(b.pilot, containsPair('w', 180));
      expect(((await device('lamp'))['mode'] as Map)['kind'], 'colour');
      await invoke('lamp', 'color_temp', {'value': 2700});
      final d = await device('lamp');
      expect(d['mode'], {
        'kind': 'white',
        'label': 'Warm white 2700 K',
        'temp': 2700,
      });
      expect((d['state'] as Map).containsKey('speed'), isFalse);
    });

    test('the capability list gives each scene a name, a group and an icon, '
        'only those the bulb plays', () async {
      await add('lamp', module: 'ESP56_SHTW3_01', range: [2700, 6500]);
      await learned('lamp');
      final listed = await engine.handle('device.list', {
        'withCapabilities': true,
      });
      final caps = ((listed['devices'] as List).single as Map)['capabilities'];
      final scene = (caps as List).cast<Map>().singleWhere(
        (c) => c['id'] == 'scene',
      );
      final choices = ((scene['params'] as Map)['scene'] as Map)['choices'];
      expect(
        [for (final c in choices as List) (c as Map)['value']],
        [for (final s in wizScenesFor('white')) s.slug],
      );
      expect((choices.first as Map)['label'], 'Daylight');
      expect(
        (choices.cast<Map>().singleWhere(
          (c) => c['value'] == 'golden_white',
        ))['takes'],
        ['speed'],
      );
      final refused = await invoke('lamp', 'scene', {'scene': 'ocean'});
      expect((refused['error'] as Map)['type'], 'invalid');
      expect('${(refused['error'] as Map)['message']}', contains('scene'));
    });

    test('Rhythm and a scene the bulb lacks are refused in words, and '
        'nothing is sent', () async {
      final b = await add('lamp');
      final sent = b.requests.length;
      final rhythm = await invoke('lamp', 'scene', {'scene': 'rhythm'});
      expect((rhythm['error'] as Map)['type'], 'invalid');
      final speed = await invoke('lamp', 'scene', {
        'scene': 'ocean',
        'speed': 'fast',
      });
      expect((speed['error'] as Map)['type'], 'invalid');
      expect(b.requests.length, sent);
    });

    test('a captured scene puts the bulb back in its scene at its speed, '
        'or on its colour and white channels', () async {
      final b = await add('lamp');
      await learned('lamp');
      await invoke('lamp', 'scene', {'scene': 'party', 'speed': 60});
      final party = await engine.handle('scene.capture', {
        'name': 'Party time',
        'devices': ['lamp'],
      });
      expect(party['ok'], isTrue, reason: '$party');
      expect((party['actions'] as List).last, {
        'do': 'lamp.scene',
        'params': {'scene': 'party', 'speed': 60},
      });
      await invoke('lamp', 'rgb', {'r': 255, 'g': 40, 'b': 0, 'w': 30});
      final glow = await engine.handle('scene.capture', {
        'name': 'Glow',
        'devices': ['lamp'],
      });
      expect((glow['actions'] as List).last, {
        'do': 'lamp.rgb',
        'params': {'r': 255, 'g': 40, 'b': 0, 'c': 0, 'w': 30},
      });
      await invoke('lamp', 'color_temp', {'value': 4000});
      final run = await engine.handle('scene.run', {'id': party['id']});
      expect(run['ok'], isTrue, reason: '$run');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.pilot['sceneId'], 4);
      expect(b.pilot['speed'], 60);
      expect(b.pilot.containsKey('temp'), isFalse);
    });

    test('the sentence of a scene step names the scene', () async {
      await add('bedroom');
      final words = await engine.handle('rule.words', {
        'rule': {
          'when': [
            {'at': '07:00'},
          ],
          'then': [
            {
              'do': 'bedroom.scene',
              'params': {'scene': 'ocean'},
            },
            {
              'do': 'bedroom.rgb',
              'params': {'r': 0, 'g': 0, 'b': 255},
            },
          ],
        },
      });
      expect(words['ok'], isTrue, reason: '$words');
      final texts = [
        for (final p in (words['parts'] as List).cast<Map>())
          if (p['kind'] == 'step') p['text'],
      ];
      expect(texts, ['Bedroom Ocean scene', 'Bedroom blue colour']);
    });
  });
}
