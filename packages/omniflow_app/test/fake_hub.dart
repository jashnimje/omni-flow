import 'dart:async';

import 'package:omniflow_app/service/hub_connection.dart';
import 'package:omniflow_engine/omniflow_engine.dart'
    show omniflowEngineVersion;

/// A hub over loopback: answers from canned results, records calls, and
/// can drop the link or refuse to open.
class FakeHub {
  final calls = <(String, Map<String, Object?>)>[];
  final answers = <String, Map<String, Object?>>{
    'device.list': {
      'ok': true,
      'devices': [
        {'id': 'desk_lamp', 'name': 'Desk lamp'},
      ],
    },
    'device.get': {
      'ok': true,
      'device': {
        'id': 'jade_pixel',
        'driver': 'phone',
        'settings': {'person': 'jade'},
      },
    },
  };
  final eventsOut = StreamController<Map<String, Object?>>.broadcast();

  /// What the next [FakeHubSession.open] throws, when set.
  HubConnectException? refuse;
  HubHello hello = const HubHello(
    hostKey: 'ssh-ed25519 SHA256:abc',
    hubVersion: omniflowEngineVersion,
    person: 'jade',
  );
  var opens = 0;
  FakeHubSession? live;

  FakeHubSession connect() => FakeHubSession(this);

  /// The Mac mini goes away.
  void drop() => live?.drop();

  List<(String, Map<String, Object?>)> callsOf(String command) =>
      calls.where((c) => c.$1 == command).toList();
}

class FakeHubSession implements HubSession {
  FakeHubSession(this.hub);

  final FakeHub hub;
  final _done = Completer<void>();
  StreamSubscription<Map<String, Object?>>? _forward;
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<HubHello> open() async {
    hub.opens++;
    if (hub.refuse case final refuse?) throw refuse;
    hub.live = this;
    _forward = hub.eventsOut.stream.listen(_events.add);
    return hub.hello;
  }

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_done.isCompleted) {
      return {
        'ok': false,
        'error': {'type': 'unavailable', 'message': 'the link dropped'},
      };
    }
    hub.calls.add((command, args));
    return hub.answers[command] ?? const {'ok': true};
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> get done => _done.future;

  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    drop();
    await _forward?.cancel();
    if (hub.live == this) hub.live = null;
  }
}
