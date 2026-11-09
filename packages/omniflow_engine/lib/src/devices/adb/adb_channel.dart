import 'dart:async';
import 'dart:io';

import '../../manifest/driver_manifest.dart';
import '../../manifest/validation.dart';
import '../../storage/secret_store.dart';
import '../../template/template_renderer.dart';
import '../../transports/udp_transport.dart';
import '../channels.dart';
import '../device.dart';
import 'adb_commands.dart';
import 'adb_connection.dart';
import 'adb_key.dart';
import 'adb_sync.dart';
import 'wake_on_lan.dart';

const adbDefaultPort = 5555;

/// The TV has not accepted this engine's ADB key. The message says what to
/// do on the TV.
class AdbPairingException extends CommandFailedException {
  AdbPairingException(super.message);
}

/// Android TV and Fire TV over legacy ADB (TCP 5555, RSA auth, no TLS).
///
/// The command renders to `{"op": ...}` (see [AdbAction]). The channel
/// builds the shell line itself, so the reply is
/// `{"shell": "<line run>", "output": "<what it printed>"}`, or
/// `{"wakeOnLan": "<mac>"}` for the `wake_on_lan` op.
///
/// One connection per device is kept and reused. The private key is read
/// from [SecretStore] under [adbHostKeySecret], and generated on first use.
class AdbChannel implements DriverChannel {
  AdbChannel(
    this._secrets, {
    this._renderer = const TemplateRenderer(),
    String? keyName,
    this._connectTimeout = const Duration(seconds: 3),
    this._pairingTimeout = const Duration(seconds: 60),
    this._wakeOnLan = broadcastWakeOnLan,
    this._generateKey = AdbHostKey.generate,
    this._onPairingPrompt,
  }) : _keyName = keyName ?? 'omniflow@${_safeHostName()}';

  final SecretStore _secrets;
  final TemplateRenderer _renderer;
  final String _keyName;
  final Duration _connectTimeout;
  final Duration _pairingTimeout;
  final WakeOnLanSender _wakeOnLan;
  final Future<AdbHostKey> Function() _generateKey;

  /// Runs with the device id when its TV is showing "Allow USB debugging?".
  final void Function(String deviceId)? _onPairingPrompt;

  Future<AdbHostKey>? _key;
  final _connections = <String, _Held>{};

  /// Connections still in their handshake, so [close] can cut them off.
  final _opening = <AdbConnection>{};
  var _closed = false;

  /// Runs when the TV of a device being paired shows its prompt.
  final _pairing = <String, void Function()>{};

