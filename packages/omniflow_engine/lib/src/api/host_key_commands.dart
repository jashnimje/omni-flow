import 'api_error.dart';
import 'command_args.dart';
import 'engine_core.dart';
import '../devices/device.dart';
import '../manifest/driver_manifest.dart';
import '../transports/ssh_executor.dart';
import '../transports/udp_transport.dart';

/// Reads the host key a host offers now, as `<type> <fingerprint>`.
typedef HostKeyProbe = Future<String> Function(String host, int port);

/// A changed host key as the core API reports it.
ApiError hostKeyError(HostKeyMismatchException e) => ApiError(
  'host_key',
  'the SSH host key of ${e.host} changed: it offers ${e.offered} but '
      '${e.pinned} is pinned. If the host was reinstalled, check the new key '
      'with device.hostkey and accept it',
);

/// `device.hostkey`: show, accept or clear the SSH host key pinned for a
/// device that runs commands over SSH.
class HostKeyCommands {
  HostKeyCommands(this._core, {HostKeyProbe? probe})
    : _probe = probe ?? probeSshHostKey;

  final EngineCore _core;
  final HostKeyProbe _probe;

  /// `{id, action: show | accept | clear, fingerprint}`. `show` (the
  /// default) returns the pinned key and the key the host offers now.
  /// `accept` pins the key the host offers now, and only when it is the
  /// `fingerprint` the user reviewed, so a key that changed between the two
  /// is refused with `conflict`. `clear` removes the pin, and the next
  /// connection pins whatever key it meets.
  Future<Map<String, Object?>> hostKey(Map<String, Object?> args) async {
    final id = stringArg(args, 'id');
    final action = optStringArg(args, 'action') ?? 'show';
    final device = await _core.device(id);
    final (host, port) = _sshAddress(device);
    final pins = HostKeyPins(_core.secrets);
    final pinned = await pins.pinned(host, port);
    final where = {'id': id, 'host': host, 'port': port};
    switch (action) {
      case 'show':
        String? offered;
        String? error;
        try {
          offered = await _probe(host, port);
        } on TransportTimeoutException catch (e) {
          error = e.message;
        }
        return {
          ...where,
          'pinned': pinned,
          'offered': offered,
          if (pinned != null && offered != null) 'matches': pinned == offered,
          'error': ?error,
        };
      case 'accept':
        final fingerprint = stringArg(args, 'fingerprint');
        final offered = await _probe(host, port);
        if (!_sameKey(fingerprint, offered)) {
          throw ApiError(
            'conflict',
            '$host:$port now offers $offered, not $fingerprint. Check it again',
          );
        }
        await pins.pin(host, port, offered);
        return {...where, 'pinned': offered, 'previous': pinned};
      case 'clear':
        await pins.clear(host, port);
        return {...where, 'pinned': null, 'cleared': pinned != null};
      default:
        throw ApiError('invalid', 'action is show, accept or clear');
    }
  }

  (String, int) _sshAddress(Device device) {
    final manifest = _core.registry[device.driverId];
    if (manifest?.transport.type != TransportType.exec ||
        device.host == 'local') {
      throw ApiError('invalid', '${device.id} does not run commands over SSH');
    }
    return (device.host, device.port ?? 22);
  }

  /// The user may give the whole `<type> <fingerprint>` or just the
  /// fingerprint, as `ssh-keygen -l` prints it.
  static bool _sameKey(String given, String offered) {
    final trimmed = given.trim();
    return trimmed == offered || trimmed == offered.split(' ').last;
  }
}
