import 'dart:async';
import 'dart:convert';

import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import 'tv_commands.dart';
import '../devices/adb/adb_commands.dart' show shellQuote;
import '../devices/adb/adb_connection.dart';
import '../devices/adb/tv_parsers.dart';
import '../devices/board.dart' show manifestFor;
import '../devices/device.dart';
import '../manifest/driver_manifest.dart';

/// OmniFlow's own pointer helper for Android TV, built from `tv_helper/`.
const tvHelperPackage = 'com.jashnm.omniflow.tvhelper';

/// The helper's service, which `am start-foreground-service` starts.
const tvHelperService = '$tvHelperPackage/.PointerService';

/// The abstract Unix socket the helper listens on. It takes connections
/// only from the ADB shell, so only `localabstract:` over ADB reaches it.
const tvPointerSocket = 'omniflow_pointer';

const _openTimeout = Duration(seconds: 3);
const _writeTimeout = Duration(seconds: 3);
const _startWait = Duration(seconds: 4);
const _startPoll = Duration(milliseconds: 250);

/// A pointer stream nothing is sent on is closed after this, so the ADB
/// connection it rides on is not left looking busy.
const _idleClose = Duration(seconds: 15);

/// The `tv.helper.*` and `tv.pointer*` commands: install and start the
/// pointer helper on a TV, then move its pointer live and click where it
/// is. The engine keeps where the pointer is for each TV, so a click taps
/// there and every move sends the pointer's whole position.
class TvPointerCommands {
  TvPointerCommands(this._core, this._tv);

  final EngineCore _core;
  final TvCommands _tv;
  final _links = <String, _PointerLink>{};
  final _positions = <String, (double, double)>{};
  final _queues = <String, Future<void>>{};

  Map<String, CommandHandler> get commands => {
    'tv.helper.status': status,
    'tv.helper.install': install,
    'tv.pointer': pointer,
    'tv.pointer.click': click,
  };

  Future<({Device device, DriverManifest manifest, bool offerKey})> _device(
    Map<String, Object?> args,
  ) async {
    final device = await _core.device(stringArg(args, 'id'));
    final manifest = manifestFor(_core.registry, device);
    if (manifest == null || manifest.transport.type != TransportType.adb) {
      throw ApiError('invalid', '${device.id} is not an Android TV over ADB');
    }
    return (
      device: device,
      manifest: manifest,
      offerKey: args['allowPairing'] != false,
    );
  }

  Future<String> _run(
    ({Device device, DriverManifest manifest, bool offerKey}) tv,
    String command,
  ) => _core.adb.run(tv.device, tv.manifest, command, offerKey: tv.offerKey);

  // Status and install -------------------------------------------------

  Future<Map<String, Object?>> status(Map<String, Object?> args) async {
    final tv = await _device(args);
    return {'id': tv.device.id, ...await _status(tv)};
  }

  Future<Map<String, Object?>> _status(
    ({Device device, DriverManifest manifest, bool offerKey}) tv,
  ) async {
    final package = shellQuote(tvHelperPackage);
    final sections = splitTvSections(
      await _run(
        tv,
        tvSections({
          'path': 'pm path $package',
          'ops': 'appops get $package SYSTEM_ALERT_WINDOW',
          'socket': 'grep -c ${shellQuote('@$tvPointerSocket')} /proc/net/unix',
        }),
      ),
    );
    final installed = (sections['path'] ?? '').contains('package:');
    final mode = RegExp(r'SYSTEM_ALERT_WINDOW: (\w+)')
        .firstMatch(sections['ops'] ?? '')
        ?.group(1);
    final sockets = int.tryParse((sections['socket'] ?? '').trim()) ?? 0;
    return {
      'package': tvHelperPackage,
      'installed': installed,
      'overlayAllowed': installed && mode == 'allow',
      'running': installed && sockets > 0,
    };
  }

