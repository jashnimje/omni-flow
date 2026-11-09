import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_client.dart';

typedef Json = Map<String, Object?>;

/// Overridden in main() with the real engine, and in tests with a fake.
final engineClientProvider = Provider<EngineClient>(
  (ref) => throw UnimplementedError('override engineClientProvider'),
);

/// Why the hub did not start at launch, or null when it runs.
final hubErrorProvider = Provider<String?>((ref) => null);

/// Shows API errors without each screen handling them.
final messengerKey = GlobalKey<ScaffoldMessengerState>();

void showMessage(String text) =>
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));

/// Calls the engine and shows the error message when the call fails.
Future<Json> callEngine(
  WidgetRef ref,
  String command, [
  Json args = const {},
]) => callClient(ref.read(engineClientProvider), command, args);

Future<Json> callClient(
  EngineClient client,
  String command, [
  Json args = const {},
]) async {
  final result = await client.call(command, args);
  if (result['ok'] != true) showMessage(errorMessage(result));
  return result;
}

/// The error's message and, for a validation error, each issue, since the
/// message alone only names what was invalid.
String errorMessage(Json result) {
  final error = result['error'] as Map? ?? const {};
  return [
    '${error['message'] ?? 'failed'}',
    for (final issue in (error['issues'] as List? ?? const []))
      switch (issue) {
        {'path': final path, 'message': final message} => '$path: $message',
        _ => '$issue',
      },
  ].join('\n');
}

/// Devices with their capabilities, kept current from engine events. A
/// device the engine reports unreachable carries `online: false` and the
/// reason in `offlineReason` until it is heard from again.
class DevicesNotifier extends AsyncNotifier<List<Json>> {
  final _offline = <String, String>{};
  String? _lastBoardError;

  @override
  Future<List<Json>> build() async {
    final client = ref.watch(engineClientProvider);
    final sub = client.events.listen(_onEvent);
    ref.onDispose(sub.cancel);
    return _load(client);
  }

  void _onEvent(Json e) {
    final current = state.value;
    switch (e['event']) {
      case 'device.stateChanged':
        final changed = Map<String, Object?>.from(e['device'] as Map);
        final heard = changed['online'] != false;
        if (heard) _offline.remove(changed['id']);
        if (current == null) return;
        state = AsyncData([
          for (final d in current)
            d['id'] == changed['id'] ? _merge(d, changed, heard) : d,
        ]);
      case 'device.offline' || 'board.offline' || 'device.pollFailed':
        final id = e['device'];
        if (id is! String) return;
        _offline[id] = '${e['error'] ?? 'not reachable'}';
        if (current == null) return;
        state = AsyncData([for (final d in current) _withStatus(d)]);
      case 'board.error':
        // A failing board repeats its error with every hello.
        final text = 'Board error: ${e['error']}';
        if (text == _lastBoardError) return;
        _lastBoardError = text;
        showMessage(text);
    }
  }

  Json _merge(Json d, Json changed, bool heard) {
    final merged = {...d, ...changed, 'capabilities': d['capabilities']};
    if (heard) {
      merged['online'] = changed['online'] ?? true;
      merged.remove('offlineReason');
    }
    return _withStatus(merged);
  }

  Json _withStatus(Json d) {
    final reason = _offline[d['id']];
    return reason == null
        ? d
        : {...d, 'online': false, 'offlineReason': reason};
  }

  Future<List<Json>> _load(EngineClient client) async {
    final result = await client.call('device.list', {'withCapabilities': true});
    return [
      for (final d in (result['devices'] as List? ?? const []))
        _withStatus(Map<String, Object?>.from(d as Map)),
    ];
  }

  Future<void> refresh() async =>
      state = AsyncData(await _load(ref.read(engineClientProvider)));
}

final devicesProvider = AsyncNotifierProvider<DevicesNotifier, List<Json>>(
  DevicesNotifier.new,
);

/// Flows, reloaded after runs finish (at most once per [settle]) or a flow
/// changes.
class FlowsNotifier extends AsyncNotifier<List<Json>> {
  static const settle = Duration(milliseconds: 500);
  Timer? _reload;

  @override
  Future<List<Json>> build() async {
    final client = ref.watch(engineClientProvider);
    final sub = client.events
        .where((e) => e['event'] == 'run.finished')
        .listen(
          (_) => _reload ??= Timer(settle, () {
            _reload = null;
            refresh();
          }),
        );
    ref.onDispose(() {
      sub.cancel();
      _reload?.cancel();
    });
    return _load(client);
  }

  Future<List<Json>> _load(EngineClient client) async {
    final result = await client.call('flow.list');
    return [
      for (final f in (result['flows'] as List? ?? const []))
        Map<String, Object?>.from(f as Map),
    ];
  }

  Future<void> refresh() async {
    final flows = await _load(ref.read(engineClientProvider));
    if (ref.mounted) state = AsyncData(flows);
  }
}

final flowsProvider = AsyncNotifierProvider<FlowsNotifier, List<Json>>(
  FlowsNotifier.new,
);

/// The newest packets for the inspector, oldest dropped past [cap].
class PacketsNotifier extends Notifier<List<Json>> {
  static const cap = 200;

  @override
  List<Json> build() {
    final sub = ref
        .watch(engineClientProvider)
        .events
        .where((e) => e['event'] == 'packet.captured')
        .listen((p) {
          final next = [p, ...state];
          state = next.length > cap ? next.sublist(0, cap) : next;
        });
    ref.onDispose(sub.cancel);
    return const [];
  }

  void clear() => state = const [];
}

final packetsProvider = NotifierProvider<PacketsNotifier, List<Json>>(
  PacketsNotifier.new,
);