  /// Connects to [device] so its TV asks the user to allow this engine's
  /// key, and waits for the answer. Returns whether the TV showed the
  /// prompt: false when it already trusted the key. [onPrompt] runs when
  /// the prompt shows.
  Future<bool> pair(
    Device device,
    DriverManifest manifest, {
    void Function()? onPrompt,
  }) async {
    final port = device.port ?? manifest.transport.port ?? adbDefaultPort;
    var prompted = false;
    _pairing[device.id] = () {
      prompted = true;
      onPrompt?.call();
    };
    try {
      await _connection(
        device,
        port,
        Duration(milliseconds: manifest.reliability.timeoutMs),
        offerKey: true,
      );
    } finally {
      _pairing.remove(device.id);
    }
    return prompted;
  }

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final device = request.device;
    final action = AdbAction.parse(
      _renderer.render(request.command, request.context),
    );
    switch (action) {
      case AdbWakeOnLan():
        final mac = device.settings['mac'];
        if (mac is! String || !macPattern.hasMatch(mac)) {
          throw ValidationException('adb command', [
            ValidationIssue(
              'device.mac',
              '${device.id} needs a mac setting such as AA:BB:CC:DD:EE:FF',
            ),
          ]);
        }
        await _wakeOnLan(wakeOnLanPacketFor(mac));
        return ChannelReply({'wakeOnLan': mac});
      case AdbShell():
        final timeout = Duration(
          milliseconds: request.manifest.reliability.timeoutMs,
        );
        final port =
            device.port ?? request.manifest.transport.port ?? adbDefaultPort;
        final output = await _shell(
          device,
          port,
          action.command,
          timeout,
          offerKey: request.allowPairing,
        );
        final failure = action.failureIn(output);
        if (failure != null) throw CommandFailedException(failure);
        return ChannelReply({
          'shell': action.command,
          'output': output,
        }, raw: output);
    }
  }

  /// Runs [command] on [device] as built by the caller, and returns what it
  /// printed. Only commands built from validated values come here.
  Future<String> run(
    Device device,
    DriverManifest manifest,
    String command, {
    Duration? timeout,
    bool offerKey = false,
  }) => _shell(
    device,
    _portOf(device, manifest),
    command,
    timeout ?? Duration(milliseconds: manifest.reliability.timeoutMs),
    offerKey: offerKey,
  );

  /// Runs [body] on a sync session to [device], then ends the session. A
  /// session the device never accepted is opened once more on a fresh
  /// connection, as nothing ran on it.
  Future<T> sync<T>(
    Device device,
    DriverManifest manifest,
    Future<T> Function(AdbSync sync) body, {
    bool offerKey = false,
    Duration? timeout,
  }) async {
    final port = _portOf(device, manifest);
    final handshake = Duration(milliseconds: manifest.reliability.timeoutMs);
    for (var attempt = 0; ; attempt++) {
      final reused = _isHeld(device, port);
      final AdbSync session;
      try {
        final connection = await _connection(
          device,
          port,
          handshake,
          offerKey: offerKey,
        );
        session = await AdbSync.open(
          connection,
          timeout: timeout ?? const Duration(seconds: 30),
        );
      } on AdbConnectionClosedException {
        _drop(device.id);
        if (attempt == 0 && reused) continue;
        throw CommandFailedException('${device.id} closed the ADB connection');
      } on AdbShellTimeoutException {
        _drop(device.id);
        throw CommandFailedException(
          'no reply from ${device.id} to the ADB sync request',
        );
      } on AdbStreamRefusedException {
        throw CommandFailedException('${device.id} refused ADB file access');
      }
      try {
        final result = await body(session);
        await session.quit();
        return result;
      } on AdbConnectionClosedException {
        _drop(device.id);
        throw CommandFailedException(
          '${device.id} closed the ADB connection during the transfer',
        );
      } on TimeoutException {
        session.abort();
        _drop(device.id);
        throw CommandFailedException(
          'no reply from ${device.id} during the transfer',
        );
      } catch (_) {
        session.abort();
        rethrow;
      }
    }
  }

  int _portOf(Device device, DriverManifest manifest) =>
      device.port ?? manifest.transport.port ?? adbDefaultPort;

  bool _isHeld(Device device, int port) {
    final held = _connections[device.id];
    return held != null &&
        held.connection != null &&
        !held.connection!.isClosed &&
        held.host == device.host &&
        held.port == port;
  }

  Future<String> _shell(
    Device device,
    int port,
    String command,
    Duration timeout, {
    required bool offerKey,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final held = _connections[device.id]?.connection;
      final reused =
          held != null &&
          !held.isClosed &&
          _connections[device.id]!.host == device.host &&
          _connections[device.id]!.port == port;
      try {
        final connection = await _connection(
          device,
          port,
          timeout,
          offerKey: offerKey,
        );
        return await connection.shell(command, timeout: timeout);
      } on AdbConnectionClosedException catch (e) {
        _drop(device.id);
        // A stream the device never accepted did not run, so one retry on
        // a fresh connection cannot run the command twice.
        if (attempt == 0 && reused && !e.acknowledged) continue;
        throw CommandFailedException('${device.id} closed the ADB connection');
      } on AdbShellTimeoutException {
        _drop(device.id);
        throw CommandFailedException(
          'no reply from ${device.id} to the ADB shell command',
        );
      } on AdbStreamRefusedException {
        throw CommandFailedException('${device.id} refused the ADB shell');
      }
    }
  }

  Future<AdbConnection> _connection(
    Device device,
    int port,
    Duration timeout, {
    required bool offerKey,
  }) async {
    _checkOpen();
    final held = _connections[device.id];
    if (held != null && held.host == device.host && held.port == port) {
      final connection = await held.pending;
      if (!connection.isClosed) return connection;
    }
    _drop(device.id);
    final pending = _open(device, port, timeout, offerKey: offerKey);
    final entry = _connections[device.id] = _Held(device.host, port, pending);
    final AdbConnection connection;
    try {
      connection = await pending;
    } catch (_) {
      if (identical(_connections[device.id], entry)) {
        _connections.remove(device.id);
      }
      rethrow;
    }
    // Dropped while connecting (shut down, or replaced for a new address):
    // nobody else would ever close it.
    if (_closed || !identical(_connections[device.id], entry)) {
      connection.close();
      _checkOpen();
      throw CommandFailedException(
        '${device.id} moved while its ADB connection was opening',
      );
    }
    return entry.connection = connection;
  }

  void _checkOpen() {
    if (_closed) throw CommandFailedException('the ADB channel is shut down');
  }

  Future<AdbConnection> _open(
    Device device,
    int port,
    Duration timeout, {
    required bool offerKey,
  }) async {
    final key = await _hostKey();
    AdbConnection? opened;
    try {
      return await AdbConnection.connect(
        device.host,
        port,
        key: key,
        keyName: _keyName,
        connectTimeout: _connectTimeout,
        handshakeTimeout: timeout,
        pairingTimeout: _pairingTimeout,
        onPrompt: () {
          _pairing[device.id]?.call();
          _onPairingPrompt?.call(device.id);
        },
        onOpened: (c) {
          opened = c;
          _opening.add(c);
          if (_closed) c.close();
        },
        offerKey: offerKey,
      );
    } on AdbKeyNotAllowedException {
      throw PairingRequiredException(device.id);
    } on SocketException catch (e) {
      throw TransportTimeoutException(
        'cannot reach ${device.id} at ${device.host}:$port (${e.message}). '
        'Turn on network or ADB debugging in the TV developer options',
      );
    } on AdbHandshakeTimeoutException {
      throw TransportTimeoutException(
        'no ADB handshake from ${device.id} at ${device.host}:$port',
      );
    } on AdbAuthException catch (e) {
      throw AdbPairingException(
        e.promptShown
            ? '${device.id} did not accept this ADB key. On the TV choose '
                  'Allow on "Allow USB debugging?" and tick "Always allow '
                  'from this computer", then try again'
            : '${device.id} refused ADB: ${e.message}',
      );
    } on AdbConnectionClosedException {
      _checkOpen();
      throw CommandFailedException(
        '${device.id} closed the ADB connection during the handshake',
      );
    } finally {
      _opening.remove(opened);
    }
  }

  Future<AdbHostKey> _hostKey() async {
    final pending = _key ??= loadOrCreateAdbHostKey(
      _secrets,
      generate: _generateKey,
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_key, pending)) _key = null;
      rethrow;
    }
  }

  void _drop(String deviceId) {
    _connections.remove(deviceId)?.connection?.close();
  }

  /// Closes the device's held session, for a device that is removed or
  /// replaced.
  void forget(String deviceId) => _drop(deviceId);

  Future<void> close() async {
    _closed = true;
    for (final held in _connections.values) {
      held.connection?.close();
    }
    _connections.clear();
    for (final c in [..._opening]) {
      c.close();
    }
    _opening.clear();
  }
}

class _Held {
  _Held(this.host, this.port, this.pending);

  final String host;
  final int port;
  final Future<AdbConnection> pending;
  AdbConnection? connection;
}

String _safeHostName() {
  String name;
  try {
    name = Platform.localHostname;
  } on Object {
    name = '';
  }
  final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  return safe.isEmpty ? 'host' : safe;
}