  /// Installs the helper APK at `path` (the app's bundled copy) through
  /// `tv.install`, lets it draw over other apps and starts it.
  Future<Map<String, Object?>> install(Map<String, Object?> args) async {
    final tv = await _device(args);
    final id = tv.device.id;
    final installed = await _tv.install({
      'id': id,
      'path': args['path'],
      'replace': true,
      'allowPairing': tv.offerKey,
    });
    var now = await _status(tv);
    if (now['installed'] != true) {
      throw ApiError(
        'invalid',
        '${installed['installed']} is not the OmniFlow pointer helper',
      );
    }
    final package = shellQuote(tvHelperPackage);
    final granted = await _run(
      tv,
      'appops set $package SYSTEM_ALERT_WINDOW allow',
    );
    if (granted.trim().isNotEmpty) {
      throw ApiError(
        'device_error',
        '$id did not let the helper draw over other apps: ${granted.trim()}',
      );
    }
    _drop(id);
    final started = await _run(
      tv,
      'am start-foreground-service -n ${shellQuote(tvHelperService)}',
    );
    if (started.contains('Error') || started.contains('Exception')) {
      throw ApiError(
        'device_error',
        '$id did not start the helper: ${started.trim()}',
      );
    }
    final deadline = DateTime.now().add(_startWait);
    while (true) {
      now = await _status(tv);
      if (now['running'] == true || DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(_startPoll);
    }
    if (now['running'] != true) {
      throw ApiError(
        'device_error',
        'the helper is installed on $id but did not start listening',
      );
    }
    return {'id': id, 'bytes': installed['bytes'], ...now};
  }

  // Pointer --------------------------------------------------------------

  /// Moves the pointer: exactly one of `show`, `hide`, `to: [x, y]` (each
  /// a fraction of the screen) or `by: [dx, dy]` (fractions, -1 to 1).
  Future<Map<String, Object?>> pointer(Map<String, Object?> args) async {
    final tv = await _device(args);
    final id = tv.device.id;
    final given = [
      for (final k in const ['show', 'hide', 'to', 'by'])
        if (args[k] != null && args[k] != false) k,
    ];
    if (given.length != 1) {
      throw ApiError('invalid', 'give one of show, hide, to or by');
    }
    var (x, y) = _positions[id] ?? (0.5, 0.5);
    switch (given.single) {
      case 'show' || 'hide':
        if (args[given.single] != true) {
          throw ApiError('invalid', '${given.single} is true');
        }
      case 'to':
        (x, y) = _pair(args, 'to', low: 0, high: 1);
      case 'by':
        final (dx, dy) = _pair(args, 'by', low: -1, high: 1);
        x = (x + dx).clamp(0.0, 1.0);
        y = (y + dy).clamp(0.0, 1.0);
    }
    final hide = given.single == 'hide';
    // The whole position goes each time, so a helper that restarted puts
    // the pointer where a click will land.
    final line = hide
        ? {'hide': true}
        : {
            'to': [x, y],
          };
    await _queued(id, () => _send(tv, '${jsonEncode(line)}\n'));
    _positions[id] = (x, y);
    return {'id': id, 'x': x, 'y': y, 'shown': !hide};
  }

  /// Taps where the pointer is, with `tv.input.tap`.
  Future<Map<String, Object?>> click(Map<String, Object?> args) async {
    final tv = await _device(args);
    final (x, y) = _positions[tv.device.id] ?? (0.5, 0.5);
    final tapped = await _tv.tap({
      'id': tv.device.id,
      'x': x,
      'y': y,
      'allowPairing': tv.offerKey,
    });
    return {
      'id': tv.device.id,
      'x': x,
      'y': y,
      'px': tapped['x'],
      'py': tapped['y'],
    };
  }

  static (double, double) _pair(
    Map<String, Object?> args,
    String key, {
    required double low,
    required double high,
  }) {
    final value = args[key];
    if (value is List && value.length == 2) {
      final [a, b] = value;
      if (a is num && b is num && a.isFinite && b.isFinite) {
        if (a >= low && a <= high && b >= low && b <= high) {
          return (a.toDouble(), b.toDouble());
        }
      }
    }
    throw ApiError(
      'invalid',
      '$key is two numbers from ${_plain(low)} to ${_plain(high)}',
    );
  }

  static String _plain(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : '$v';

  /// Runs [op] after the ones already sent to [id], so moves arrive in
  /// order.
  Future<void> _queued(String id, Future<void> Function() op) {
    final next = (_queues[id] ?? Future<void>.value()).then((_) => op());
    final settled = next.then<void>((_) {}, onError: (Object _) {});
    _queues[id] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_queues[id], settled)) _queues.remove(id);
      }),
    );
    return next;
  }

  Future<void> _send(
    ({Device device, DriverManifest manifest, bool offerKey}) tv,
    String line,
  ) async {
    final bytes = utf8.encode(line);
    for (var attempt = 0; ; attempt++) {
      final link = await _link(tv);
      try {
        await link.stream.write(bytes, timeout: _writeTimeout);
        link.touch(() => _drop(tv.device.id, only: link));
        return;
      } on Object catch (e) {
        _drop(tv.device.id, only: link);
        if (e is ApiError) rethrow;
        if (attempt > 0) {
          throw ApiError(
            'device_error',
            '${tv.device.id} did not take the pointer move',
          );
        }
      }
    }
  }

  /// The open stream to the helper on [tv], opened again when it or its
  /// ADB connection ended.
  Future<_PointerLink> _link(
    ({Device device, DriverManifest manifest, bool offerKey}) tv,
  ) async {
    final id = tv.device.id;
    final held = _links[id];
    if (held != null &&
        !held.stream.isDone &&
        identical(held.connection, _core.adb.connectionOf(id))) {
      return held;
    }
    _drop(id);
    var connection = _core.adb.connectionOf(id);
    if (connection == null) {
      // Any command opens the connection, with pairing and errors as
      // every other TV command has them.
      await _run(tv, 'true');
      connection = _core.adb.connectionOf(id);
    }
    if (connection is! AdbConnection) {
      throw ApiError('device_error', '$id has no ADB connection');
    }
    final AdbStream stream;
    try {
      stream = await connection.openStream(
        'localabstract:$tvPointerSocket',
        timeout: _openTimeout,
      );
    } on AdbStreamRefusedException {
      throw ApiError(
        'not_ready',
        'the pointer helper is not running on $id. Install it from the '
            'Mouse tab, or with tv.helper.install',
      );
    } on AdbConnectionClosedException {
      throw ApiError('device_error', '$id closed the ADB connection');
    } on AdbShellTimeoutException {
      throw ApiError('timeout', 'no reply from $id to the pointer stream');
    }
    return _links[id] = _PointerLink(connection, stream);
  }

  void _drop(String id, {_PointerLink? only}) {
    final link = _links[id];
    if (link == null || (only != null && !identical(link, only))) return;
    _links.remove(id)?.close();
  }
}

class _PointerLink {
  _PointerLink(this.connection, this.stream);

  final AdbConnection connection;
  final AdbStream stream;
  Timer? _idle;

  void touch(void Function() onIdle) {
    _idle?.cancel();
    _idle = Timer(_idleClose, onIdle);
  }

  void close() {
    _idle?.cancel();
    stream.close();
  }
}
