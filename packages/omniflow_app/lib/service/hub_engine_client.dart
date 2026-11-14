import 'dart:async';
import 'dart:convert';

import 'package:omniflow_engine/omniflow_engine.dart';

import '../api/engine_client.dart';
import '../api/engine_client_hub.dart';
import 'hub_connection.dart';
import 'hub_settings.dart';

/// The engine client of a phone in hub mode: every command goes to the Mac
/// mini hub, and nothing opens a database on the phone.
///
/// It keeps the link up on its own, retrying with backoff, and tells the
/// UI how it stands with a [HubLink.event] event. While the hub is not
/// reachable, read commands answer with the last result the hub gave, and
/// every other command answers `unavailable` with the reason. Readings the
/// phone takes meanwhile are dropped, except the latest presence, which is
/// sent again as soon as the hub is back.
class HubEngineClient implements EngineClient {
  HubEngineClient({
    required this.settings,
    required this._connect,
    this.appVersion = omniflowEngineVersion,
    Duration Function(int attempt)? backoff,
    Map<String, Map<String, Object?>>? lastKnown,
    this._remember,
    DateTime Function()? now,
  }) : _backoff = backoff ?? defaultBackoff,
       _lastKnown = {...?lastKnown},
       _now = now ?? DateTime.now;

  final HubSettings settings;
  final String appVersion;
  final HubConnector _connect;
  final Duration Function(int attempt) _backoff;
  final DateTime Function() _now;

  /// Read results by command and args, from the last time the hub answered.
  final Map<String, Map<String, Object?>> _lastKnown;
  final void Function(Map<String, Map<String, Object?>>)? _remember;

  final _events = StreamController<Map<String, Object?>>.broadcast();

  /// The latest presence reading per input, sent again on reconnect.
  final _presence = <String, (String, Map<String, Object?>)>{};

  HubSession? _connection;
  var _phoneKnown = false;
  StreamSubscription<Map<String, Object?>>? _hubEvents;
  Timer? _retry;
  var _attempt = 0;
  var _closed = false;
  Completer<void>? _opening;

  late HubLinkView _view = HubLinkView(
    state: HubLinkState.connecting,
    address: settings.address,
    phone: settings.phone,
    appVersion: appVersion,
  );

  /// 1, 2, 4 ... seconds, at most a minute.
  static Duration defaultBackoff(int attempt) =>
      Duration(seconds: attempt >= 6 ? 60 : 1 << attempt);

  static const unreachableReason =
      'The hub is not reachable, so this cannot run now. OmniFlow keeps '
      'trying to reach it.';

  HubLinkView get view => _view;

  /// The person the hub has for this phone, once connected.
  String? get person => _view.person;

  /// Whether an ask or notification belongs on this phone: it names this
  /// phone's person, or no person at all.
  bool showsOnThisPhone(Map<String, Object?> event) {
    final to = event['person'] ?? event['to'];
    if (to is! String || to.isEmpty) return true;
    return to == person;
  }

