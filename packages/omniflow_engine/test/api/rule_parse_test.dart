import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/rule_parse.dart';
import 'package:test/test.dart';

/// A home to read sentences against: two lamps and a TV in the living
/// room, a kettle plug in the kitchen, a hall light and a door sensor in
/// the hall, a fan, a thermometer, a person, two places, an NFC tag and a
/// scene.
ParseHome fixtureHome({
  bool withPerson = true,
  bool withLocation = true,
  bool withThermometer = true,
  bool twoThermometers = false,
}) {
  final registry = DriverRegistry.withBuiltIns();
  ParseThing thing(
    String id,
    String name,
    String driver, [
    String? room,
    Map<String, Object?> state = const {},
  ]) => ParseThing(
    id: id,
    name: name,
    driver: driver,
    manifest: registry[driver],
    room: room,
    state: state,
  );
  return ParseHome(
    things: [
      thing('desk_lamp', 'Desk lamp', 'philips_wiz_udp', 'living'),
      thing('floor_lamp', 'Floor lamp', 'philips_hue_light', 'living'),
      thing('tv', 'TV', 'android_tv_adb', 'living'),
      thing('kettle_plug', 'Kettle plug', 'tuya_plug', 'kitchen'),
      thing('hall_light', 'Hall light', 'philips_wiz_udp', 'hall'),
      thing('front_door', 'Front door', 'zigbee2mqtt_device', 'hall', {
        'contact': true,
      }),
      thing('fan', 'Fan', 'shelly_plus_switch', 'bedroom'),
      if (withThermometer)
        thing('thermometer', 'Thermometer', 'zigbee2mqtt_device', 'bedroom', {
          'temperature': 21,
        }),
      if (twoThermometers)
        thing('patio', 'Patio sensor', 'zigbee2mqtt_device', null, {
          'temperature': 25,
        }),
      if (withPerson) thing('jade', 'Jade', 'person'),
      thing('mira', 'Mira', 'person'),
      thing('home', 'Home', 'place'),
      thing('office', 'Office', 'place'),
      thing('door_tag', 'Door tag', 'nfc_tag'),
    ],
    rooms: const {
      'living': 'Living room',
      'kitchen': 'Kitchen',
      'hall': 'Hall',
      'bedroom': 'Bedroom',
    },
    automations: const {'movie_time': 'Movie time', 'bedtime': 'Bedtime'},
    person: withPerson ? 'jade' : null,
    homePlace: 'home',
    location: withLocation ? (latitude: 51.5, longitude: -0.12) : null,
    now: DateTime(2026, 6, 21, 12),
  );
}

const _context = RuleContext(
  places: {'home': 'home', 'office': 'office'},
  person: 'jade',
  personHome: 'home',
);

Future<RuleParse> read(String text, [ParseHome? home]) =>
    const GrammarRuleParser().parse(text, home ?? fixtureHome());

/// [text] read into a spec the rule normalizer accepts as it is.
Future<Map<String, Object?>> spec(String text, [ParseHome? home]) async {
  final r = await read(text, home);
  expect(r.problem, isNull, reason: 'problem for "$text": ${r.problem}');
  final s = r.spec!;
  final normalized = normalizeRule(s, context: _context);
  expect({...normalized}..remove('id'), s, reason: 'already stored form');
  return s;
}

Map<String, Object?> on(String ref, bool value) => {
  'do': ref,
  'params': {'value': value},
};

