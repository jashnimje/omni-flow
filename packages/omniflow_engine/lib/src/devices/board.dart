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
    PinMode.input || PinMode.inputPullup => (raw != 0) != invert,
    PinMode.output => raw != 0,
    _ => raw,
  };

  CapabilitySpec get capability => switch (mode) {
    PinMode.output => CapabilitySpec(
      id: name,
      type: CapabilityType.toggle,
      label: name,
      params: CapabilityType.toggle.defaultParams,
      command: {'cmd': 'pin.write', 'pin': pin, 'value': '{{value}}'},
      stateJsonPath: '\$.$name',
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

  Map<String, Object?> toJson() => {
    'pin': pin,
    'mode': mode.wireName,
    if (mode.isInput)
      'watch': watchMs == null ? false : {'ms': watchMs, 'delta': watchDelta},
    if (mode.isDigitalInput && invert != (mode == PinMode.inputPullup))
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
    if (invert != null && (invert is! bool || !mode.isDigitalInput)) {
      issues.add(
        ValidationIssue('$path.invert', 'is true or false, for digital inputs'),
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

/// The manifest as it applies to [device]: a board device adds one
/// capability per named pin. Null when the driver is unknown.
DriverManifest? manifestFor(DriverRegistry registry, Device device) {
  final base = registry[device.driverId];
  if (base == null || !isBoardDriver(base)) return base;
  return base.withCapabilities([
    for (final p in boardPinsOf(device, base)) p.capability,
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
      {'cmd': 'pin.mode', 'pin': p.pin, 'mode': p.mode.wireName},
      if (p.mode == PinMode.output && state[p.name] is bool)
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
