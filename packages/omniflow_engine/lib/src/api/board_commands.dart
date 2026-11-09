import 'api_error.dart';
import 'board_runtime.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../devices/board.dart';
import '../devices/channels.dart';
import '../devices/device.dart';
import '../devices/device_service.dart';
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
  /// IR and RF outputs. An offline board gives the last describe this
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
    } finally {
      await _core.serial.release(probe.id);
    }
  }

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
