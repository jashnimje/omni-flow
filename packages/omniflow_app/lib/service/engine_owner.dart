import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// Makes a service task wait for the engine the task before it still holds.
///
/// A restart (Retry, the plugin's auto restart) runs the old task's
/// onDestroy without waiting for it and starts the new task in a new
/// isolate at once. Two engines would then share the database and run the
/// same automations, and the old one closing would take the new one's
/// agent socket with it. The isolates share nothing in Dart, and file
/// locks are per process, so the owner is a port registered by name.
class EngineOwner {
  EngineOwner({this.name = 'omniflow.engine', this.wait = _wait});

  final String name;

  /// How long to wait for the old engine. One killed outright never
  /// answers, so the new task opens anyway after this.
  final Duration wait;
  static const _wait = Duration(seconds: 10);

  ReceivePort? _port;
  final _waiting = <SendPort>[];
  var _released = false;

  /// Waits for the engine another task holds to close, then takes over.
  Future<void> claim() async {
    if (IsolateNameServer.lookupPortByName(name) case final previous?) {
      final answer = ReceivePort();
      previous.send(answer.sendPort);
      try {
        await answer.first.timeout(wait);
      } on TimeoutException {
        // Gone without closing: nothing holds the engine any more.
      } finally {
        answer.close();
      }
    }
    final port = _port = ReceivePort();
    port.listen((message) {
      if (message is! SendPort) return;
      if (_released) {
        message.send(true);
      } else {
        _waiting.add(message);
      }
    });
    IsolateNameServer.removePortNameMapping(name);
    IsolateNameServer.registerPortWithName(port.sendPort, name);
  }

  /// The engine is closed: a task waiting to open its own can go ahead.
  void release() {
    if (_released) return;
    _released = true;
    final port = _port;
    if (port == null) return;
    if (IsolateNameServer.lookupPortByName(name) == port.sendPort) {
      IsolateNameServer.removePortNameMapping(name);
    }
    for (final waiting in _waiting) {
      waiting.send(true);
    }
    _waiting.clear();
    port.close();
  }
}
