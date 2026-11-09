import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';
import '../manifest/driver_registry.dart';
import '../manifest/param_spec.dart';
import '../manifest/validation.dart';
import 'channels.dart';
import 'device.dart';

/// What a board pin is used for, as the firmware names it.
enum PinMode {
  input('in'),
  inputPullup('in_pullup'),
  output('out'),
  pwm('pwm'),
  servo('servo'),
  adc('adc');

  const PinMode(this.wireName);

  final String wireName;

  static PinMode? fromWire(Object? name) =>
      values.where((m) => m.wireName == name).firstOrNull;

  bool get isInput => this == input || this == inputPullup || this == adc;
  bool get isDigitalInput => this == input || this == inputPullup;
}

/// One named pin from a board device's `pins` setting:
///
///     "door": {"pin": 0, "mode": "in_pullup", "watch": {"ms": 50}}
///
/// Inputs are watched by default (every 50 ms, or every second with a delta
/// of 2 for `adc`); `"watch": false` turns that off. A digital input reads
/// true when the pin is high, except `in_pullup`, which is active low (a
/// button to ground reads true while pressed) unless `"invert": false`.
/// An `out` pin with `"invert": true` is active low, for a relay module that
/// switches on at LOW: its state stays true for on, and the pin is driven to
/// the opposite level.
class BoardPin {
  const BoardPin({
    required this.name,
    required this.pin,
    required this.mode,
    this.watchMs,
    this.watchDelta = 0,
    this.invert = false,
  });

  final String name;
  final int pin;
  final PinMode mode;

  /// How often the board checks the pin, or null when it is not watched.
  final int? watchMs;
  final int watchDelta;
  final bool invert;

  /// The device state value for a raw reading: a bool for a digital input or
  /// an output, the number itself for everything else.
  Object stateValue(num raw) => switch (mode) {
    PinMode.input ||
    PinMode.inputPullup ||
    PinMode.output => (raw != 0) != invert,
    _ => raw,
  };

  /// The level an output is driven to for the logical [on].
  int levelFor(bool on) => on != invert ? 1 : 0;

  CapabilitySpec get capability => switch (mode) {
    PinMode.output => CapabilitySpec(
      id: name,
      type: CapabilityType.toggle,
      label: name,
      params: CapabilityType.toggle.defaultParams,
      command: {'cmd': 'pin.write', 'pin': pin, 'value': '{{value}}'},
      stateJsonPath: '\$.$name',
      onOff: invert ? (levelFor(true), levelFor(false)) : null,
    ),
    PinMode.pwm || PinMode.servo => CapabilitySpec(
      id: name,
      type: CapabilityType.level,
      label: name,
      params: {
        'value': ParamSpec(
          type: ParamType.number,
          min: 0,
          max: mode == PinMode.pwm ? 100 : 180,
          unit: mode == PinMode.pwm ? '%' : 'deg',
        ),
      },
      command: {
        'cmd': mode == PinMode.pwm ? 'pwm.write' : 'servo.write',
        'pin': pin,
        'value': '{{value}}',
      },
      stateJsonPath: '\$.$name',
    ),
    _ => CapabilitySpec(
      id: name,
      type: CapabilityType.sensor,
      label: name,
      params: const {},
      command: null,
      stateJsonPath: '\$.$name',
    ),
  };

  /// The events this pin raises as `<name>.<event>`: a watched input
  /// `changed`, and a digital one also `pressed` when it turns true and
  /// `released` when it turns false.
  List<String> get eventKeys => [
    if (mode.isInput) '$name.changed',
    if (mode.isDigitalInput) ...['$name.pressed', '$name.released'],
  ];

  List<CapabilitySpec> get events => [
    for (final key in eventKeys)
      CapabilitySpec(
        id: key,
        type: CapabilityType.event,
        label: key.replaceAll('.', ' '),
        params: const {},
        command: null,
      ),
  ];

  Map<String, Object?> toJson() => {
    'pin': pin,
    'mode': mode.wireName,
    if (mode.isInput)
      'watch': watchMs == null ? false : {'ms': watchMs, 'delta': watchDelta},
    if ((mode.isDigitalInput || mode == PinMode.output) &&
        invert != (mode == PinMode.inputPullup))
      'invert': invert,
  };
}

final _pinName = RegExp(r'^[a-z][a-z0-9_]*$');

