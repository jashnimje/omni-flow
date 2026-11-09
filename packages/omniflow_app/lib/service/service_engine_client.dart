import 'dart:async';

import '../api/engine_client.dart';
import '../api/tv_calls.dart';
import 'engine_link.dart';

/// The event this client adds to [EngineClient.events] when the service
/// stops, from its notification or from Android. It is the app's own event,
/// never one the engine sends.
const serviceStoppedEvent = 'service.stopped';

/// Talks to the engine in the foreground service over an [EngineLink]. Like
/// the engine, [call] never throws: a call the service cannot answer comes
/// back as an `unavailable` error.
class ServiceEngineClient implements EngineClient {
  ServiceEngineClient(
    this._link, {
    this.callTimeout = const Duration(minutes: 2),
    this.transferTimeout = const Duration(minutes: 30),
    String? session,
  }) : session = session ?? _newSession() {
    _sub = _link.incoming.listen(_onMessage);
  }

  final EngineLink _link;

  /// Long enough for the slowest command, a board joining Wi-Fi during
  /// board.setup.
  final Duration callTimeout;

  /// For the TV commands that move whole files or APKs, where a large file
  /// over Wi-Fi takes many minutes.
  final Duration transferTimeout;
  final String session;

  late final StreamSubscription<String> _sub;
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _pending = <int, Completer<Map<String, Object?>>>{};
  Completer<String?>? _ready;
  var _nextId = 0;
  String? _closedReason;

  /// The service task that answered [connect]. Only its `stopped` closes
  /// this client: a stopped task never answers again, so a `stopped` that
  /// comes before `ready` is from a task this client never used.
  String? _instance;

  static String _newSession() => newLinkId();

  /// Says hello until the service answers, and returns why the hub did not
  /// start, or null when it runs. Throws when the engine could not open or
  /// the service does not answer within [timeout]. The first hellos can be
  /// lost while the service isolate is still setting its handler.
  Future<String?> connect({
    Duration timeout = const Duration(seconds: 30),
    Duration retry = const Duration(milliseconds: 250),
  }) async {
    final ready = _ready ??= Completer<String?>();
    void hello() => _send({'t': LinkMessage.hello});
    hello();
    final again = Timer.periodic(retry, (_) => hello());
    try {
      return await ready.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'The background service did not answer',
          timeout,
        ),
      );
    } finally {
      again.cancel();
    }
  }

  @override
  Future<Map<String, Object?>> call(
    String command, [
    Map<String, Object?> args = const {},
  ]) {
    if (_closedReason case final reason?) {
      return Future.value(_unavailable(reason));
    }
    final id = _nextId++;
    final reply = _pending[id] = Completer<Map<String, Object?>>();
    try {
      _send({
        't': LinkMessage.call,
        'id': id,
        'command': command,
        'args': args,
      });
    } on Object catch (e) {
      _pending.remove(id);
      return Future.value(_error('invalid', 'cannot send $command: $e'));
    }
    return reply.future.timeout(
      TvCalls.longRunning.contains(command) ? transferTimeout : callTimeout,
      onTimeout: () {
        _pending.remove(id);
        return _unavailable('$command got no answer from the service');
      },
    );
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  void _send(Map<String, Object?> message) =>
      _link.send(LinkMessage.encode({...message, 's': session}));

  void _onMessage(String raw) {
    final message = LinkMessage.decode(raw);
    if (message == null) return;
    final mine = message['s'] == session;
    switch (message['t']) {
      case LinkMessage.ready when mine:
        final ready = _ready;
        if (ready == null || ready.isCompleted) return;
        _instance = message['i'] as String?;
        if (message['startError'] case final String error) {
          ready.completeError(StateError(error));
        } else {
          ready.complete(message['hubError'] as String?);
        }
      case LinkMessage.reply when mine:
        final result = message['result'];
        _pending
            .remove(message['id'])
            ?.complete(
              result is Map<String, Object?>
                  ? result
                  : _error('internal', 'the service sent no result'),
            );
      case LinkMessage.event:
        if (message['event'] case final Map<String, Object?> event) {
          _events.add(event);
        }
      case LinkMessage.stopped when _instance != null:
        if (message['i'] != _instance) return;
        _stop('${message['reason'] ?? 'OmniFlow was stopped'}');
    }
  }

  void _stop(String reason) {
    if (_closedReason != null) return;
    _closedReason = reason;
    for (final reply in _pending.values) {
      reply.complete(_unavailable(reason));
    }
    _pending.clear();
    _events.add({'event': serviceStoppedEvent, 'reason': reason});
    close();
  }

  /// Stops listening. Calls after this answer `unavailable`.
  Future<void> close() async {
    _closedReason ??= 'the app closed its connection';
    for (final reply in _pending.values) {
      reply.complete(_unavailable(_closedReason!));
    }
    _pending.clear();
    await _sub.cancel();
    await _link.close();
    await _events.close();
  }

  static Map<String, Object?> _unavailable(String message) =>
      _error('unavailable', message);

  static Map<String, Object?> _error(String type, String message) => {
    'ok': false,
    'error': {'type': type, 'message': message, 'issues': const []},
  };
}
