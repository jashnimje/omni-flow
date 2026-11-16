@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/away_lighting.dart';
import 'package:omniflow_engine/src/api/energy_commands.dart';
import 'package:omniflow_engine/src/api/smart_home.dart';
import 'package:omniflow_engine/src/api/sun_lighting.dart';
import 'package:omniflow_engine/src/api/weather.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// A light on the virtual transport: commands are taken as sent.
const _light = {
  'schemaVersion': 1,
  'id': 'test_lamp',
  'name': 'Test lamp',
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
        'value': {'type': 'number', 'integer': true, 'min': 1, 'max': 100},
      },
      'command': {'set': 'brightness', 'value': '{{value}}'},
      'stateJsonPath': r'$.brightness',
    },
    {
      'id': 'color_temp',
      'type': 'color_temp',
      'label': 'White temperature',
      'params': {
        'value': {
          'type': 'number',
          'integer': true,
          'min': 2200,
          'max': 6500,
          'unit': 'K',
        },
      },
      'command': {'set': 'temp', 'value': '{{value}}'},
      'stateJsonPath': r'$.temp',
    },
  ],
};

/// An Open-Meteo reply for 14:45 local time.
Map<String, Object?> _forecast() => {
  'current': {
    'time': '2026-11-12T14:45',
    'temperature_2m': 31.4,
    'apparent_temperature': 33.0,
    'relative_humidity_2m': 40,
    'wind_speed_10m': 12.5,
    'weather_code': 61,
    'uv_index': 6.2,
  },
  'hourly': {
    'time': ['2026-11-12T14:00', '2026-11-12T15:00', '2026-11-12T16:00'],
    'precipitation': [0.0, 1.2, 0.4],
    'precipitation_probability': [10, 70, 30],
  },
  'daily': {
    'temperature_2m_max': [32.0, 29.0],
    'temperature_2m_min': [21.5, 20.0],
  },
};

/// Serves [handle] on loopback.
Future<HttpServer> _serve(
  FutureOr<Object?> Function(HttpRequest request) handle,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = await handle(request);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  });
  return server;
}