/// Parses and checks a `pins` setting. [reserved] are the driver's own
/// capability ids, which a pin name may not take. Throws a
/// [ValidationException] listing every problem.
List<BoardPin> parseBoardPins(Object? json, {Set<String> reserved = const {}}) {
  if (json == null) return const [];
  final issues = <ValidationIssue>[];
  if (json is! Map) {
    throw ValidationException('pins', [
      const ValidationIssue(r'$', 'must be an object of name -> {pin, mode}'),
    ]);
  }
  final pins = <BoardPin>[];
  final used = <int, String>{};
  for (final entry in json.entries) {
    final name = '${entry.key}';
    final path = '\$.$name';
    if (!_pinName.hasMatch(name)) {
      issues.add(ValidationIssue(path, 'a pin name is lower snake case'));
      continue;
    }
    if (reserved.contains(name)) {
      issues.add(
        ValidationIssue(path, '"$name" is already a capability of this board'),
      );
      continue;
    }
    final spec = entry.value;
    if (spec is! Map) {
      issues.add(ValidationIssue(path, 'must be {"pin": N, "mode": ...}'));
      continue;
    }
    final pin = spec['pin'];
    final mode = PinMode.fromWire(spec['mode']);
    if (pin is! int || pin < 0 || pin > 39) {
      issues.add(ValidationIssue('$path.pin', 'must be a GPIO number 0 to 39'));
    }
    if (mode == null) {
      issues.add(
        ValidationIssue(
          '$path.mode',
          'must be one of ${PinMode.values.map((m) => m.wireName).join(', ')}',
        ),
      );
    }
    if (pin is! int || pin < 0 || pin > 39 || mode == null) continue;
    final clash = used[pin];
    if (clash != null) {
      issues.add(ValidationIssue('$path.pin', 'pin $pin is already "$clash"'));
      continue;
    }
    used[pin] = name;

    int? watchMs;
    var watchDelta = 0;
    final watch = spec['watch'];
    if (mode.isInput && watch != false) {
      watchMs = mode == PinMode.adc ? 1000 : 50;
      watchDelta = mode == PinMode.adc ? 2 : 0;
      if (watch is Map) {
        final ms = watch['ms'];
        final delta = watch['delta'];
        if (ms != null && (ms is! int || ms < 10 || ms > 60000)) {
          issues.add(ValidationIssue('$path.watch.ms', 'must be 10 to 60000'));
        } else if (ms is int) {
          watchMs = ms;
        }
        if (delta != null && (delta is! int || delta < 0 || delta > 100)) {
          issues.add(ValidationIssue('$path.watch.delta', 'must be 0 to 100'));
        } else if (delta is int) {
          watchDelta = delta;
        }
      } else if (watch != null && watch != true) {
        issues.add(
          ValidationIssue('$path.watch', 'must be false or {"ms", "delta"}'),
        );
      }
    } else if (!mode.isInput && watch != null) {
      issues.add(ValidationIssue('$path.watch', 'only inputs can be watched'));
    }
    final invert = spec['invert'];
    if (invert != null &&
        (invert is! bool || !(mode.isDigitalInput || mode == PinMode.output))) {
      issues.add(
        ValidationIssue(
          '$path.invert',
          'is true or false, for digital inputs and outputs',
        ),
      );
    }
    pins.add(
      BoardPin(
        name: name,
        pin: pin,
        mode: mode,
        watchMs: watchMs,
        watchDelta: watchDelta,
        invert: invert is bool ? invert : mode == PinMode.inputPullup,
      ),
    );
  }
  if (issues.isNotEmpty) throw ValidationException('pins', issues);
  return pins;
}

bool isBoardDriver(DriverManifest? manifest) =>
    manifest?.transport.type == TransportType.omniflow;

/// The pins of a board device, or none for any other device.
List<BoardPin> boardPinsOf(Device device, DriverManifest manifest) =>
    isBoardDriver(manifest)
    ? parseBoardPins(
        device.settings['pins'],
        reserved: {for (final c in manifest.capabilities) c.id},
      )
    : const [];

/// The event a board raises when its NFC reader sees a tag, `{uid}`.
const boardNfcEvent = 'nfc.scanned';

/// The peripheral types firmware 3 knows: `periph.set` takes these.
const boardPeriphTypes = ['ir', 'rf', 'nfc_rc522', 'nfc_pn532'];

bool _isNfcReader(Object? type) => type == 'nfc_rc522' || type == 'nfc_pn532';

/// The board driver's actions that need a transmitter, by peripheral type.
const _periphActions = {'ir_nec': 'ir', 'ir_code': 'ir', 'rf_send': 'rf'};

