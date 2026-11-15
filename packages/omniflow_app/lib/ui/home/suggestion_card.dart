import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/suggestion_calls.dart';
import '../../state/providers.dart';
import '../automations/rule_editor.dart';
import '../design/design.dart';

/// The rules the engine offers from the person's habits, best first. Make
/// it and Not now reload it, so a rule saved from one drops it.
final suggestionsProvider = FutureProvider<List<Suggestion>>(
  (ref) => SuggestionCalls.fetch(ref.watch(engineClientProvider)),
);

/// Make it opens the suggested rule in the editor to check and save.
Future<void> makeSuggestion(
  BuildContext context,
  WidgetRef ref,
  Suggestion s,
) async {
  await openRuleEditor(context, spec: s.spec);
  ref.invalidate(suggestionsProvider);
}

/// Not now tells the engine, which stops offering it.
Future<void> dismissSuggestion(WidgetRef ref, Suggestion s) async {
  final done = await SuggestionCalls.notNow(
    ref.read(engineClientProvider),
    s.id,
  );
  if (!done) {
    showMessage('That suggestion could not be put away. Try again.');
  }
  ref.invalidate(suggestionsProvider);
}

/// Home's "Make it automatic?" card: the best suggestion in plain words,
/// with Make it and Not now. Nothing shows when there is none.
class SuggestionCard extends ConsumerWidget {
  const SuggestionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(suggestionsProvider).value?.firstOrNull;
    if (s == null) return const SizedBox.shrink();
    return SuggestionTile(
      key: const ValueKey('suggestion-card'),
      suggestion: s,
      title: 'Make it automatic?',
    );
  }
}

/// One suggestion: its words, then Make it and Not now.
class SuggestionTile extends ConsumerWidget {
  const SuggestionTile({super.key, required this.suggestion, this.title});

  final Suggestion suggestion;
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = suggestion;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Semantics(
              header: true,
              child: Text(title!, style: OmniText.bodyStrong),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: OmniSpace.sm),
            child: Text(
              s.words,
              key: ValueKey('suggestion-words-${s.id}'),
              style: OmniText.body,
            ),
          ),
          Wrap(
            spacing: OmniSpace.sm,
            runSpacing: OmniSpace.sm,
            children: [
              OmniButton(
                key: ValueKey('suggestion-make-${s.id}'),
                label: 'Make it',
                icon: OmniIcons.add,
                expand: false,
                onPressed: () => makeSuggestion(context, ref, s),
              ),
              OmniButton.ghost(
                key: ValueKey('suggestion-not-now-${s.id}'),
                label: 'Not now',
                expand: false,
                onPressed: () => dismissSuggestion(ref, s),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
