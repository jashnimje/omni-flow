import 'dart:async';
import 'dart:io';

import '../../manifest/driver_manifest.dart';
import '../../storage/secret_store.dart';
import '../../template/template_renderer.dart';
import '../../transports/packet_tap.dart';
import '../../transports/udp_transport.dart';
import '../channels.dart';
import '../device.dart';
import 'tizen_protocol.dart';
import 'tv_protocol.dart';
import 'tv_socket.dart';
import 'webos_protocol.dart';

/// The device secret setting that holds a TV's pinned certificate.
const tvCertificateSecret = 'certSha256';

/// TVs over WebSocket. The transport option `protocol` picks the family:
/// `webos` (LG SSAP) or `tizen` (Samsung remote control).
///
/// A connection is opened, paired and kept per device. The pairing key the
/// TV issues, and for `wss` the certificate fingerprint seen on first use,
/// are stored as the device's secrets and reused on every later connect. A
/// TV that refuses pairing is not asked again for [pairingCooldown] unless a
/// key is stored or [forget] is called, so a state poll does not raise a
/// prompt on the TV every interval.
class TvWebSocketChannel implements DriverChannel {
  TvWebSocketChannel(
    this._secrets, {
    this._tap,
    this._renderer = const TemplateRenderer(),
    Map<String, TvProtocol>? protocols,
    this.pairingCooldown = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _protocols =
           protocols ??
           const {'webos': WebOsProtocol(), 'tizen': TizenProtocol()},
       _clock = clock ?? DateTime.now;

  final SecretStore _secrets;
  final PacketTap? _tap;
  final TemplateRenderer _renderer;
  final Map<String, TvProtocol> _protocols;
  final Duration pairingCooldown;
  final DateTime Function() _clock;
  final _connections = <String, TvConnection>{};
  final _refusedAt = <String, DateTime>{};

  /// Devices whose TV showed its prompt for the stored key on an unattended
  /// command. Cleared by [forget] and by the next successful pairing.
  final _staleKeys = <String>{};

  /// Sockets still connecting or pairing, so [close] can cut them off.
  final _opening = <TvSocket>{};
  var _closed = false;

  static const _defaultPairingTimeout = Duration(seconds: 60);

  TvProtocol _protocolFor(TransportSpec transport) =>
      _protocols[transport.options['protocol']] ??
      (throw ArgumentError(
        'transport protocol must be one of ${_protocols.keys.join(', ')}',
      ));

  /// Connects to [device] and pairs it when no key is stored, so the TV
  /// shows its prompt now. A refusal cooldown is cleared first, because the
  /// user asked for this. Returns whether the TV issued a new key.
  Future<bool> pair(Device device, DriverManifest manifest) async {
    final protocol = _protocolFor(manifest.transport);
    final keyName = deviceSecretKey(device.id, protocol.pairingSecret);
    final before = await _secrets.read(keyName);
    forget(device.id);
    await _connection(
      ChannelRequest(
        device: device,
        manifest: manifest,
        command: null,
        context: TemplateContext(device: device.settings),
      ),
      protocol,
      Duration(milliseconds: manifest.reliability.timeoutMs),
    );
    final after = await _secrets.read(keyName);
    return after != null && after != before;
  }

  @override
  Future<ChannelReply> send(ChannelRequest request) async {
    final device = request.device;
    final protocol = _protocolFor(request.manifest.transport);
    final command = protocol.parse(
      _renderer.render(request.command, request.context),
    );
    final reliability = request.manifest.reliability;
    final timeout = Duration(milliseconds: reliability.timeoutMs);
    for (var attempt = 0; attempt <= reliability.retries; attempt++) {
      final connection = await _connection(request, protocol, timeout);
      try {
        return await protocol.deliver(
          connection,
          command,
          deviceId: device.id,
          timeout: timeout,
        );
      } on TimeoutException {
        _drop(device.id);
      } on SocketException {
        _drop(device.id);
      }
    }
    throw TransportTimeoutException('no reply from ${device.id}');
  }

  Future<TvConnection> _connection(
    ChannelRequest request,
    TvProtocol protocol,
    Duration timeout,
  ) async {
    final device = request.device;
    final transport = request.manifest.transport;
    final port = device.port ?? transport.port;
    _checkOpen();
    final existing = _connections[device.id];
    if (existing != null &&
        !existing.socket.isClosed &&
        existing.host == device.host &&
        existing.port == (port ?? existing.port)) {
      return existing;
    }
    _drop(device.id);

    final keyName = deviceSecretKey(device.id, protocol.pairingSecret);
    final key = await _secrets.read(keyName);
    if (!request.allowPairing &&
        (key == null || _staleKeys.contains(device.id))) {
      throw PairingRequiredException(device.id, name: device.name);
    }
    _checkCooldown(device, key);
    final pinName = deviceSecretKey(device.id, tvCertificateSecret);
    final uri = protocol.uri(device.host, port, transport, key);
    final secure = uri.scheme == 'wss';
    final pin = secure
        ? normalizeFingerprint(await _secrets.read(pinName))
        : null;
    final learned = <String>[];
    final socket = await TvSocket.connect(
      deviceId: device.id,
      uri: uri,
      timeout: timeout,
      pinnedSha256: pin,
      tap: _tap,
      redact: () => [?key, ...learned],
    );
    _opening.add(socket);
    try {
      _checkOpen();
      final presented = socket.presentedSha256;
      if (secure && pin == null && presented != null) {
        await _secrets.write(pinName, presented);
      }
      final String? issued;
      try {
        issued = await protocol.pair(
          socket,
          deviceId: device.id,
          transport: transport,
          pairingKey: key,
          allowPairing: request.allowPairing,
          timeout: request.allowPairing ? _pairingTimeout(request) : timeout,
        );
      } on PairingRequiredException {
        // The TV no longer knows the stored key. Unattended commands stop
        // reconnecting, so the prompt does not come back every poll.
        _staleKeys.add(device.id);
        rethrow;
      } on TvPairingException {
        _refusedAt[device.id] = _clock();
        rethrow;
      } on TimeoutException {
        throw TvPairingException(
          'no answer to the pairing prompt on ${device.id}. Accept it on the TV and try again',
        );
      } on SocketException {
        _checkOpen();
        throw TvPairingException(
          '${device.id} closed the connection while pairing',
        );
      }
      _checkOpen();
      if (issued != null) learned.add(issued);
      if (issued != null && issued != key) {
        await _secrets.write(keyName, issued);
      }
      _refusedAt.remove(device.id);
      _staleKeys.remove(device.id);
      _checkOpen();
    } catch (_) {
      socket.close();
      rethrow;
    } finally {
      _opening.remove(socket);
    }
    final raced = _connections[device.id];
    if (raced != null &&
        !raced.socket.isClosed &&
        raced.host == device.host &&
        raced.port == uri.port) {
      socket.close();
      return raced;
    }
    _drop(device.id);
    final connection = TvConnection(socket, device.host, uri.port);
    _connections[device.id] = connection;
    return connection;
  }

  void _checkOpen() {
    if (_closed) {
      throw CommandFailedException('the TV channel is shut down');
    }
  }

  void _checkCooldown(Device device, String? key) {
    final refused = _refusedAt[device.id];
    if (key != null || refused == null) return;
    final since = _clock().difference(refused);
    if (since < pairingCooldown) {
      throw TvPairingException(
        '${device.id} refused pairing ${since.inSeconds}s ago. Try again '
        'after ${pairingCooldown.inSeconds}s, or accept the prompt on the TV',
      );
    }
  }

  Duration _pairingTimeout(ChannelRequest request) {
    final ms = request.manifest.transport.options['pairingTimeoutMs'];
    return ms is int && ms > 0
        ? Duration(milliseconds: ms)
        : _defaultPairingTimeout;
  }

  /// Drops the device's connection and any pairing refusal, so the next
  /// command reconnects with the secrets as they are now. Call it after a
  /// TV secret is set.
  void forget(String deviceId) {
    _drop(deviceId);
    _refusedAt.remove(deviceId);
    _staleKeys.remove(deviceId);
  }

  void _drop(String deviceId) => _connections.remove(deviceId)?.socket.close();

  Future<void> close() async {
    _closed = true;
    for (final c in _connections.values) {
      c.socket.close();
    }
    _connections.clear();
    for (final s in [..._opening]) {
      s.close();
    }
  }
}
