import 'dart:async';
import 'dart:convert';

import '../api/engine_client.dart';
import 'engine_link.dart';

/// The service end of the link: answers the UI's calls from the engine the
/// service owns and forwards every engine event. Messages that arrive while
/// the engine is still opening wait for it.
class EngineHost {
  EngineHost({required this._send, String? instance})
    : instance = instance ?? newLinkId();

  final void Function(String message) _send;

  /// This service task, so a client ignores the `stopped` of a task that
  /// a restart replaced.
  final String instance;
  final _opened = Completer<EngineClient?>();
  StreamSubscription<Map<String, Object?>>? _events;
  String? _hubError;
  String? _startError;
  var _stopped = false;

  /// Starts serving [engine], which was opened with the hub result
  /// [hubError].
  void attach(EngineClient engine, {String? hubError}) {
    if (_opened.isCompleted) return;
    _hubError = hubError;
    _events = engine.events.listen(
      (event) => _post({'t': LinkMessage.event, 'event': event}),
    );
    _opened.complete(engine);
  }

  /// The engine could not open: every hello is told why.
  void fail(String error) {
    if (_opened.isCompleted) return;
    _startError = error;
    _opened.complete(null);
  }

  /// Handles one message from the UI.
  Future<void> receive(Object? data) async {
    final message = LinkMessage.decode(data);
    if (message == null || _stopped) return;
    final session = message['s'];
    if (session is! String) return;
    switch (message['t']) {
      case LinkMessage.hello:
        await _opened.future;
        _post({
          't': LinkMessage.ready,
          's': session,
          'i': instance,
          'hubError': ?_hubError,
          'startError': ?_startError,
        });
      case LinkMessage.call:
        final id = message['id'];
        final command = message['command'];
        final args = message['args'];
        if (id is! int || command is! String) return;
        final engine = await _opened.future;
        final result = engine == null
            ? _error('unavailable', 'OmniFlow did not start: $_startError')
            : await _answer(engine, command, args);
        _post({
          't': LinkMessage.reply,
          's': session,
          'id': id,
          'result': result,
        });
    }
  }

  Future<Map<String, Object?>> _answer(
    EngineClient engine,
    String command,
    Object? args,
  ) async {
    if (args is! Map<String, Object?>) {
      return _error('invalid', 'args is an object');
    }
    try {
      return await engine.call(command, args);
    } on Object catch (e) {
      return _error('internal', '$command failed: $e');
    }
  }

  /// Tells the UI the service is going away and stops forwarding events.
  Future<void> stop(String reason) async {
    if (_stopped) return;
    _stopped = true;
    _post({'t': LinkMessage.stopped, 'i': instance, 'reason': reason});
    await _events?.cancel();
  }

  void _post(Map<String, Object?> message) {
    String encoded;
    try {
      encoded = LinkMessage.encode(message);
    } on JsonUnsupportedObjectError catch (e) {
      if (message['t'] != LinkMessage.reply) return;
      encoded = LinkMessage.encode({
        ...message,
        'result': _error('internal', 'the result is not JSON: ${e.cause}'),
      });
    }
    _send(encoded);
  }

  static Map<String, Object?> _error(String type, String message) => {
    'ok': false,
    'error': {'type': type, 'message': message, 'issues': const []},
  };
}
