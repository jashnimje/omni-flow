import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

Map<String, Object?> manifest(
  List<Object?> capabilities, {
  String? transport,
}) => {
  'schemaVersion': 1,
  'id': 'gadget',
  'name': 'Gadget',
  'category': 'other',
  'transport': {'type': transport ?? 'virtual'},
  'capabilities': capabilities,
};

List<String> problems(Map<String, Object?> json) {
  try {
    DriverManifest.parse(json);
    return const [];
  } on ValidationException catch (e) {
    return e.issues.map((i) => '$i').toList();
  }
}

void main() {
  test('an event takes a dotted id, keeps no state and has no command', () {
    final m = DriverManifest.parse(
      manifest([
        {'id': 'button.pressed', 'type': 'event', 'label': 'Pressed'},
        {'id': 'level', 'type': 'sensor', 'stateJsonPath': r'$.level'},
      ]),
    );
    final event = m.capability('button.pressed')!;
    expect(event.type, CapabilityType.event);
    expect(event.type.hasCommand, isFalse);
    expect(event.params, isEmpty);
    expect(m.transport.type, TransportType.virtual);
  });

  test('an event with a command, state or a bad id is refused', () {
    expect(
      problems(
        manifest([
          {
            'id': 'pressed',
            'type': 'event',
            'command': {'cmd': 'x'},
          },
        ]),
      ).join(),
      contains('an event has no command'),
    );
    expect(
      problems(
        manifest([
          {'id': 'pressed', 'type': 'event', 'stateJsonPath': r'$.pressed'},
        ]),
      ).join(),
      contains('an event keeps no state'),
    );
    expect(
      problems(
        manifest([
          {'id': 'Button.Pressed', 'type': 'event'},
        ]),
      ).join(),
      contains('dotted parts allowed'),
    );
    expect(
      problems(
        manifest([
          {
            'id': 'button.pressed',
            'type': 'action',
            'command': {'cmd': 'x'},
          },
        ]),
      ).join(),
      contains('must be lower snake case'),
    );
  });

  test('the virtual drivers are built in', () {
    final registry = DriverRegistry.withBuiltIns();
    Set<String> ids(String driver, CapabilityType type) => {
      for (final c in registry[driver]!.capabilities)
        if (c.type == type) c.id,
    };
    for (final id in ['phone', 'person', 'place', 'nfc_tag']) {
      expect(registry[id]!.transport.type, TransportType.virtual, reason: id);
      expect(registry[id]!.isHighRisk, isFalse, reason: id);
    }
    expect(ids('phone', CapabilityType.sensor), {
      'wifi_ssid',
      'wifi_bssid',
      'battery',
      'charging',
      'app_on_screen',
      'bluetooth_devices',
      'screen_on',
      'dnd_on',
      'next_alarm',
      'call',
      'media_playing',
      'headphones',
      'face_down',
    });
    expect(ids('phone', CapabilityType.event), {
      'nfc_scanned',
      'app_opened',
      'app_closed',
      'notification',
      'bluetooth_connected',
      'bluetooth_disconnected',
      'alarm_soon',
      'call_ringing',
      'call_answered',
      'call_ended',
      'media_started',
      'media_stopped',
      'calendar_started',
      'calendar_ended',
      'shaken',
      'started_up',
      'app_installed',
      'app_updated',
    });
    expect(ids('phone', CapabilityType.action), {
      'speak',
      'vibrate',
      'play_sound',
      'ringer',
      'media_volume',
      'media',
      'open_app',
      'open_link',
      'set_alarm',
      'set_timer',
      'show_message',
    });
    expect(ids('phone', CapabilityType.toggle), {'torch', 'set_dnd'});
    expect(ids('person', CapabilityType.sensor), {
      'home',
      'place',
      'home_source',
      'home_since',
    });
    expect(ids('place', CapabilityType.sensor), {'inside', 'people'});
    expect(ids('nfc_tag', CapabilityType.sensor), {'last_scanned'});
    expect(ids('nfc_tag', CapabilityType.event), {'scanned'});
    expect(registry['nfc_tag']!.settings.map((s) => (s.key, s.secret)), [
      ('uid', false),
    ]);
  });

  test('a board input pin raises changed, pressed and released', () {
    final registry = DriverRegistry.withBuiltIns();
    final board = Device(
      id: 'desk_board',
      name: 'Desk board',
      driverId: 'omniflow_board',
      host: '192.0.2.5',
      settings: const {
        'pins': {
          'button': {'pin': 0, 'mode': 'in_pullup'},
          'light': {'pin': 34, 'mode': 'adc'},
          'relay': {'pin': 4, 'mode': 'out'},
        },
      },
    );
    final events = {
      for (final c in manifestFor(registry, board)!.capabilities)
        if (c.type == CapabilityType.event) c.id,
    };
    expect(events, {
      'button.changed',
      'button.pressed',
      'button.released',
      'light.changed',
    });
  });
}
