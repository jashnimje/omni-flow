import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How the rule editor shows a rule: as its sentence or as a diagram.
enum RuleView { sentence, diagram }

/// The view last chosen, kept on this phone only: it is how the app
/// looks, not part of the home.
abstract interface class RuleViewStore {
  Future<RuleView?> read();
  Future<void> write(RuleView view);
}

/// Kept in the app's shared preferences through flutter_foreground_task,
/// as the first-run flag is. Where they cannot be read (tests, a broken
/// store) the sentence view shows.
class PrefsRuleViewStore implements RuleViewStore {
  const PrefsRuleViewStore();

  static const _key = 'rule_view';

  @override
  Future<RuleView?> read() async {
    try {
      final name = await FlutterForegroundTask.getData<String>(key: _key);
      return RuleView.values.where((v) => v.name == name).firstOrNull;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(RuleView view) async {
    try {
      await FlutterForegroundTask.saveData(key: _key, value: view.name);
    } on Object {
      return;
    }
  }
}

/// Holds the choice in memory, for tests.
class MemoryRuleViewStore implements RuleViewStore {
  MemoryRuleViewStore([this.view]);

  RuleView? view;

  @override
  Future<RuleView?> read() async => view;

  @override
  Future<void> write(RuleView view) async => this.view = view;
}

final ruleViewStoreProvider = Provider<RuleViewStore>(
  (ref) => const PrefsRuleViewStore(),
);

/// The rule editor's view, the sentence until a stored choice is read.
class RuleViewNotifier extends Notifier<RuleView> {
  var _chosen = false;

  @override
  RuleView build() {
    ref.read(ruleViewStoreProvider).read().then((v) {
      // A choice made before the stored one was read wins.
      if (v != null && ref.mounted && !_chosen) state = v;
    });
    return RuleView.sentence;
  }

  Future<void> set(RuleView view) async {
    _chosen = true;
    state = view;
    await ref.read(ruleViewStoreProvider).write(view);
  }
}

final ruleViewProvider = NotifierProvider<RuleViewNotifier, RuleView>(
  RuleViewNotifier.new,
);
