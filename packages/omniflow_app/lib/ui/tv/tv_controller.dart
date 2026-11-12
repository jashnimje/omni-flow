import '../../api/plain_error.dart';

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../api/engine_client.dart';
import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import 'tv_widgets.dart' show appNameOf;

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

  /// The file the running transfer is on, for its progress card.
  String? progressName;

  /// Labels by package, filled once the Apps tab has listed them, so the
  /// header can name the focused app.
  final appLabels = <String, String>{};

  /// What the app in front is called, or null when none is.
  String? get appName => switch (state.app) {
    final String app => appNameOf(app, label: appLabels[app]),
    null => null,
  };

  Timer? _timer;
  StreamSubscription<Json>? _events;
  var _disposed = false;

  void start() {
    unawaited(refresh());
    unawaited(_loadKeys());
    _resume();
    _events = client.events.listen(_onEvent);
    // No reads while the app is in the background: the hub keeps its own
    // poll, and this one only feeds the screen.
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _timer?.cancel();
        _timer = null;
      },
      onShow: () {
        if (_disposed || _timer != null) return;
        unawaited(refresh());
        _resume();
      },
    );
  }

  void _resume() => _timer = Timer.periodic(poll, (_) => unawaited(refresh()));

  AppLifecycleListener? _lifecycle;

  /// A read in flight, so a slow TV never gets several at once.
  var _reading = false;

  /// Bumped by each change the user makes, so a read that started before it
  /// cannot put the old value back.
  var _generation = 0;

  /// The TV is reachable but has not allowed this phone's key.
  var needsPairing = false;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _events?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// The Apps tab learned labels, so the header can name the app in front.
  void labelsChanged() => _changed();

  /// Reads the state without a snackbar, since it runs every few seconds.
  ///
  /// It never starts pairing: a read every few seconds would put "Allow USB
  /// debugging?" on the TV again each time it is dismissed. Pairing is the
  /// page's Pair button.
  Future<void> refresh() async {
    if (_reading) return;
    _reading = true;
    final generation = _generation;
    final Json result;
    try {
      result = await client.call(TvCalls.state, {
        ...TvCalls.idArgs(id),
        'allowPairing': false,
      });
    } finally {
      _reading = false;
    }
    if (_disposed || generation != _generation) return;
    loaded = true;
    needsPairing = false;
    if (result['ok'] == true) {
      state = TvCalls.stateOf(result);
      offline = null;
    } else if ((result['error'] as Map?)?['type'] == 'needs_user') {
      needsPairing = true;
      offline =
          'The TV has not let OmniFlow in yet. Tap Pair again, then choose '
          'Allow on the TV.';
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
    _generation++;
    final result = await call(TvCalls.volume, TvCalls.volumeArgs(id, level));
    if (result['ok'] == true) {
      // What the TV says it is now, when it says.
      if (result['volume'] case final int reported) level = reported;
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
  Future<Json> transfer(
    String command,
    Json args, {
    bool quiet = false,
    String? name,
  }) async {
    progress = (op: command, done: 0, total: null);
    progressName = name;
    _changed();
    try {
      return quiet
          ? await client.call(command, args)
          : await call(command, args);
    } finally {
      progress = null;
      progressName = null;
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
        offline = plainError(
          '${event['errorType'] ?? 'timeout'}',
          event['error'] as String?,
        );
        _changed();
    }
  }
}