/// What a board's peripherals let it do, from its describe reply: the types
/// listed under `periph`, in order, then `ir` and `rf` when the describe's
/// `ir` or `rf` flag says the board can send them without one (the native
/// virtual board, or a carrier built into the board). Null for firmware
/// that reports neither.
List<String>? periphTypesOf(Map<String, Object?> describe) {
  final periph = describe['periph'];
  final ir = describe['ir'];
  final rf = describe['rf'];
  if (periph is! List && ir is! bool && rf is! bool) return null;
  final types = [
    if (periph is List)
      for (final p in periph)
        if (p is Map && p['type'] is String) p['type'] as String,
  ];
  if (ir == true && !types.contains('ir')) types.add('ir');
  if (rf == true && !types.contains('rf')) types.add('rf');
  return types;
}

/// The manifest as it applies to [device]: a board device adds one
/// capability per named pin, and the `nfc.scanned` event when the board
/// reported an NFC reader in its `periph` setting. Once the board has
/// reported its peripherals, `ir_nec` and `ir_code` need `ir` among them
/// and `rf_send` needs `rf`, so a flow cannot use a transmitter the board
/// lacks. Null when the driver is unknown.
DriverManifest? manifestFor(DriverRegistry registry, Device device) {
  final base = registry[device.driverId];
  if (base == null || !isBoardDriver(base)) return base;
  final pins = boardPinsOf(device, base);
  final periph = device.settings['periph'];
  bool offered(CapabilitySpec c) => switch (_periphActions[c.id]) {
    null => true,
    final type => (periph as List).contains(type),
  };
  return base.withCapabilities(keep: periph is List ? offered : null, [
    for (final p in pins) p.capability,
    for (final p in pins) ...p.events,
    if (periph is List && periph.any(_isNfcReader))
      const CapabilitySpec(
        id: boardNfcEvent,
        type: CapabilityType.event,
        label: 'NFC tag scanned',
        params: {},
        command: null,
      ),
  ]);
}

Map<int, Set<String>> _offeredCaps(Map<String, Object?> describe) {
  final offered = <int, Set<String>>{};
  final list = describe['pins'];
  if (list is List) {
    for (final p in list) {
      if (p is Map && p['pin'] is int && p['caps'] is List) {
        offered[p['pin'] as int] = {for (final c in p['caps'] as List) '$c'};
      }
    }
  }
  return offered;
}

/// Checks [pins] against a board's describe reply and returns one message per
/// pin the board cannot do, empty when every pin fits.
///
/// A board that lists `pullup` in some pin's caps has internal pull-ups only
/// there (ESP32 GPIO34-39 and ESP8266 GPIO16 have none). Older firmware
/// lists no `pullup` at all, and then any input pin is taken to have one.
/// When describe gives `watches`, the most pins the board can watch, more
/// watched pins than that are refused before anything is sent.
List<String> pinsUnsupportedBy(
  List<BoardPin> pins,
  Map<String, Object?> describe,
) {
  final offered = _offeredCaps(describe);
  final reportsPullup = offered.values.any((c) => c.contains('pullup'));
  final board = describe['board'] ?? 'this board';
  final needed = {
    PinMode.input: 'in',
    PinMode.inputPullup: reportsPullup ? 'pullup' : 'in',
    PinMode.output: 'out',
    PinMode.pwm: 'pwm',
    PinMode.servo: 'servo',
    PinMode.adc: 'adc',
  };
  final watched = pins.where((p) => p.watchMs != null).length;
  final limit = describe['watches'];
  return [
    for (final p in pins)
      if (offered[p.pin] == null)
        '${p.name}: pin ${p.pin} is not available on $board'
      else if (p.mode == PinMode.inputPullup &&
          !offered[p.pin]!.contains(needed[p.mode]) &&
          offered[p.pin]!.contains('in'))
        '${p.name}: pin ${p.pin} on $board has no internal pull-up: add an '
            'external resistor and use mode in'
      else if (!offered[p.pin]!.contains(needed[p.mode]))
        '${p.name}: pin ${p.pin} on $board cannot do ${p.mode.wireName} '
            '(it can do ${(offered[p.pin]!.toList()..sort()).join(', ')})',
    if (limit is int && watched > limit)
      '$watched pins are watched but $board can watch $limit: '
          'set "watch": false on the inputs that do not need it',
  ];
}

/// The GPIOs that set how each board boots. A button or load on one can
/// keep the board from starting or send it into its flash loader.
const strappingPins = {
  'esp8266': {0, 2, 15},
  'esp32': {0, 2, 5, 12, 15},
};

