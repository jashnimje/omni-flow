import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../rules/things.dart';
import '../../state/providers.dart';

/// Why the automation list could not load, for the screen's error state.
class AutomationsUnavailable implements Exception {
  const AutomationsUnavailable(this.failure);

  final ApiFailure failure;
}

/// Every automation as `automation.list` writes it (sentence, last run, the
/// things it uses), reloaded when runs finish (at most once per [settle])
/// and after any screen changes one. Scenes are automations too; the
/// Automations tab leaves them to Home and Settings.
class AutomationsNotifier extends AsyncNotifier<List<AutomationSummary>> {
  static const settle = Duration(milliseconds: 500);
  Timer? _reload;

  @override
  Future<List<AutomationSummary>> build() async {
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
    return _load();
  }

  Future<List<AutomationSummary>> _load() async {
    final reply = await ref.read(engineApiProvider).automations();
    if (reply.failure case final failure?) {
      throw AutomationsUnavailable(failure);
    }
    return reply.value!;
  }

  /// Loads the list again. A failed reload keeps the list on screen (the
  /// failure has shown as a snackbar); a failed first load shows the error.
  Future<void> refresh() async {
    try {
      final list = await _load();
      if (ref.mounted) state = AsyncData(list);
    } on AutomationsUnavailable catch (e, stack) {
      if (ref.mounted && state.value == null) state = AsyncError(e, stack);
    }
  }

  /// Loads again from scratch, showing the loading state.
  Future<void> retry() async {
    state = const AsyncLoading();
    await refresh();
  }
}

final automationsProvider =
    AsyncNotifierProvider<AutomationsNotifier, List<AutomationSummary>>(
      AutomationsNotifier.new,
      // The screen shows the failure with Try again rather than retrying
      // behind a spinner.
      retry: (_, _) => null,
    );

/// The things a rule can name, from the live device list.
final ruleThingsProvider = Provider<List<Thing>>(
  (ref) => thingsOf(ref.watch(devicesProvider).value ?? const []),
);
