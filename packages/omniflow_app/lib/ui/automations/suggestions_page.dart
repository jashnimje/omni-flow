import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/design.dart';
import '../home/suggestion_card.dart';
import 'type_it_page.dart';

/// The top of the Automations list: Type what you want, and the
/// suggestions from habits when there are any.
class AutomationHelpers extends ConsumerWidget {
  const AutomationHelpers({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Home loads the suggestions when the app opens, so this list only
    // shows what is loaded and starts no read of its own.
    final suggestions = ref.watch(suggestionsProvider.exists)
        ? ref.watch(suggestionsProvider).value ?? const []
        : const [];
    return Padding(
      padding: const EdgeInsets.only(bottom: OmniSpace.sm),
      child: Column(
        children: [
          OmniListRow(
            key: const ValueKey('type-it'),
            icon: OmniIcons.edit,
            title: 'Type what you want',
            subtitle: 'Say it in a sentence, then check it in the editor',
            chevron: true,
            divider: suggestions.isNotEmpty,
            onTap: () => openTypeIt(context),
          ),
          if (suggestions.isNotEmpty)
            OmniListRow(
              key: const ValueKey('suggestions-row'),
              icon: OmniIcons.star,
              title: 'Suggestions',
              subtitle: suggestions.first.words,
              value: '${suggestions.length}',
              chevron: true,
              divider: false,
              semanticLabel:
                  '${suggestions.length} suggestion'
                  '${suggestions.length == 1 ? '' : 's'} from your habits',
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const SuggestionsPage()),
              ),
            ),
        ],
      ),
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
      banners: const [
        Padding(
          padding: EdgeInsets.only(bottom: OmniSpace.md),
          child: Text(
            'From the last four weeks of what you turned on and off '
            'yourself. Make it opens the automation to check before it is '
            'saved.',
            style: OmniText.caption,
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
