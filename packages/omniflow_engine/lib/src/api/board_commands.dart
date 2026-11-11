import 'dart:io';
import 'dart:typed_data';

import 'api_error.dart';
import 'board_runtime.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../devices/board.dart';
import '../devices/channels.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
import '../devices/flash/esp_rom.dart';
import '../devices/flash/stk500.dart';
import '../devices/serial_channel.dart';
import '../storage/database.dart';
import '../template/template_renderer.dart';
import '../transports/udp_transport.dart';

/// The board commands: describe a board, set its pins and bring it to them,
/// and set up a new board over USB.
class BoardCommands {
  BoardCommands(this._core, this._boards);

  final EngineCore _core;
  final BoardRuntime _boards;

  DeviceService get _devices => _core.devices;

  /// The chips `board.flash` writes, and the file each takes.
  static const flashChips = {
    'esp32':
        'a .bin made for address 0 (arduino-cli --export-binaries '
        'gives the merged one)',
    'esp8266': 'a .bin',
    'uno': 'an Intel .hex',
  };

  /// The serial ports a board can be flashed or set up on: the phone's USB
  /// ports, and a computer's USB serial ports.
  Future<Map<String, Object?>> ports(Map<String, Object?> args) async => {
    'ports': [...await usbSerialPorts(), ...?await _core.serial.links?.ports()],
    'canFlash': _core.serial.links != null,
  };

  /// `{port, chip, file, offset?}`: writes firmware from [file] to the board
  /// on the USB [port], then starts it. Progress goes out as
  /// `board.flashProgress` events. Only ports the platform opens itself
  /// (the phone's USB) can be flashed, since a flash needs DTR and RTS.
  Future<Map<String, Object?>> flash(Map<String, Object?> args) async {
    final port = stringArg(args, 'port');
    final chip = stringArg(args, 'chip');
    if (!flashChips.containsKey(chip)) {
      throw ApiError(
        'invalid',
        'chip must be ${flashChips.keys.join(', ')}. A Pico W is flashed '
            'with its BOOTSEL drive for now',
      );
    }
    final links = _core.serial.links;
    if (links == null || !isLinkPort(port)) {
      throw ApiError(
        'invalid',
        'only a board on this phone\'s USB can be flashed here. On a '
            'computer use arduino-cli',
      );
    }
    final file = File(stringArg(args, 'file'));
    if (!await file.exists()) {
      throw ApiError('not_found', 'no firmware file ${file.path}');
    }
    final Uint8List image;
    try {
      image = chip == 'uno'
          ? parseIntelHex(await file.readAsString())
          : await file.readAsBytes();
    } on FlashException catch (e) {
      throw ApiError('invalid', e.message);
    }
    if (image.isEmpty) throw ApiError('invalid', 'the firmware file is empty');
    await _core.serial.releasePath(port);
    final watch = Stopwatch()..start();
    var last = -1;
    void progress(String stage, double done) {
      final percent = (done * 100).floor();
      if (percent == last && stage == 'Writing') return;
      last = percent;
      _core.emit({
        'event': 'board.flashProgress',
        'port': port,
        'stage': stage,
        'done': done,
      });
    }

    final link = await links.open(port, 115200);
    try {
      String found;
      if (chip == 'uno') {
        await Stk500Flasher(link).flash(image, progress: progress);
        found = 'uno';
      } else {
        found = (await EspRomFlasher(link).flash(
          image,
          offset: optIntArg(args, 'offset') ?? 0,
          progress: progress,
          expect: EspChip.values.byName(chip),
        )).name;
      }
      return {
        'port': port,
        'chip': found,
        'bytes': image.length,
        'ms': watch.elapsedMilliseconds,
      };
    } on FlashException catch (e) {
      throw ApiError('device_error', e.message);
    } finally {
      await link.close();
    }
  }

  Future<Map<String, Object?>> provision(Map<String, Object?> args) async {
    final board = await _boards.provisionBoard(stringArg(args, 'id'));
    return {'board': board, 'warnings': board['warnings']};
  }

  Future<Device> _board(String id) async {
    final device = await _core.device(id);
    if (!isBoardDriver(_core.registry[device.driverId])) {
      throw ApiError('invalid', '$id is not an OmniFlow board');
    }
    return device;
  }

