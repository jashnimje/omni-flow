import 'package:flutter/material.dart';

import '../design/design.dart';

/// One thing the library offers: a step kind, a device action, a trigger.
/// [onTap] gets the library sheet's context and pops it with what it built.
class LibraryChoice {
  const LibraryChoice({
    required this.key,
    required this.title,
    required this.icon,
    required this.category,
    required this.onTap,
    this.subtitle,
    this.warning = false,
    this.keywords = '',
    this.searchOnly = false,
  });

  final String key;
  final String title;
  final String? subtitle;
  final IconData icon;
  final String category;
  final Future<void> Function(BuildContext context)? onTap;
  final bool warning;

  /// More words a search matches, beyond the title and subtitle.
  final String keywords;

  /// Shown only for a search that matches it, such as each device action.
  final bool searchOnly;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return !searchOnly;
    return [
      title,
      subtitle ?? '',
      keywords,
      category,
    ].any((s) => s.toLowerCase().contains(q));
  }
}

/// A quick pick at the top of the library: a device or step kind this
/// rule already uses.
class LibrarySuggestion {
  const LibrarySuggestion({
    required this.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String key;
  final String label;
  final IconData icon;
  final Future<void> Function(BuildContext context) onTap;
}

/// Opens the library as a sheet: a search field, the [suggestions], the
/// [categories] as chips that narrow the list, then the [choices] under
/// their categories. Typing searches every choice, including the ones
/// only a search shows, and the ones [more] loads the first time someone
/// types (the apps on a TV).
Future<T?> showLibrary<T>(
  BuildContext context, {
  required String title,
  required String hint,
  required List<String> categories,
  required List<LibraryChoice> choices,
  List<LibrarySuggestion> suggestions = const [],
  Future<List<LibraryChoice>> Function()? more,
}) => showOmniSheet<T>(
  context,
  builder: (_) => _Library(
    title: title,
    hint: hint,
    categories: categories,
    choices: choices,
    suggestions: suggestions,
    more: more,
  ),
);

class _Library extends StatefulWidget {
  const _Library({
    required this.title,
    required this.hint,
    required this.categories,
    required this.choices,
    required this.suggestions,
    required this.more,
  });

  final String title;
  final String hint;
  final List<String> categories;
  final List<LibraryChoice> choices;
  final List<LibrarySuggestion> suggestions;
  final Future<List<LibraryChoice>> Function()? more;

  @override
  State<_Library> createState() => _LibraryState();
}

class _LibraryState extends State<_Library> {
  var _query = '';
  String? _category;
  Future<List<LibraryChoice>>? _more;

  void _search(String query) {
    setState(() {
      _query = query;
      if (query.trim().isNotEmpty) {
        _more ??= widget.more?.call().catchError((_) => <LibraryChoice>[]);
      }
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<LibraryChoice>>(
    future: _more,
    builder: (context, snap) {
      final all = [...widget.choices, ...?snap.data];
      final searching = _query.trim().isNotEmpty;
      final sections = [
        for (final cat in widget.categories)
          if (_category == null || _category == cat || searching)
            (
              cat,
              [
                for (final c in all)
                  if (c.category == cat && c.matches(_query)) c,
              ],
            ),
      ].where((s) => s.$2.isNotEmpty).toList();
      return OmniSheet(
        title: widget.title,
        children: [
          TextField(
            key: const ValueKey('picker-search'),
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: const Icon(OmniIcons.search),
            ),
            onChanged: _search,
          ),
          if (!searching && widget.suggestions.isNotEmpty) ...[
            const OmniSectionHeader('Suggestions'),
            Wrap(
              key: const ValueKey('library-suggestions'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in widget.suggestions)
                  OmniFilterChip(
                    key: ValueKey(s.key),
                    label: s.label,
                    icon: s.icon,
                    onTap: () => s.onTap(context),
                  ),
              ],
            ),
          ],
          if (!searching) ...[
            const SizedBox(height: OmniSpace.sm),
            Wrap(
              key: const ValueKey('library-categories'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cat in widget.categories)
                  if (all.any((c) => c.category == cat && !c.searchOnly))
                    OmniFilterChip(
                      key: ValueKey('category-$cat'),
                      label: cat,
                      selected: _category == cat,
                      onTap: () => setState(
                        () => _category = _category == cat ? null : cat,
                      ),
                    ),
              ],
            ),
          ],
          if (sections.isEmpty)
            OmniEmptyState(
              icon: OmniIcons.search,
              title: snap.connectionState == ConnectionState.waiting
                  ? 'Looking…'
                  : 'Nothing matches',
              message: 'Try another word, or clear the search.',
            ),
          for (final (title, choices) in sections) ...[
            OmniSectionHeader(title),
            for (final c in choices)
              OmniListRow(
                key: ValueKey(c.key),
                icon: c.icon,
                title: c.title,
                subtitle: c.subtitle,
                subtitleLines: 2,
                chevron: c.onTap != null,
                iconForeground: c.warning ? OmniColors.warn : null,
                trailing: c.warning
                    ? const Icon(
                        OmniIcons.warning,
                        color: OmniColors.warn,
                        size: 20,
                        semanticLabel: 'High risk',
                      )
                    : null,
                onTap: c.onTap == null ? null : () => c.onTap!(context),
              ),
          ],
        ],
      );
    },
  );
}