void main() {
  late Directory home;
  late OmniEngine engine;

  Future<OmniEngine> open() => OmniEngine.open(
    home: home,
    secrets: InMemorySecretStore(),
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  Future<Map<String, Object?>> ok(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isTrue, reason: '$command: $r');
    return r;
  }

  Future<Map<String, Object?>> error(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await engine.handle(command, args);
    expect(r['ok'], isFalse, reason: '$command: $r');
    return Map<String, Object?>.from(r['error'] as Map);
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_smart_home');
    engine = await open();
  });

  tearDown(() async {
    SmartHome.weatherSourceOverride = null;
    await engine.close();
    await home.delete(recursive: true);
  });

  group('weather', () {
    test('the request rounds home to two decimals and asks for the fields', () {
      final uri = weatherRequest((latitude: 51.507412, longitude: -0.127812));
      expect(uri.host, 'api.open-meteo.com');
      expect(uri.queryParameters['latitude'], '51.51');
      expect(uri.queryParameters['longitude'], '-0.13');
      expect(uri.queryParameters['current'], contains('uv_index'));
      expect(
        uri.queryParameters['hourly'],
        contains('precipitation_probability'),
      );
      expect(uri.queryParameters['timezone'], 'auto');
    });

    test('a reply becomes plain state, with the next hour of rain', () {
      final state = weatherState(_forecast(), DateTime.utc(2026, 11, 12, 9));
      expect(state['temperature'], 31.4);
      expect(state['feels_like'], 33.0);
      expect(state['humidity'], 40);
      expect(state['wind_speed'], 12.5);
      expect(state['uv_index'], 6.2);
      expect(state['condition'], 'Light rain');
      expect(state['rain_next_hour'], 1.2);
      expect(state['rain_chance_next_hour'], 70);
      expect(state['rain_expected'], isTrue);
      expect(state['high_today'], 32.0);
      expect(state['low_today'], 21.5);
      expect(weatherWords(0), 'Clear sky');
      expect(weatherWords(95), 'Thunderstorm');
      expect(weatherWords(1234), 'Unknown');
      expect(
        () => weatherState({'nope': 1}, DateTime.now()),
        throwsFormatException,
      );
    });

    test(
      'adding weather needs home, then reads it through the web requester',
      () async {
        final missing = await error('weather.add');
        expect(missing['message'], contains('where home is'));

        final asked = <Uri>[];
        final server = await _serve((r) {
          asked.add(r.uri);
          return _forecast();
        });
        addTearDown(server.close);
        SmartHome.weatherSourceOverride = WeatherSource(
          web: IoWebRequester(refusal: (_) => null),
          base: Uri.parse('http://127.0.0.1:${server.port}/v1/forecast'),
        );
        await engine.close();
        engine = await open();
        await ok('home.location.set', {
          'latitude': 12.97194,
          'longitude': 77.59369,
        });

        final added = await ok('weather.add');
        final id = added['id'] as String;
        expect(asked.single.queryParameters['latitude'], '12.97');
        expect(asked.single.queryParameters['longitude'], '77.59');
        final device = (await ok('device.get', {'id': id}))['device'] as Map;
        expect(device['name'], 'Weather at home');
        final state = device['state'] as Map;
        expect(state['temperature'], 31.4);
        expect(state['rain_expected'], isTrue);

        final refreshed = await ok('weather.refresh');
        expect((refreshed['weather'] as List), hasLength(1));
        expect(asked, hasLength(2));
      },
    );

    test('a weather rule reads as a sentence from the driver labels', () async {
      await ok('home.location.set', {'latitude': 1, 'longitude': 1});
      SmartHome.weatherSourceOverride = WeatherSource(web: _NoWeb());
      await engine.close();
      engine = await open();
      final added = await ok('weather.add');
      expect(added['problem'], contains('Added'));
      final id = added['id'];
      final view = await ok('automation.save', {
        'form': 'rule',
        'trusted': true,
        'spec': {
          'name': 'Hot outside',
          'when': [
            {
              'on': '$id.temperature',
              'crosses': {'above': 30},
            },
          ],
          'then': [
            {
              'notify': {'title': 'Hot'},
            },
          ],
        },
      });
      expect(view['id'], 'hot_outside');
      final list = await ok('automation.list');
      expect(jsonEncode(list), contains('outside temperature'));
    });

    test(
      'the engine requester refuses this machine, so the guard holds',
      () async {
        final server = await _serve((_) => _forecast());
        addTearDown(server.close);
        SmartHome.weatherSourceOverride = WeatherSource(
          base: Uri.parse('http://127.0.0.1:${server.port}/v1/forecast'),
        );
        await engine.close();
        engine = await open();
        await ok('home.location.set', {'latitude': 1, 'longitude': 1});
        await ok('weather.add');
        final refused = await error('weather.refresh');
        expect(refused['type'], 'unavailable');
        expect(refused['message'], contains('this machine'));
      },
    );

    test('Open-Meteo answers for real', () async {
      final state = await WeatherSource().read((
        latitude: 51.5,
        longitude: -0.12,
      ), DateTime.now());
      expect(state['temperature'], isA<num>());
      expect(state['condition'], isNot('Unknown'));
    }, tags: ['live']);
  });

  group('lights that follow the sun', () {
    const london = (latitude: 51.5074, longitude: -0.1278);

    test('the sun is high at a summer noon and below at midnight', () {
      final noon = sunElevation(DateTime.utc(2026, 6, 21, 12), london);
      expect(noon, closeTo(62, 1));
      expect(sunElevation(DateTime.utc(2026, 6, 21, 0), london), lessThan(-10));
      expect(peakElevation(DateTime(2026, 6, 21), london), closeTo(62, 1));
    });

    test('the curve is warm and dim at night, cool and bright at the peak', () {
      const curve = SunCurve();
      expect(curve.at(-20, 60), (kelvin: 2200, brightness: 30));
      expect(curve.at(60, 60), (kelvin: 5000, brightness: 100));
      final middle = curve.at(27, 60);
      expect(middle.kelvin, inExclusiveRange(2200, 5000));
      expect(SunCurve.dayShare(10, -10), 0);
      expect(
        () => SunCurve.of({'minK': 5000, 'maxK': 3000}),
        throwsA(isA<ApiError>()),
      );
      final preview = curve.preview(DateTime(2026, 6, 21), london);
      expect(preview, hasLength(48));
    });

    test('a followed light that is on takes the curve, and a change by hand pauses it', () async {
      await ok('driver.register', {'manifest': _light});
      await ok('device.add', {
        'id': 'desk',
        'name': 'Desk',
        'driver': 'test_lamp',
      });
      await ok('device.add', {
        'id': 'hall',
        'name': 'Hall',
        'driver': 'test_lamp',
      });

      expect((await ok('sunlight.get'))['problem'], contains('where home is'));
      await ok('home.location.set', {
        'latitude': london.latitude,
        'longitude': london.longitude,
      });

      final notLight = await error('sunlight.set', {
        'targets': ['nope'],
        'enabled': true,
      });
      expect(notLight['type'], 'not_found');

      final set = await ok('sunlight.set', {
        'targets': ['desk', 'hall'],
        'enabled': true,
        'minK': 2400,
        'maxK': 4800,
      });
      expect((set['targets'] as List), hasLength(2));
      expect(set['preview'], hasLength(48));

      await ok('device.invoke', {
        'id': 'desk',
        'capability': 'power',
        'params': {'value': true},
      });
      final applied = await ok('sunlight.apply');
      expect(applied['applied'], ['desk']);
      expect(applied['off'], ['hall']);
      final state =
          ((await ok('device.get', {'id': 'desk'}))['device'] as Map)['state']
              as Map;
      expect(state['temp'], inInclusiveRange(2400, 4800));
      expect(state['brightness'], inInclusiveRange(30, 100));

      await ok('device.invoke', {
        'id': 'desk',
        'capability': 'brightness',
        'params': {'value': 7},
      });
      final again = await ok('sunlight.apply');
      expect(again['paused'], ['desk']);
      expect(
        ((await ok('sunlight.get'))['paused'] as List).single['id'],
        'desk',
      );

      await ok('sunlight.set', {
        'targets': ['desk', 'hall'],
        'enabled': false,
      });
      expect((await ok('sunlight.get'))['targets'], isEmpty);
    });

    test(
      'a room follows the sun for every light in it, and is saved',
      () async {
        await ok('driver.register', {'manifest': _light});
        await ok('room.save', {'id': 'study', 'name': 'Study'});
        await ok('device.add', {
          'id': 'desk',
          'name': 'Desk',
          'driver': 'test_lamp',
          'room': 'study',
        });
        // Follow the sun needs home on the map first.
        expect(
          (await error('sunlight.set', {
            'targets': ['study'],
            'enabled': true,
          }))['message'],
          contains('where Home is'),
        );
        await ok('home.location.set', {'latitude': 51.5, 'longitude': -0.12});
        await ok('sunlight.set', {
          'targets': ['study'],
          'enabled': true,
        });
        await engine.close();
        engine = await open();
        final got = await ok('sunlight.get');
        final target = (got['targets'] as List).single as Map;
        expect(target['kind'], 'room');
        expect(target['name'], 'Study');
        expect(target['lights'], ['desk']);
      },
    );
  });

  group('away lighting', () {
    test('the plan replays last week within 20 minutes, the same each time, in order', () {
      final date = DateTime(2026, 11, 12);
      final lastWeek = {
        'desk': [
          (at: DateTime(2026, 11, 5, 19, 0), on: true),
          (at: DateTime(2026, 11, 5, 19, 2), on: false),
          (at: DateTime(2026, 11, 5, 22, 30), on: true),
        ],
      };
      final plan = awayPlan(date, lastWeek);
      expect(plan, hasLength(3));
      expect(awayPlan(date, lastWeek), plan);
      for (final (i, a) in plan.indexed) {
        final source = lastWeek['desk']![i].at;
        final wanted = DateTime(2026, 11, 12, source.hour, source.minute);
        expect(a.at.difference(wanted).inMinutes.abs(), lessThanOrEqualTo(21));
        if (i > 0) expect(a.at.isAfter(plan[i - 1].at), isTrue);
      }
      expect(plan.map((a) => a.on), [true, false, true]);
      expect(
        dueActions(
          plan,
          DateTime(2026, 11, 12, 18),
          DateTime(2026, 11, 12, 20),
        ),
        hasLength(2),
      );
    });

    test('the preview reads last week from device history, without its own replays', () async {
      await ok('driver.register', {'manifest': _light});
      await ok('device.add', {
        'id': 'desk',
        'name': 'Desk',
        'driver': 'test_lamp',
      });
      await engine.close();

      final today = DateTime.now();
      final week = DateTime(today.year, today.month, today.day - 7);
      final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
      await DriftHistoryStore(db).add('desk', [
        HistoryEntry(
          week.add(const Duration(hours: 19)).toUtc(),
          'power',
          true,
          by: 'user',
        ),
        HistoryEntry(
          week.add(const Duration(hours: 23)).toUtc(),
          'power',
          false,
        ),
        HistoryEntry(
          week.add(const Duration(hours: 20)).toUtc(),
          'power',
          true,
          by: awaylightBy,
        ),
        HistoryEntry(
          week.add(const Duration(hours: 20)).toUtc(),
          'brightness',
          50,
        ),
      ]);
      await db.close();
      engine = await open();

      expect(
        (await error('awaylight.set', {
          'lights': ['nope'],
        }))['type'],
        'not_found',
      );
      final set = await ok('awaylight.set', {
        'lights': ['desk'],
        'enabled': true,
      });
      expect(set['enabled'], isTrue);
      expect(set['away'], isFalse);

      final preview = await ok('awaylight.preview');
      final actions = preview['actions'] as List;
      expect(actions, hasLength(2));
      expect(actions.map((a) => (a as Map)['on']), [true, false]);
      expect((actions.first as Map)['name'], 'Desk');
      expect(
        await error('awaylight.preview', {'date': '12/11/2026'}),
        isNotEmpty,
      );
    });
  });

  group('energy', () {
    test('each driver reports power in watts and its counter in kWh', () {
      expect(
        energyReading('shelly_plus_switch', {
          'apower': 12.5,
          'aenergy': {'total': 1500},
        }),
        (watts: 12.5, counterKwh: 1.5),
      );
      expect(
        energyReading('shelly_gen1_relay', {'power': 60, 'total': 120000}),
        (watts: 60.0, counterKwh: 2.0),
      );
      expect(energyReading('tuya_plug', {'19': 1234}), (
        watts: 123.4,
        counterKwh: null,
      ));
      expect(energyReading('tuya_plug', {'1': true}), isNull);
      expect(energyReading('philips_wiz_udp', {'state': true}), isNull);
    });

    test('a counter wins, power is integrated where there is none, and a long gap is capped', () {
      final meter = EnergyMeter();
      final t = DateTime(2026, 11, 12, 10);
      meter.add('a', t, (watts: 100, counterKwh: 1.0));
      meter.add('a', t.add(const Duration(minutes: 5)), (
        watts: 100,
        counterKwh: 1.25,
      ));
      expect(meter.on('a', t), closeTo(0.25, 1e-9));

      meter.add('b', t, (watts: 1000, counterKwh: null));
      meter.add('b', t.add(const Duration(minutes: 6)), (
        watts: 1000,
        counterKwh: null,
      ));
      expect(meter.on('b', t), closeTo(0.1, 1e-9));
      // A gap longer than an hour counts only its first hour.
      meter.add('b', t.add(const Duration(hours: 4)), (
        watts: 1000,
        counterKwh: null,
      ));
      expect(meter.on('b', t), closeTo(1.1, 1e-9));

      final late = DateTime(2026, 11, 12, 23, 55);
      meter.add('c', late, (watts: 600, counterKwh: null));
      meter.add('c', late.add(const Duration(minutes: 10)), (
        watts: 600,
        counterKwh: null,
      ));
      expect(meter.on('c', late), closeTo(0.05, 1e-9));
      expect(meter.on('c', DateTime(2026, 11, 13)), closeTo(0.05, 1e-9));
    });

    test('a Shelly Plus reading becomes today\'s kWh and cost', () async {
      var total = 1000.0;
      final server = await _serve((r) {
        expect(r.uri.path, '/rpc/Switch.GetStatus');
        return {
          'id': 0,
          'output': true,
          'apower': 42.0,
          'voltage': 230.1,
          'current': 0.2,
          'aenergy': {'total': total},
        };
      });
      addTearDown(server.close);
      await ok('device.add', {
        'id': 'kettle',
        'name': 'Kettle',
        'driver': 'shelly_plus_switch',
        'host': '127.0.0.1',
        'port': server.port,
      });
      await ok('device.refresh', {'id': 'kettle'});
      total = 1750;
      await ok('device.refresh', {'id': 'kettle'});

      await ok('energy.price.set', {'perKwh': 8, 'currency': '₹'});
      final summary = await ok('energy.summary');
      final row = (summary['devices'] as List).single as Map;
      expect(row['watts'], 42.0);
      expect(row['todayKwh'], 0.75);
      expect(row['weekKwh'], 0.75);
      expect(row['todayCost'], 6.0);
      expect((row['days'] as List), hasLength(7));
      expect((summary['total'] as Map)['todayKwh'], 0.75);
      expect(summary['price'], {'perKwh': 8.0, 'currency': '₹'});
      expect(
        ((await ok('energy.summary', {'days': 3}))['devices'] as List)
            .single['days'],
        hasLength(3),
      );
      expect((await error('energy.summary', {'days': 0}))['type'], 'invalid');
      expect(
        (await error('energy.price.set', {'perKwh': -1}))['type'],
        'invalid',
      );

      await engine.close();
      engine = await open();
      final kept = await ok('energy.summary');
      expect(((kept['devices'] as List).single as Map)['todayKwh'], 0.75);
    });

    test('a Shelly Gen1 reads its meter beside the relay', () async {
      final server = await _serve(
        (_) => {
          'relays': [
            {'ison': true},
          ],
          'meters': [
            {'power': 15.5, 'total': 6000, 'is_valid': true},
          ],
        },
      );
      addTearDown(server.close);
      await ok('device.add', {
        'id': 'fan',
        'name': 'Fan',
        'driver': 'shelly_gen1_relay',
        'host': '127.0.0.1',
        'port': server.port,
      });
      final device =
          (await ok('device.refresh', {'id': 'fan'}))['device'] as Map;
      final state = device['state'] as Map;
      expect(state['ison'], isTrue);
      expect(state['power'], 15.5);
      expect(state['total'], 6000);
    });
  });

  test('every new command has an agent policy entry', () {
    for (final c in ['energy.summary', 'energy.price']) {
      expect(agentRefusal(c, const {}, AgentAccess.read), isNull, reason: c);
    }
    for (final c in [
      'sunlight.set',
      'sunlight.get',
      'sunlight.apply',
      'awaylight.set',
      'awaylight.get',
      'awaylight.preview',
      'energy.price.set',
      'weather.add',
      'weather.refresh',
    ]) {
      expect(engine.commandNames, contains(c));
      expect(
        agentRefusal(c, const {}, AgentAccess.read),
        contains('Set up everything'),
        reason: c,
      );
      expect(agentRefusal(c, const {}, AgentAccess.setup), isNull, reason: c);
    }
  });
}

class _NoWeb implements WebRequester {
  @override
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async => throw StateError('offline');
}
