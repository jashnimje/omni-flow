import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_client.dart';

typedef Json = Map<String, Object?>;

/// Overridden in main() with the real engine, and in tests with a fake.
final engineClientProvider = Provider<EngineClient>(
  (ref) => throw UnimplementedError('override engineClientProvider'),
);

/// Shows API errors without each screen handling them.
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Calls the engine and shows the error message when the call fails.
Future<Json> callEngine(
  WidgetRef ref,
  String command, [
  Json args = const {},
]) async {
  final result = await ref.read(engineClientProvider).call(command, args);
  if (result['ok'] != true) {
    final error = result['error'] as Map? ?? const {};
    messengerKey.currentState?.showSnackBar(
      SnackBar(content: Text('${error['message'] ?? 'failed'}')),
    );
  }
  return result;
}

/// Devices with their capabilities, kept current from engine events.
class DevicesNotifier extends AsyncNotifier<List<Json>> {
  @override
  Future<List<Json>> build() async {
    final client = ref.watch(engineClientProvider);
    final sub = client.events.listen((e) {
      if (e['event'] != 'device.stateChanged') return;
      final changed = Map<String, Object?>.from(e['device'] as Map);
      final current = state.value;
      if (current == null) return;
      state = AsyncData([
        for (final d in current)
          d['id'] == changed['id']
              ? {...d, ...changed, 'capabilities': d['capabilities']}
              : d,
      ]);
    });
    ref.onDispose(sub.cancel);
    return _load(client);
  }

  Future<List<Json>> _load(EngineClient client) async {
    final result = await client.call('device.list', {'withCapabilities': true});
    return [
      for (final d in (result['devices'] as List? ?? const []))
        Map<String, Object?>.from(d as Map),
    ];
  }

  Future<void> refresh() async =>
      state = AsyncData(await _load(ref.read(engineClientProvider)));
}

final devicesProvider = AsyncNotifierProvider<DevicesNotifier, List<Json>>(
  DevicesNotifier.new,
);

/// Flows, reloaded after any run finishes or a flow changes.
class FlowsNotifier extends AsyncNotifier<List<Json>> {
  @override
  Future<List<Json>> build() async {
    final client = ref.watch(engineClientProvider);
    final sub = client.events
        .where((e) => e['event'] == 'run.finished')
        .listen((_) => refresh());
    ref.onDispose(sub.cancel);
    return _load(client);
  }

  Future<List<Json>> _load(EngineClient client) async {
    final result = await client.call('flow.list');
    return [
      for (final f in (result['flows'] as List? ?? const []))
        Map<String, Object?>.from(f as Map),
    ];
  }

  Future<void> refresh() async =>
      state = AsyncData(await _load(ref.read(engineClientProvider)));
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