  /// What the board offers, for a GPIO picker: its profile, every pin with
  /// its caps, the pins set now, how many it can watch, and whether it has
  /// IR and RF outputs, and its boot strapping pins (`bootPins`), so a
  /// picker can warn before a save. An offline board gives the last describe this
  /// engine saw, with `live: false` and when it was seen.
  Future<Map<String, Object?>> describe(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final device = await _board(id);
    Map<String, Object?> describe;
    var live = true;
    DateTime? seenAt;
    try {
      describe = await _boards.describeBoard(id);
    } on TransportTimeoutException {
      final remembered = await DriftBoardDescribeStore(_core.db).get(id);
      if (remembered == null) rethrow;
      (describe, seenAt, live) = (
        remembered.describe,
        remembered.seenAt,
        false,
      );
    }
    final manifest = _core.registry[device.driverId]!;
    return {
      'id': id,
      'live': live,
      'seenAt': ?seenAt?.toIso8601String(),
      'describe': describe,
      'warnings': strappingPinWarnings(boardPinsOf(device, manifest), describe),
      'bootPins': bootPinsOf(describe),
    };
  }

  Future<Map<String, Object?>> pins(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final device = await _board(id);
    final manifest = _core.registry[device.driverId];
    final pins = objectArg(args, 'pins');
    final parsed = parseBoardPins(
      pins,
      reserved: {for (final c in manifest!.capabilities) c.id},
    );
    // Checked against the board first, so a pin it cannot do never
    // replaces the pins that work. An offline board is checked when it
    // is next set up.
    Map<String, Object?>? describe;
    try {
      describe = await _boards.describeBoard(id);
    } on TransportTimeoutException {
      describe = null;
    }
    if (describe != null) {
      final problems = pinsUnsupportedBy(parsed, describe);
      if (problems.isNotEmpty) throw ApiError('invalid', problems.join('; '));
    }
    final warnings = strappingPinWarnings(
      parsed,
      describe ??
          (await DriftBoardDescribeStore(_core.db).get(id))?.describe ??
          const {},
    );
    final previous = device.settings;
    await _devices.updateDevice(
      id,
      (d) => d.copyWith(settings: {...d.settings, 'pins': pins}),
    );
    try {
      return {'board': await _boards.provisionBoard(id), 'warnings': warnings};
    } on ApiError {
      await _devices.updateDevice(id, (d) => d.copyWith(settings: previous));
      rethrow;
    } catch (e) {
      return {
        'device': _core.deviceJson(await _core.device(id)),
        'provisionError': '$e',
        'warnings': warnings,
      };
    }
  }

  static final _boardName = RegExp(r'^[a-z][a-z0-9_-]{0,22}$');

  /// Sets up a board on a USB serial port: Wi-Fi, node name and IR pin, all
  /// kept in the board's flash. With Wi-Fi it waits until the board joins
  /// and returns its address. The password goes to the board only.
  Future<Map<String, Object?>> setup(Map<String, Object?> args) async {
    final port = stringArg(args, 'port');
    final name = optStringArg(args, 'name');
    if (name != null && !_boardName.hasMatch(name)) {
      throw ApiError(
        'invalid',
        'name is lower snake case, at most 23 characters, like desk_board',
      );
    }
    return _onPort(port, (send, describe) async {
      if (name != null) {
        await send({'cmd': 'node.set', 'name': name});
        await _renameBoard(port, describe['node'], name);
      }
      if (args['irPin'] is int) {
        await send({'cmd': 'ir.pin', 'pin': args['irPin']});
      }
      var wifi = await send(const {'cmd': 'wifi.status'});
      if (args['ssid'] is String) {
        // A Pico W stops answering serial for up to 15 s while it joins, so a
        // late ack or a silent status poll is waited out until the deadline.
        final timeoutMs = optIntArg(args, 'timeoutMs') ?? 30000;
        final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
        try {
          await send({
            'cmd': 'wifi.set',
            'ssid': args['ssid'],
            'password': args['password'] is String ? args['password'] : '',
          });
        } on TransportTimeoutException {
          // Joining: the status poll below tells whether it worked.
        }
        do {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          try {
            wifi = await send(const {'cmd': 'wifi.status'});
          } on TransportTimeoutException {
            continue;
          }
        } while (wifi['connected'] != true &&
            DateTime.now().isBefore(deadline));
      }
      return {
        'node': wifi['node'] ?? describe['node'],
        'board': describe['board'],
        'fw': describe['fw'],
        'wifi': {
          'configured': wifi['configured'] == true,
          'connected': wifi['connected'] == true,
          'ip': ?wifi['ip'],
        },
      };
    });
  }

