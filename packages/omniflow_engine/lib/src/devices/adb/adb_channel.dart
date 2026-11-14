import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// Finds the TLS connect port a Wireless Debugging device with [guid]
/// announces now, or null.
typedef AdbTlsLocator = Future<({String host, int port})?> Function(
  String guid,
);

/// Records that [deviceId] answers at [host]:[port] now.
typedef AdbMovedCallback = Future<void> Function(
  String deviceId,
  String host,
  int port,
);

/// The guid a Wireless Debugging device announces as its
/// `_adb-tls-connect._tcp` instance, `adb-<serial>-<six letters>`, which
/// android.pair stores as the device's stable id. A TV's `_adb._tcp` id,
/// `adb-<serial>`, has no suffix.
final adbTlsGuidPattern = RegExp(r'^adb-[A-Za-z0-9]+-[A-Za-z0-9]{6}$');

/// How often a Wireless Debugging device that stopped answering is looked
/// for on mDNS, so one that is off is not searched for on every command.
const _followEvery = Duration(minutes: 1);

/// The TV has not accepted this engine's ADB key. The message says what to
/// do on the TV.
class AdbPairingException extends CommandFailedException {
  AdbPairingException(super.message);
}

/// Android TVs, Fire TV and phones over ADB: legacy TCP 5555 with RSA auth,
/// or a Wireless Debugging connect port, which switches to TLS 1.3 when
/// the device answers STLS.
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
    this._wakeWait = const Duration(seconds: 45),
    this._wakeRetry = const Duration(seconds: 3),
    this._generateKey = AdbHostKey.generate,
    this._onPairingPrompt,
    this._locateTls,
    this._onMoved,
  }) : _keyName = keyName ?? 'omniflow@${_safeHostName()}';

  final SecretStore _secrets;
  final TemplateRenderer _renderer;
  final String _keyName;
  final Duration _connectTimeout;
  final Duration _pairingTimeout;
  final WakeOnLanSender _wakeOnLan;

  /// How long a TV woken by Wake-on-LAN gets to bring ADB back, and how
  /// often it is tried in that time.
  final Duration _wakeWait;
  final Duration _wakeRetry;
  final Future<AdbHostKey> Function() _generateKey;

  /// Runs with the device id when its TV is showing "Allow USB debugging?".
  final void Function(String deviceId)? _onPairingPrompt;

  /// Follows a Wireless Debugging device to the port it picked when it was
  /// turned on again, by the guid in its stable id.
  final AdbTlsLocator? _locateTls;
  final AdbMovedCallback? _onMoved;
  final _lastFollow = <String, DateTime>{};

  /// The engine's ADB key, read or made on first use. Pairing presents the
  /// same key the connections use.
  Future<AdbHostKey> hostKey() => _hostKey();

  /// The name the device lists this engine's key under.
  String get keyName => _keyName;

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
    final rendered = _renderer.render(request.command, request.context);
    final action = AdbAction.parse(rendered);
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
        Future<String> run() => _shell(
          device,
          port,
          action.command,
          timeout,
          offerKey: request.allowPairing,
        );
        final output = _isWake(rendered)
            ? await _wake(device, run)
            : await run();
        final failure = action.failureIn(output);
        if (failure != null) throw CommandFailedException(failure);
        return ChannelReply({
          'shell': action.command,
          'output': output,
        }, raw: output);
    }
  }

  static bool _isWake(Object? rendered) =>
      rendered is Map && rendered['op'] == 'key' && rendered['key'] == 'wakeup';

  /// Runs the wake key. A TV in deep standby has its network off and does
  /// not answer, so a TV with a `mac` setting gets a Wake-on-LAN packet and
  /// then the key again until ADB is back or [_wakeWait] runs out.
  Future<String> _wake(Device device, Future<String> Function() run) async {
    try {
      return await run();
    } on Exception catch (e) {
      // Unreachable, or a held connection the TV dropped when it went into
      // deep standby without closing it (no reply). A TV that refuses the
      // key is not asleep.
      final asleep =
          e is TransportTimeoutException ||
          (e is CommandFailedException &&
              e is! PairingRequiredException &&
              e is! AdbPairingException);
      final mac = device.settings['mac'];
      if (!asleep || mac is! String || !macPattern.hasMatch(mac)) rethrow;
      await _wakeOnLan(wakeOnLanPacketFor(mac));
    }
    final deadline = DateTime.now().add(_wakeWait);
    while (true) {
      await Future<void>.delayed(_wakeRetry);
      try {
        return await run();
      } on Exception catch (e) {
        if (e is PairingRequiredException || e is AdbPairingException) rethrow;
        if (e is! TransportTimeoutException && e is! CommandFailedException) {
          rethrow;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TransportTimeoutException(
            '${device.id} did not answer within ${_wakeWait.inSeconds} s of '
            'Wake-on-LAN. Turn on network standby (wake on Wi-Fi) in the TV '
            'power settings',
          );
        }
      }
    }
  }

  /// Runs [command] on [device] as built by the caller, and returns what it
  /// printed. Only commands built from validated values come here.
  ///
  /// With [wake], a TV that does not answer gets Wake-on-LAN first, as the
  /// driver's wake capability does.
  Future<String> run(
    Device device,
    DriverManifest manifest,
    String command, {
    Duration? timeout,
    bool offerKey = false,
    bool wake = false,
  }) {
    Future<String> once() => _shell(
      device,
      _portOf(device, manifest),
      command,
      timeout ?? Duration(milliseconds: manifest.reliability.timeoutMs),
      offerKey: offerKey,
    );
    return wake ? _wake(device, once) : once();
  }

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

  /// Runs [command] on the `exec:` service and returns its output byte for
  /// byte. Unlike `shell:`, exec has no terminal, so binary output such as
  /// a PNG arrives without line endings rewritten.
  Future<Uint8List> exec(
    Device device,
    DriverManifest manifest,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    bool offerKey = false,
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    final port = _portOf(device, manifest);
    final handshake = Duration(milliseconds: manifest.reliability.timeoutMs);
    for (var attempt = 0; ; attempt++) {
      final reused = _isHeld(device, port);
      AdbStream? stream;
      try {
        final connection = await _connection(
          device,
          port,
          handshake,
          offerKey: offerKey,
        );
        stream = await connection.openStream(
          'exec:$command',
          timeout: handshake,
        );
        final out = BytesBuilder(copy: false);
        final deadline = DateTime.now().add(timeout);
        while (true) {
          final left = deadline.difference(DateTime.now());
          if (left <= Duration.zero) throw TimeoutException(null);
          final chunk = await stream.readChunk(timeout: left);
          if (chunk == null) break;
          out.add(chunk);
          if (out.length > maxBytes) {
            stream.close();
            throw CommandFailedException(
              '${device.id} sent more than ${maxBytes ~/ (1024 * 1024)} MB',
            );
          }
        }
        final error = stream.error;
        if (error is AdbConnectionClosedException) throw error;
        return out.takeBytes();
      } on AdbConnectionClosedException catch (e) {
        _drop(device.id);
        if (attempt == 0 && reused && !e.acknowledged && stream == null) {
          continue;
        }
        throw CommandFailedException('${device.id} closed the ADB connection');
      } on AdbShellTimeoutException {
        _drop(device.id);
        throw CommandFailedException(
          'no reply from ${device.id} to the ADB exec request',
        );
      } on TimeoutException {
        stream?.close();
        throw CommandFailedException(
          '${device.id} did not finish in ${timeout.inSeconds} s',
        );
      } on AdbStreamRefusedException {
        throw CommandFailedException(
          '${device.id} refused the ADB exec service',
        );
      }
    }
  }

  /// The connection held for [deviceId] now, as an opaque key: what was
  /// learned on one connection is learned again on the next.
  Object? connectionOf(String deviceId) {
    final connection = _connections[deviceId]?.connection;
    return connection == null || connection.isClosed ? null : connection;
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
      } on AdbShellTimeoutException catch (e) {
        // One slow command is not a dead connection: the TV answered its
        // open, or a transfer is still moving on it. Only a connection
        // nothing answers on is dropped, so the next command reconnects.
        final held = _connections[device.id]?.connection;
        if (!e.acknowledged && !(held?.busy ?? false)) _drop(device.id);
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
    entry
      ..host = connection.host
      ..port = connection.port;
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
    try {
      return await _openAt(device, device.host, port, timeout, offerKey);
    } on TransportTimeoutException {
      final moved = await _follow(device, port);
      if (moved == null) rethrow;
      return _openAt(device, moved.host, moved.port, timeout, offerKey);
    }
  }

  /// Where a Wireless Debugging device that stopped answering at [port]
  /// announces its connect port now, recorded through [_onMoved], or null.
  Future<({String host, int port})?> _follow(Device device, int port) async {
    final locate = _locateTls;
    final guid = device.stableId;
    if (locate == null || guid == null || !adbTlsGuidPattern.hasMatch(guid)) {
      return null;
    }
    final now = DateTime.now();
    final last = _lastFollow[device.id];
    if (last != null && now.difference(last) < _followEvery) return null;
    _lastFollow[device.id] = now;
    final found = await locate(guid);
    if (found == null || (found.host == device.host && found.port == port)) {
      return null;
    }
    await _onMoved?.call(device.id, found.host, found.port);
    return found;
  }

  Future<AdbConnection> _openAt(
    Device device,
    String host,
    int port,
    Duration timeout,
    bool offerKey,
  ) async {
    final key = await _hostKey();
    AdbConnection? opened;
    try {
      return await AdbConnection.connect(
        host,
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
    } on AdbTlsRefusedException {
      throw AdbPairingException(
        '${device.id} did not accept this engine\'s key over wireless '
        'debugging. On the phone open Developer options, Wireless debugging, '
        'Pair device with pairing code, then pair with android.pair',
      );
    } on AdbKeyNotAllowedException {
      throw PairingRequiredException(device.id, name: device.name);
    } on SocketException catch (e) {
      throw TransportTimeoutException(
        'cannot reach ${device.id} at $host:$port (${e.message}). '
        'Turn on network or ADB debugging in the TV developer options',
      );
    } on AdbHandshakeTimeoutException {
      throw TransportTimeoutException(
        'no ADB handshake from ${device.id} at $host:$port',
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

  String host;
  int port;
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
