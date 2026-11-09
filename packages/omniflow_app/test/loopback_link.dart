import 'dart:async';

import 'package:omniflow_app/service/engine_host.dart';
import 'package:omniflow_app/service/engine_link.dart';

/// The plugin's data channel in one isolate: UI ends send to [host], and
/// the host's messages reach every UI end, as sendDataToMain does.
class LoopbackLink {
  LoopbackLink() {
    host = EngineHost(send: _toUi.add);
    _toService.stream.listen((m) {
      if (!serviceDeaf) host.receive(m);
    });
  }

  late EngineHost host;
  final _toUi = StreamController<String>.broadcast();

  /// A new service task in place of [host], as a restart makes. Returns the
  /// old one, which can still post to every UI end until it is destroyed.
  EngineHost replaceHost() {
    final old = host;
    host = EngineHost(send: _toUi.add);
    return old;
  }

  final _toService = StreamController<String>.broadcast();

  /// Drops what UIs send, as Android does before the task handler is set.
  bool serviceDeaf = false;

  /// A new UI end, like the one a reopened activity makes.
  EngineLink uiEnd() => _UiEnd(this);
}

class _UiEnd implements EngineLink {
  _UiEnd(this._link);

  final LoopbackLink _link;

  @override
  void send(String message) => _link._toService.add(message);

  @override
  Stream<String> get incoming => _link._toUi.stream;

  @override
  Future<void> close() async {}
}
