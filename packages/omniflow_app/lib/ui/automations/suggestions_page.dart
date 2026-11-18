import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/design.dart';
import '../home/suggestion_card.dart';
import 'new_automation.dart' show openNewAutomation;

/// Inside Ideas for you on the Automations list: the suggestions from
/// habits, or what to do while there are none.
class AutomationHelpers extends ConsumerWidget {
  const AutomationHelpers({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Home loads the suggestions when the app opens, so this list only
    // shows what is loaded and starts no read of its own.
    final suggestions = ref.watch(suggestionsProvider.exists)
        ? ref.watch(suggestionsProvider).value ?? const []
        : const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (suggestions.isNotEmpty)
          OmniListRow(
            key: const ValueKey('suggestions-row'),
            icon: OmniIcons.star,
            title: 'Suggestions',
            subtitle: suggestions.first.words,
            value: '${suggestions.length}',
            chevron: true,
            semanticLabel:
                '${suggestions.length} suggestion'
                '${suggestions.length == 1 ? '' : 's'} from your habits',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const SuggestionsPage()),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: OmniSpace.sm),
            child: Text(
              'Ideas show up once you do the same thing at about the same '
              'time for a couple of weeks.',
              style: OmniText.captionOf(context),
            ),
          ),
        OmniListRow(
          key: const ValueKey('ideas-templates'),
          icon: OmniIcons.add,
          title: 'Start from a template',
          subtitle: 'Arrive home, bedtime and more',
          chevron: true,
          divider: false,
          onTap: () => openNewAutomation(context),
        ),
      ],
    );
  }
}

/// Every suggestion from habits, each with Make it and Not now.
class SuggestionsPage extends ConsumerWidget {
  const SuggestionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(suggestionsProvider);
    return ListPage(
      title: 'Suggestions',
      state: OmniLoad.of(
        async,
        isEmpty: (v) => v.isEmpty,
        onRetry: () => ref.invalidate(suggestionsProvider),
        error: 'The suggestions did not load.',
      ),
      banners: [
        Padding(
          padding: const EdgeInsets.only(bottom: OmniSpace.md),
          child: Text(
            'From the last four weeks of what you turned on and off '
            'yourself. Make it opens the automation to check before it is '
            'saved.',
            style: OmniText.captionOf(context),
          ),
        ),
      ],
      empty: const OmniEmptyState(
        key: ValueKey('suggestions-empty'),
        icon: OmniIcons.star,
        title: 'Nothing to suggest yet',
        message:
            'Suggestions show up once you do the same thing at about the '
            'same time for a couple of weeks.',
      ),
      children: (context) => [
        for (final s in async.requireValue) SuggestionTile(suggestion: s),
      ],
    );
  }
}
