import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart';

/// What is wired to a pin, in the words of 5.2. Each role is one or two of
/// the firmware's pin modes; the engine checks the mode against the board.
enum PinRole {
  button('Button or switch', Symbols.radio_button_checked_rounded),
  relay('Relay or LED', Symbols.electric_bolt_rounded),
  dimmer('Dimmer', Symbols.brightness_medium_rounded),
  servo('Servo', Symbols.rotate_right_rounded),
  analog('Analog sensor', Symbols.tune_rounded);

  const PinRole(this.label, this.icon);

  final String label;
  final IconData icon;

  static PinRole of(String? mode) => switch (mode) {
    'in' || 'in_pullup' => button,
    'pwm' => dimmer,
    'servo' => servo,
    'adc' => analog,
    _ => relay,
  };

  /// The firmware mode for this role. A button wired to ground uses the
  /// pin's pull-up, so a press reads on.
  String mode({bool toGround = true}) => switch (this) {
    button => toGround ? 'in_pullup' : 'in',
    relay => 'out',
    dimmer => 'pwm',
    servo => 'servo',
    analog => 'adc',
  };
}

/// The board.describe capability a pin mode needs.
String capabilityFor(String mode) => switch (mode) {
  'in_pullup' => 'pullup',
  final m => m,
};

/// One named pin from a board device's `pins` setting.
class NamedPin {
  const NamedPin({
    required this.name,
    required this.pin,
    required this.mode,
    this.invert = false,
  });

  final String name;
  final int pin;
  final String mode;
  final bool invert;

  PinRole get role => PinRole.of(mode);

  /// "Door sensor" for `door_sensor`.
  String get label {
    final words = name.replaceAll('_', ' ').trim();
    return words.isEmpty
        ? name
        : '${words[0].toUpperCase()}${words.substring(1)}';
  }

  /// The pin and its job in plain words: "GPIO 3 · button to ground".
  String get description => [
    'GPIO $pin',
    switch (mode) {
      'in_pullup' => 'button to ground',
      'in' => 'button',
      'out' => 'switch',
      'pwm' => 'dimmer',
      'servo' => 'servo',
      'adc' => 'analog',
      final m => m,
    },
    if (mode == 'out' && invert) 'active low',
  ].join(' · ');

  /// What the pin reads now, from the board device's [state]: pressed or
  /// released, a level or an angle. Null for an output, which shows a
  /// switch instead.
  String? valueIn(Json state) {
    final v = state[name];
    return switch (mode) {
      'out' => null,
      'in' || 'in_pullup' => switch (v) {
        true => 'pressed',
        false => 'released',
        _ => '-',
      },
      'servo' => v is num ? '${v.round()}°' : '-',
      _ => v is num ? '${v.round()}%' : '-',
    };
  }

  Json toJson() => {
    'pin': pin,
    'mode': mode,
    if (mode == 'out' && invert) 'invert': true,
  };

  /// The pins of a board device row, in the order they were named.
  static List<NamedPin> ofDevice(Json device) {
    final pins = (device['settings'] as Map? ?? const {})['pins'];
    return [
      if (pins is Map)
        for (final e in pins.entries)
          if (e.value case {'pin': final int pin} && final Map spec)
            NamedPin(
              name: '${e.key}',
              pin: pin,
              mode: '${spec['mode'] ?? 'out'}',
              invert: spec['invert'] == true,
            ),
    ];
  }

  /// The raw `pins` setting of [device], kept as the engine stores it so a
  /// save does not drop keys this screen does not edit (a `watch`).
  static Json rawOf(Json device) => Map<String, Object?>.from(
    (device['settings'] as Map? ?? const {})['pins'] as Map? ?? const {},
  );
}

/// A pin name the engine takes, made from what the user typed: lower snake
/// case starting with a letter. The engine still judges it.
String pinNameFor(String typed) {
  final id = typed
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (id.isEmpty) return '';
  return RegExp(r'^[a-z]').hasMatch(id) ? id : 'pin_$id';
}

/// The board type as people say it: "ESP32", "Pico W".
String boardTypeLabel(String? board) => switch (board) {
  null => 'Board',
  'esp32' => 'ESP32',
  'esp8266' => 'ESP8266',
  'pico_w' || 'picow' || 'rp2040' => 'Pico W',
  'uno' => 'Uno',
  'native' || 'virtual' => 'Virtual board',
  final b => b.toUpperCase(),
};

/// The extras of 5.1, as each firmware type is named for people.
abstract final class BoardExtras {
  static const ir = 'ir';
  static const rf = 'rf';
  static const rc522 = 'nfc_rc522';
  static const pn532 = 'nfc_pn532';

  static String title(String type) => switch (type) {
    ir => 'IR LED',
    rf => 'RF transmitter',
    _ => 'NFC reader',
  };

  static String job(String type) => switch (type) {
    ir => 'send remote codes',
    rf => 'send 433 MHz codes',
    _ => 'read NFC tags',
  };

  static String chip(String type) => switch (type) {
    rc522 => 'RC522',
    pn532 => 'PN532',
    _ => '',
  };

  static IconData icon(String type) => switch (type) {
    ir => Symbols.settings_remote_rounded,
    rf => Symbols.cell_tower_rounded,
    _ => Symbols.nfc_rounded,
  };

  /// The lines each extra takes on the board, which the user picks.
  static List<String> lines(String type) => switch (type) {
    ir || rf => const ['tx'],
    rc522 => const ['ss', 'rst'],
    pn532 => const ['sda', 'scl'],
    _ => const [],
  };

  static String lineLabel(String line) => switch (line) {
    'tx' => 'Signal pin',
    'ss' => 'SS (SDA) pin',
    'rst' => 'RST pin',
    'sda' => 'SDA pin',
    'scl' => 'SCL pin',
    final l => l.toUpperCase(),
  };
}
