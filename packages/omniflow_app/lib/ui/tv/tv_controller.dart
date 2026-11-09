import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/engine_client.dart';
import '../../api/tv_calls.dart';
import '../../state/providers.dart';

/// One open TV control centre: the TV's live state, its key catalog and
/// the progress of whatever transfer runs, shared by the header and every
/// tab. Engine errors from user actions show as snackbars.
class TvController extends ChangeNotifier {
  TvController({required this.client, required this.id, required this.poll});

  final EngineClient client;
  final String id;
  final Duration poll;

  TvState state = const TvState();

  /// Why the TV did not answer the last state read, or null when it did.
  String? offline;
  var loaded = false;
  List<TvKeyGroup> keyGroups = const [];
  TvProgress? progress;

  /// Labels by package, filled once the Apps tab has listed them, so the
  /// header can name the focused app.
  final appLabels = <String, String>{};

  Timer? _timer;
  StreamSubscription<Json>? _events;
  var _disposed = false;

  void start() {
    unawaited(refresh());
    unawaited(_loadKeys());
    _timer = Timer.periodic(poll, (_) => unawaited(refresh()));
    _events = client.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _events?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Reads the state without a snackbar, since it runs every few seconds.
  Future<void> refresh() async {
    final result = await client.call(TvCalls.state, TvCalls.idArgs(id));
    if (_disposed) return;
    loaded = true;
    if (result['ok'] == true) {
      state = TvCalls.stateOf(result);
      offline = null;
    } else {
      offline = errorMessage(result);
    }
    _changed();
  }

  Future<void> _loadKeys() async {
    final result = await client.call(TvCalls.keys, TvCalls.idArgs(id));
    if (_disposed || result['ok'] != true) return;
    keyGroups = TvCalls.keyGroupsOf(result);
    _changed();
  }

  /// The catalog key with [keycode], when the catalog has one.
  TvKey? catalogKey(int keycode) {
    for (final g in keyGroups) {
      for (final k in g.keys) {
        if (k.keycode == keycode) return k;
      }
    }
    return null;
  }

  Future<Json> call(String command, Json args) =>
      callClient(client, command, args);

  Future<bool> key(int keycode, {bool longPress = false, int repeat = 1}) =>
      sendKey(
        name: catalogKey(keycode)?.key,
        keycode: keycode,
        longPress: longPress,
        repeat: repeat,
      );

  Future<bool> sendKey({
    String? name,
    int? keycode,
    bool longPress = false,
    int repeat = 1,
  }) async {
    final result = await call(
      TvCalls.key,
      TvCalls.keyArgs(
        id,
        name: name,
        keycode: keycode,
        longPress: longPress,
        repeat: repeat,
      ),
    );
    return result['ok'] == true;
  }

  Future<bool> setVolume(int level) async {
    final result = await call(TvCalls.volume, TvCalls.volumeArgs(id, level));
    if (result['ok'] == true) {
      state = TvState(
        power: state.power,
        app: state.app,
        activity: state.activity,
        playing: state.playing,
        volume: level,
        volumeMax: state.volumeMax,
        muted: state.muted,
      );
      _changed();
    }
    return result['ok'] == true;
  }

  /// Runs a transfer, clearing its progress when it ends. With [quiet] the
  /// caller handles the error, so it can ask about a conflict first.
  Future<Json> transfer(String command, Json args, {bool quiet = false}) async {
    progress = (op: command, done: 0, total: null);
    _changed();
    try {
      return quiet
          ? await client.call(command, args)
          : await call(command, args);
    } finally {
      progress = null;
      _changed();
    }
  }

  void _onEvent(Json event) {
    if (TvCalls.progressOf(event, id) case final p?) {
      progress = p;
      _changed();
      return;
    }
    switch (event['event']) {
      case 'device.stateChanged':
        final device = event['device'];
        if (device is! Map || device['id'] != id) return;
        if (device['state'] is! Map) return;
        final s = TvState.ofDevice(Map<String, Object?>.from(device));
        state = TvState(
          power: s.power ?? state.power,
          app: s.app ?? state.app,
          activity: state.activity,
          playing: s.playing ?? state.playing,
          volume: s.volume ?? state.volume,
          volumeMax: state.volumeMax,
          muted: s.muted ?? state.muted,
        );
        _changed();
      case 'device.offline' || 'device.pollFailed':
        if (event['device'] != id) return;
        offline = '${event['error'] ?? 'not reachable'}';
        _changed();
    }
  }
}