/// One warning per pin in [pins] that is a boot strapping pin on the board
/// [describe] names. These pins still work, so nothing is refused.
List<String> strappingPinWarnings(
  List<BoardPin> pins,
  Map<String, Object?> describe,
) {
  final board = describe['board'];
  final strapping = strappingPins[board] ?? const <int>{};
  return [
    for (final p in pins)
      if (strapping.contains(p.pin))
        '${p.name}: GPIO ${p.pin} is a boot strapping pin on $board. '
            'Wiring that pulls it the wrong way at power on stops the board '
            'from booting, so use another pin if one is free',
  ];
}

/// A describe reply as the engine keeps it: what the board is and can do,
/// without the request id and message type of that one reply.
Map<String, Object?> boardDescribeOf(Map<String, Object?> reply) =>
    {...reply}..removeWhere((k, _) => k == 'id' || k == 'event');

/// The pins a describe reply says have a mode set, for [pinSetupCommands]
/// to release the ones no longer configured. Each pin entry carries `mode`
/// once the firmware reports it.
List<int> pinsSetOnBoard(Map<String, Object?> describe) {
  // The firmware lists them as "set": [{"pin", "mode"}]; a mode on a pins
  // entry is read too.
  final set = describe['set'];
  final list = describe['pins'];
  return [
    if (set is List)
      for (final p in set)
        if (p is Map &&
            p['pin'] is int &&
            p['mode'] is String &&
            p['mode'] != 'none')
          p['pin'] as int,
    if (set is! List && list is List)
      for (final p in list)
        if (p is Map &&
            p['pin'] is int &&
            p['mode'] is String &&
            p['mode'] != 'none')
          p['pin'] as int,
  ];
}

/// The commands that bring a board's pins to their configured modes, put
/// outputs back to the value the device state remembers, and start watching
/// inputs. Safe to send again at any time: the firmware leaves a pin that
/// already has its mode alone.
///
/// An output's `pin.mode` names the level it starts at, so it comes up off
/// (or as remembered) instead of glitching on. Firmware that ignores that
/// level gets it from the `pin.write` after, which an inverted output always
/// gets, since its pin left at LOW would be on.
///
/// Every mode and write goes out before the first watch, so a board that
/// refuses a watch (too many watched pins) still has every output set up.
/// [current] are the pins the board has set ([pinsSetOnBoard]): any of them
/// no longer configured is released, and a configured input that is not to
/// be watched has its watch stopped.
List<Map<String, Object?>> pinSetupCommands(
  List<BoardPin> pins,
  Map<String, Object?> state, {
  Iterable<int> current = const [],
}) {
  final configured = {for (final p in pins) p.pin};
  return [
    for (final pin in current)
      if (!configured.contains(pin))
        {'cmd': 'pin.mode', 'pin': pin, 'mode': 'none'},
    for (final p in pins) ...[
      {
        'cmd': 'pin.mode',
        'pin': p.pin,
        'mode': p.mode.wireName,
        if (p.mode == PinMode.output)
          'value': p.levelFor(state[p.name] == true),
      },
      if (p.mode == PinMode.output && p.invert)
        {
          'cmd': 'pin.write',
          'pin': p.pin,
          'value': p.levelFor(state[p.name] == true),
        }
      else if (p.mode == PinMode.output && state[p.name] is bool)
        {'cmd': 'pin.write', 'pin': p.pin, 'value': state[p.name]},
      if (p.mode == PinMode.pwm && state[p.name] is num)
        {'cmd': 'pwm.write', 'pin': p.pin, 'value': state[p.name]},
      if (p.mode == PinMode.servo && state[p.name] is num)
        {'cmd': 'servo.write', 'pin': p.pin, 'value': state[p.name]},
    ],
    for (final p in pins)
      if (p.watchMs != null)
        {
          'cmd': 'pin.watch',
          'pin': p.pin,
          'ms': p.watchMs,
          'delta': p.watchDelta,
        }
      else if (p.mode.isInput)
        {'cmd': 'pin.watch', 'pin': p.pin, 'off': true},
  ];
}

/// True when [host] names a serial port rather than a network address.
bool isSerialHost(String host) =>
    host.startsWith('/dev/') || RegExp(r'^COM\d+$').hasMatch(host);

/// The OmniFlow board protocol over whichever link the device has: its
/// serial port when the host is a port path, Wi-Fi UDP otherwise.
class BoardChannel implements DriverChannel {
  BoardChannel({required this.udp, required this.serial});

  final DriverChannel udp;
  final DriverChannel serial;

  @override
  Future<ChannelReply> send(ChannelRequest request) =>
      (isSerialHost(request.device.host) ? serial : udp).send(request);
}