void main() {
  group('the six sentences of the brief', () {
    test('turn off the lights when I leave', () async {
      final s = await spec('turn off the lights when I leave');
      expect(s['when'], [
        {
          'on': 'jade.home',
          'change': {'to': false},
        },
      ]);
      expect(s['then'], [
        on('desk_lamp.power', false),
        on('floor_lamp.power', false),
        on('hall_light.power', false),
      ]);
      expect(s['name'], 'Turn off the lights when I leave');
    });

    test('at 7 every weekday turn on the kettle plug', () async {
      final s = await spec('at 7 every weekday turn on the kettle plug');
      expect(s['when'], [
        {
          'time': '07:00',
          'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
        },
      ]);
      expect(s['then'], [on('kettle_plug.power', true)]);
    });

    test('when the front door opens after sunset turn on the hall light for '
        '5 minutes', () async {
      final r = await read(
        'when the front door opens after sunset turn on the hall light for 5 '
        'minutes',
      );
      expect(r.problem, isNull);
      final s = r.spec!;
      expect(s['when'], [
        {
          'on': 'front_door.contact',
          'change': {'to': false},
        },
      ]);
      final between = (s['onlyIf'] as List).single as Map;
      expect(between['between'], hasLength(2));
      // Today's sunset to sunrise in this machine's time zone, which is
      // the zone the rule's time window is checked in.
      String hhmm(SunEvent e) {
        final t = sunEventOn(DateTime(2026, 6, 21, 12), e, (
          latitude: 51.5,
          longitude: -0.12,
        ))!;
        return '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}';
      }

      expect(between['between'], [
        hhmm(SunEvent.sunset),
        hhmm(SunEvent.sunrise),
      ]);
      expect(r.notes.single, contains('does not move with the seasons'));
      expect(s['then'], [
        on('hall_light.power', true),
        {'wait': 300000},
        on('hall_light.power', false),
      ]);
      normalizeRule(s, context: _context);
    });

    test('if it gets above 28 turn on the fan', () async {
      final s = await spec('if it gets above 28 turn on the fan');
      expect(s['when'], [
        {
          'on': 'thermometer.temperature',
          'crosses': {'above': 28},
        },
      ]);
      expect(s['then'], [on('fan.power', true)]);
    });

    test('every day at sunset run Movie time', () async {
      final s = await spec('every day at sunset run Movie time');
      expect(s['when'], [
        {'sun': 'sunset'},
      ]);
      expect(s['then'], [
        {'run': 'movie_time'},
      ]);
    });

    test(
      'when Jade gets home and it is after 18:00 turn on the living room',
      () async {
        final s = await spec(
          'when Jade gets home and it is after 18:00 turn on the living room',
        );
        expect(s['when'], [
          {
            'on': 'jade.home',
            'change': {'to': true},
          },
        ]);
        expect(s['onlyIf'], [
          {
            'between': ['18:00', '00:00'],
          },
        ]);
        expect(s['then'], [
          on('desk_lamp.power', true),
          on('floor_lamp.power', true),
          {'do': 'tv.wake'},
        ]);
      },
    );
  });

  group('triggers', () {
    test('I get home, I arrive home, I come back', () async {
      for (final t in ['I get home', 'I arrive home', 'I come back']) {
        final s = await spec('when $t turn on the desk lamp');
        expect(s['when'], [
          {
            'on': 'jade.home',
            'change': {'to': true},
          },
        ], reason: t);
      }
    });

    test('arriving at and leaving another place', () async {
      final s = await spec('when I arrive at the office turn off the fan');
      expect(s['when'], [
        {
          'on': 'office.inside',
          'change': {'to': true},
        },
      ]);
      final left = await spec('when I leave the office turn off the fan');
      expect(left['when'], [
        {
          'on': 'office.inside',
          'change': {'to': false},
        },
      ]);
    });

    test('another person leaving', () async {
      final s = await spec('when Mira leaves turn off the TV');
      expect(s['when'], [
        {
          'on': 'mira.home',
          'change': {'to': false},
        },
      ]);
      expect(s['then'], [
        {'do': 'tv.sleep'},
      ]);
    });

    test('times with am and pm, noon and a list of days', () async {
      expect((await spec('at 7:30pm turn on the desk lamp'))['when'], [
        {'time': '19:30'},
      ]);
      expect(
        (await spec('at noon on saturday and sunday toggle the fan'))['when'],
        [
          {
            'time': '12:00',
            'days': ['sat', 'sun'],
          },
        ],
      );
      expect((await spec('every weekend at 9 am turn on the kettle'))['when'], [
        {
          'time': '09:00',
          'days': ['sat', 'sun'],
        },
      ]);
    });

    test('sunrise with an offset', () async {
      final s = await spec('30 minutes before sunrise turn on the hall light');
      expect(s['when'], [
        {'sun': 'sunrise', 'offset': -30},
      ]);
      final later = await spec('an hour after sunset turn off the hall light');
      expect(later['when'], [
        {'sun': 'sunset', 'offset': 60},
      ]);
    });

    test('every few minutes', () async {
      final s = await spec('every 15 minutes toggle the fan');
      expect(s['when'], [
        {'interval': 900},
      ]);
    });

    test('a device turning on, and the TV through its power sensor', () async {
      final s = await spec(
        'when the desk lamp turns on turn on the floor lamp',
      );
      expect(s['when'], [
        {
          'on': 'desk_lamp.power',
          'change': {'to': true},
        },
      ]);
      final tv = await spec('when the TV turns on dim the floor lamp to 20%');
      expect(tv['when'], [
        {
          'on': 'tv.power_state',
          'change': {'to': 'on'},
        },
      ]);
      expect(tv['then'], [
        {
          'do': 'floor_lamp.brightness',
          'params': {'value': 20},
        },
      ]);
    });

    test('a tag scanned', () async {
      final s = await spec('when I scan the door tag run bedtime');
      expect(s['when'], [
        {'on': 'door_tag.scanned', 'event': true},
      ]);
    });

    test('a room temperature dropping below a number', () async {
      final s = await spec(
        'when the bedroom temperature drops below 18 turn on the fan',
      );
      expect(s['when'], [
        {
          'on': 'thermometer.temperature',
          'crosses': {'below': 18},
        },
      ]);
    });

    test('names a little misspelled still match', () async {
      final s = await spec('when I leave turn off the kitchen kettel plug');
      expect(s['then'], [on('kettle_plug.power', false)]);
      final hall = await spec('when the frnt door opens turn on hall lights');
      expect(hall['then'], [on('hall_light.power', true)]);
    });
  });

  group('conditions', () {
    test('only if I am home', () async {
      final s = await spec(
        'when the front door opens turn on the hall light only if I am home',
      );
      expect(s['onlyIf'], [
        {'state': 'jade.home', 'op': '==', 'value': true},
      ]);
    });

    test('days on an event trigger become a condition', () async {
      final s = await spec('when I get home on weekdays turn on the kettle');
      expect(s['onlyIf'], [
        {
          'days': ['mon', 'tue', 'wed', 'thu', 'fri'],
        },
      ]);
    });

    test('between two times', () async {
      final s = await spec(
        'when Mira gets home between 17:00 and 22:00 turn on the desk lamp',
      );
      expect(s['onlyIf'], [
        {
          'between': ['17:00', '22:00'],
        },
      ]);
    });

    test('after a time with nothing else says when it runs', () async {
      final s = await spec('after 18:00 turn on the desk lamp');
      expect(s['when'], [
        {'time': '18:00'},
      ]);
    });
  });

  group('steps', () {
    test('two devices joined by and, a toggle and a wait', () async {
      final s = await spec(
        'when I scan the door tag toggle the fan and the desk lamp then wait '
        '2 minutes and turn off the hall light',
      );
      expect(s['then'], [
        {'toggle': 'fan.power'},
        {'toggle': 'desk_lamp.power'},
        {'wait': 120000},
        on('hall_light.power', false),
      ]);
    });

    test('a TV turned off sleeps it', () async {
      final s = await spec('at midnight turn off the TV');
      expect(s['when'], [
        {'time': '00:00'},
      ]);
      expect(s['then'], [
        {'do': 'tv.sleep'},
      ]);
    });

    test('dim with no number dims to 30', () async {
      final s = await spec('at sunset dim the floor lamp');
      expect(s['then'], [
        {
          'do': 'floor_lamp.brightness',
          'params': {'value': 30},
        },
      ]);
    });

    test('the same sentence reads the same every time', () async {
      const text = 'when Jade gets home turn on the lights in the hall';
      expect((await read(text)).spec, (await read(text)).spec);
    });

    test('turn the lamp on, set brightness, several targets', () async {
      final s = await spec(
        'at 8 turn the desk lamp on and set the floor lamp to 40% and notify '
        'me Lights are on',
      );
      expect(s['then'], [
        on('desk_lamp.power', true),
        {
          'do': 'floor_lamp.brightness',
          'params': {'value': 40},
        },
        {
          'notify': {'title': 'Lights are on'},
        },
      ]);
    });

    test('the lights in a room', () async {
      final s = await spec('at 23:00 turn off the lights in the living room');
      expect(s['then'], [
        on('desk_lamp.power', false),
        on('floor_lamp.power', false),
      ]);
      final short = await spec('at 23:00 turn off the living room lights');
      expect(short['then'], s['then']);
    });

    test(
      'a lamp alone names the lamp, with the other lamp as an alternative',
      () async {
        final r = await read('at 7 turn on the lamp');
        expect(r.spec!['then'], [on('desk_lamp.power', true)]);
        expect(r.alternatives.single['text'], 'lamp');
        expect((r.alternatives.single['options'] as List).single, {
          'id': 'floor_lamp',
          'name': 'Floor lamp',
        });
      },
    );

    test(
      'two thermometers: the first, and the other as an alternative',
      () async {
        final r = await read(
          'if it gets above 28 turn on the fan',
          fixtureHome(twoThermometers: true),
        );
        expect(r.alternatives.single['text'], 'it');
      },
    );

    test('unknown words are listed and the rest still reads', () async {
      final r = await read('at 7 turn on the desk lamp quickly please');
      expect(r.problem, isNull);
      expect(r.unknown, ['quickly']);
    });
  });

  group('refuses plainly', () {
    Future<RuleParse> refused(String text, [ParseHome? home]) async {
      final r = await read(text, home);
      expect(r.spec, isNull, reason: text);
      expect(r.problem, isNotNull, reason: text);
      return r;
    }

    test('an empty sentence', () async {
      expect((await refused('   ')).problem, startsWith('Type what you want'));
    });

    test('something to do now, with no when', () async {
      expect(
        (await refused('turn on the desk lamp')).problem,
        contains('something to do now'),
      );
    });

    test('nothing to do', () async {
      expect(
        (await refused('when I get home')).problem,
        contains('what to do'),
      );
    });

    test('a device that is not in the home', () async {
      final r = await refused('when I leave turn off the jacuzzi');
      expect(r.problem, contains('jacuzzi'));
      expect(r.unknown, ['jacuzzi']);
    });

    test('a time that is not a time', () async {
      final r = await refused('at 25:00 turn on the desk lamp');
      expect(r.problem, '25:00 is not a time of day');
    });

    test('"I" with no person in the home', () async {
      final r = await refused(
        'when I leave turn off the fan',
        fixtureHome(withPerson: false),
      );
      expect(r.problem, contains('Add yourself as a person'));
    });

    test('after sunset with no home location', () async {
      final r = await refused(
        'when the front door opens after sunset turn on the hall light',
        fixtureHome(withLocation: false),
      );
      expect(r.problem, contains('home location'));
    });

    test('a temperature with nothing that reports one', () async {
      final r = await refused(
        'if it gets above 28 turn on the fan',
        fixtureHome(withThermometer: false, twoThermometers: false),
      );
      expect(r.problem, contains('temperature'));
    });

    test('a scene that does not exist', () async {
      final r = await refused('at 9 run party mode');
      expect(r.problem, contains('party mode'));
    });

    test('things it cannot do', () async {
      await refused('delete all my automations');
      await refused('unlock the front door when I get home');
      await refused('when everyone leaves turn off the lights');
      await refused('turn on the lamp unless it rains');
      await refused('when the desk lamp blinks turn on the fan');
      await refused('when I get home turn the desk lamp');
    });

    test('a sentence too long to read', () async {
      final r = await refused('at 7 turn on the desk lamp ${'and ' * 100}');
      expect(r.problem, contains('too long'));
    });
  });
}
