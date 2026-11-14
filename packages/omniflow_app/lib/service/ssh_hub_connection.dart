import 'dart:async';

import 'package:omniflow_engine/omniflow_engine.dart';

import 'hub_connection.dart';
import 'hub_settings.dart';

/// The name this app gives itself in `hub.clients`.
const hubClientName = 'omniflow-app';

/// One connection to the hub over SSH through the engine's hub client:
/// `omni hub attach` on an exec channel, the host key checked against the
/// pin the user matched, the version checked, and a `hello` naming this
/// phone.
HubSession sshHubSession({
  required HubSettings settings,
  required SecretStore secrets,
  required String privateKeySecret,
}) => _SshHubSession(settings, secrets, privateKeySecret);

class _SshHubSession implements HubSession {
  _SshHubSession(this._settings, this._secrets, this._privateKeySecret);

  final HubSettings _settings;
  final SecretStore _secrets;
  final String _privateKeySecret;
  HubConnection? _hub;
  StreamSubscription<Map<String, Object?>>? _sub;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _done = Completer<void>();

  @override
  Future<HubHello> open() async {
    final pem = await _secrets.read(_privateKeySecret);
    if (pem == null) {
      throw const HubConnectException(
        'not_allowed',
        'this phone has no hub key yet',
      );
    }
    final HubConnection hub;
    try {
      hub = _hub = await connectSshHub(
        target: SshHubTarget(_settings.user, _settings.host, _settings.port),
        privateKeyPem: pem,
        secrets: _secrets,
        hello: {'client': hubClientName, 'phone': _settings.phone},
      );
    } on HubLinkException catch (e) {
      throw _plain(e);
    }
    try {
      final events = await hub.events();
      _sub = events.listen((e) {
        if (e['event'] == 'hub.connection' && e['state'] == 'lost') {
          _lose();
        } else {
          _events.add(e);
        }
      }, onDone: _lose);
    } on HubLinkException catch (e) {
      await hub.close();
      throw _plain(e);
    }
    return HubHello(
      hostKey: await HostKeyPins(_secrets)
          .pinned(_settings.host, _settings.port),
      hubVersion: hub.hubVersion,
    );
  }

  static HubConnectException _plain(HubLinkException e) {
    final refused = e.message.contains('refused this key');
    return HubConnectException(
      refused ? 'not_allowed' : e.type,
      e.message,
      hubVersion: e.details['hubVersion'] as String?,
      appVersion: e.details['localVersion'] as String?,
    );
  }

  void _lose() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final hub = _hub;
    if (hub == null || _done.isCompleted) {
      return {
        'ok': false,
        'error': {'type': 'unavailable', 'message': 'not connected'},
      };
    }
    return hub.handle(command, args);
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    _lose();
    await _sub?.cancel();
    _sub = null;
    await _hub?.close();
    _hub = null;
  }
}