  /// Runs [work] with the board on the USB serial [port], after its first
  /// describe, and lets the port go after.
  Future<Map<String, Object?>> _onPort(
    String port,
    Future<Map<String, Object?>> Function(
      Future<Map<String, Object?>> Function(Map<String, Object?>) send,
      Map<String, Object?> describe,
    )
    work,
  ) async {
    final manifest = _core.registry['omniflow_board']!;
    final probe = Device(
      id: '_setup_${port.hashCode.abs()}',
      name: port,
      driverId: manifest.id,
      host: port,
    );
    Future<Map<String, Object?>> send(Map<String, Object?> command) async =>
        (await _core.serial.send(
          ChannelRequest(
            device: probe,
            manifest: manifest,
            command: command,
            context: const TemplateContext(),
          ),
        )).json ??
        const {};
    try {
      // Opening the port resets an Uno or an ESP32, so the first describe
      // can go unanswered while the board boots.
      Map<String, Object?>? describe;
      for (var attempt = 0; describe == null; attempt++) {
        try {
          describe = await send(const {'cmd': 'describe'});
        } on TransportTimeoutException {
          if (attempt == 1) rethrow;
        }
      }
      return await work(send, describe);
    } finally {
      await _core.serial.release(probe.id);
    }
  }

  /// `{id | port, type, pins?, clear?}`: binds a peripheral (an IR or RF
  /// transmitter, an RC522 or PN532 NFC reader) to pins on a board, kept in
  /// its flash, or clears it. The firmware takes this over USB only, so
  /// [id] must be a board on USB, or [port] the USB port of a board on
  /// Wi-Fi. The board's describe is read back, so the board device offers
  /// what the peripheral raises (`nfc.scanned` for a reader).
  Future<Map<String, Object?>> periph(Map<String, Object?> args) async {
    final type = stringArg(args, 'type');
    if (!boardPeriphTypes.contains(type)) {
      throw ApiError('invalid', 'type is ${boardPeriphTypes.join(', ')}');
    }
    final clear = args['clear'] == true;
    final pins = args['pins'] == null
        ? const <String, Object?>{}
        : objectArg(args, 'pins');
    if (clear && pins.isNotEmpty) {
      throw ApiError('invalid', 'clear takes no pins');
    }
    if (pins.values.any((v) => v is! int)) {
      throw ApiError('invalid', 'pins maps a name to a GPIO number');
    }
    final command = clear
        ? {'cmd': 'periph.clear', 'type': type}
        : {'cmd': 'periph.set', 'type': type, 'pins': pins};
    final id = optStringArg(args, 'id');
    final port = optStringArg(args, 'port');
    if ((id == null) == (port == null)) {
      throw ApiError('invalid', 'needs id (a board on USB) or port');
    }
    final Map<String, Object?> describe;
    final List<String> devices;
    if (id != null) {
      final board = await _board(id);
      if (!isSerialHost(board.host)) {
        throw ApiError(
          'invalid',
          'a board takes peripherals over USB only. Plug $id in and pass '
              'its port',
        );
      }
      await _devices.sendCommand(id, command);
      describe = await _boards.describeBoard(id);
      devices = [id];
    } else {
      describe = await _onPort(port!, (send, _) async {
        await send(command);
        return boardDescribeOf(await send(const {'cmd': 'describe'}));
      });
      devices = await _boardsNamed(describe['node']);
      for (final d in devices) {
        await _boards.rememberDescribe(d, describe);
      }
    }
    return {
      'type': type,
      'cleared': clear,
      'node': describe['node'],
      'periph': describe['periph'] ?? const [],
      'periphTypes': describe['periphTypes'] ?? const [],
      'devices': devices,
    };
  }

  Future<List<String>> _boardsNamed(Object? node) async => [
    if (node is String)
      for (final d in await DriftDeviceStore(_core.db).all())
        if (isBoardDriver(_core.registry[d.driverId]) &&
            d.stableId?.toLowerCase() == node.toLowerCase())
          d.id,
  ];

  /// A board device follows its board's new name: the one on this port, or
  /// the one known by the old name, so its events are not dropped.
  Future<void> _renameBoard(String port, Object? oldNode, String name) async {
    for (final d in await DriftDeviceStore(_core.db).all()) {
      if (!isBoardDriver(_core.registry[d.driverId])) continue;
      final onPort = d.host == port;
      final byName =
          oldNode is String &&
          d.stableId?.toLowerCase() == oldNode.toLowerCase();
      if (onPort || byName) {
        await _devices.updateDevice(
          d.id,
          (old) => old.copyWith(stableId: name),
        );
      }
    }
  }
}