  /// Starts connecting. Returns once the first attempt has finished, either
  /// way.
  Future<void> start() => _open();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    switch (command) {
      case HubLink.status:
        return {'ok': true, ..._view.toJson()};
      case HubLink.reconnect:
        if (!_view.connected) unawaited(_open(now: true));
        return {'ok': true};
    }
    if (_presenceKey(command, args) case final key?) {
      _presence[key] = (command, args);
    }
    final sent = _tagged(command, args);
    final connection = _connection;
    if (connection == null || !_view.connected) return _offline(command, sent);
    final result = await connection.call(command, sent);
    if (_isLoss(result)) {
      _lost(connection, _errorText(result));
      return _offline(command, sent);
    }
    if (agentReadCommands.contains(command) && result['ok'] == true) {
      _lastKnown[_cacheKey(command, sent)] = result;
      _remember?.call(_lastKnown);
    }
    return result;
  }

  /// Every phone reading carries this phone's id, so the hub keeps
  /// presence per phone. The hub refuses an id that is not one of its phone
  /// things, so until it has one the readings go untagged and move the
  /// household person, as on a phone engine.
  Map<String, Object?> _tagged(String command, Map<String, Object?> args) {
    final reading =
        command.startsWith('phone.') ||
        command.startsWith('sensor.') ||
        command == 'nfc.scanned';
    if (!reading || !_phoneKnown || args.containsKey('phone')) return args;
    return {...args, 'phone': settings.phone};
  }

  static String? _presenceKey(String command, Map<String, Object?> args) =>
      switch (command) {
        'phone.wifi' || 'sensor.wifi' => 'wifi',
        'phone.ble' || 'sensor.ble' => 'ble/${args['name']}',
        'phone.bluetooth' => 'bluetooth/${args['address'] ?? args['name']}',
        _ => null,
      };

  Map<String, Object?> _offline(String command, Map<String, Object?> args) {
    if (agentReadCommands.contains(command)) {
      if (_lastKnown[_cacheKey(command, args)] case final last?) return last;
    }
    final reason = _view.state == HubLinkState.versionMismatch
        ? _view.reason ?? unreachableReason
        : unreachableReason;
    return {
      'ok': false,
      'error': {'type': 'unavailable', 'message': reason, 'issues': const []},
    };
  }

  static String _cacheKey(String command, Map<String, Object?> args) {
    final rest = {...args}..remove('phone');
    try {
      return '$command ${jsonEncode(rest)}';
    } on JsonUnsupportedObjectError {
      return command;
    }
  }

  static bool _isLoss(Map<String, Object?> result) {
    final error = result['error'];
    return result['ok'] != true &&
        error is Map &&
        error['type'] == 'unavailable';
  }

  static String _errorText(Map<String, Object?> result) {
    final error = result['error'];
    return error is Map ? '${error['message'] ?? ''}' : '';
  }

  Future<void> _open({bool now = false}) {
    if (_closed) return Future.value();
    if (_opening case final opening?) return opening.future;
    _retry?.cancel();
    _retry = null;
    if (now) _attempt = 0;
    final opening = _opening = Completer<void>();
    unawaited(
      _attemptOnce().whenComplete(() {
        _opening = null;
        opening.complete();
      }),
    );
    return opening.future;
  }

  Future<void> _attemptOnce() async {
    if (!_view.connected) {
      _set(_copy(HubLinkState.connecting, reason: _view.reason));
    }
    final connection = _connect();
    try {
      final hello = await connection.open();
      final hubVersion = hello.hubVersion;
      if (hubVersion != null && !versionsMatch(hubVersion, appVersion)) {
        throw HubConnectException(
          'version_mismatch',
          'The hub runs $hubVersion and this app $appVersion',
          hubVersion: hubVersion,
          appVersion: appVersion,
        );
      }
      if (_closed) {
        await connection.close();
        return;
      }
      _connection = connection;
      _hubEvents = connection.events.listen(_events.add);
      unawaited(connection.done.then((_) => _lost(connection, null)));
      _attempt = 0;
      final (known, owner) = await _phoneThing(connection);
      _phoneKnown = known;
      final person = hello.person ?? owner;
      _set(
        HubLinkView(
          state: HubLinkState.connected,
          address: settings.address,
          phone: settings.phone,
          person: person,
          connectedSince: _now(),
          hubVersion: hubVersion,
          appVersion: appVersion,
        ),
      );
      await _sendPresence(connection);
    } on HubConnectException catch (e) {
      await connection.close();
      _failed(e);
    } on Object catch (e) {
      await connection.close();
      _failed(HubConnectException('unavailable', '$e'));
    }
  }

  /// Whether the hub has a phone thing for this phone, and the person it
  /// names.
  Future<(bool, String?)> _phoneThing(HubSession connection) async {
    final got = await connection.call('device.get', {'id': settings.phone});
    final device = got['device'];
    if (got['ok'] != true || device is! Map || device['driver'] != 'phone') {
      return (false, null);
    }
    final person = (device['settings'] as Map?)?['person'];
    return (true, person is String && person.isNotEmpty ? person : null);
  }

  Future<void> _sendPresence(HubSession connection) async {
    for (final (command, args) in _presence.values.toList()) {
      await connection.call(command, _tagged(command, args));
    }
  }

  void _failed(HubConnectException e) {
    final mismatch = e.type == 'version_mismatch';
    final hub = e.hubVersion;
    final app = e.appVersion ?? appVersion;
    _set(
      HubLinkView(
        state: mismatch
            ? HubLinkState.versionMismatch
            : HubLinkState.unreachable,
        address: settings.address,
        phone: settings.phone,
        hubVersion: hub,
        appVersion: app,
        reason: mismatch
            ? versionMismatchText(hub, app)
            : hubFailureText(e.type, e.message, settings),
      ),
    );
    _scheduleRetry(mismatch ? 6 : _attempt++);
  }

  void _lost(HubSession connection, String? why) {
    if (_connection != connection || _closed) return;
    _connection = null;
    unawaited(_hubEvents?.cancel());
    _hubEvents = null;
    unawaited(connection.close());
    _set(
      _copy(
        HubLinkState.unreachable,
        reason: hubFailureText('unavailable', why ?? '', settings),
      ),
    );
    _scheduleRetry(_attempt++);
  }

  void _scheduleRetry(int attempt) {
    if (_closed) return;
    _retry?.cancel();
    _retry = Timer(_backoff(attempt), () {
      _retry = null;
      unawaited(_open());
    });
  }

  HubLinkView _copy(HubLinkState state, {String? reason}) => HubLinkView(
    state: state,
    address: settings.address,
    phone: settings.phone,
    person: _view.person,
    hubVersion: _view.hubVersion,
    appVersion: appVersion,
    reason: reason,
  );

  void _set(HubLinkView view) {
    final changed =
        view.state != _view.state ||
        view.reason != _view.reason ||
        view.connectedSince != _view.connectedSince;
    _view = view;
    if (changed && !_events.isClosed) {
      _events.add({'event': HubLink.event, ...view.toJson()});
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    await _hubEvents?.cancel();
    await _connection?.close();
    _connection = null;
    await _events.close();
  }
}

/// "Update the hub" or "Update the app", with both versions.
String versionMismatchText(String? hub, String app) {
  if (hub == null) {
    return 'The hub runs a different version from this app ($app). Update '
        'the one that is older.';
  }
  return compareVersions(hub, app) < 0
      ? 'Update the hub. It runs $hub and this app is $app.'
      : 'Update the app. The hub runs $hub and this app is $app.';
}

/// Why the hub did not answer, in words the user can act on.
String hubFailureText(String type, String message, HubSettings settings) =>
    switch (type) {
      'host_key' =>
        'The Mac mini offered a different host key from the one you '
            'checked. If it was reinstalled, set the hub up again from '
            'Settings.',
      'not_allowed' =>
        'The Mac mini did not let this phone in. Run the omni hub allow '
            'line on it again.',
      _ =>
        'The hub at ${settings.host} is not reachable. Check that the Mac '
            'mini is on and on this Wi-Fi or Tailscale.',
    };
