import 'package:flutter/material.dart';

import '../banner.dart';
import '../headers.dart';
import '../icons.dart';
import '../list_row.dart';
import '../sheet.dart';
import '../tokens.dart';
import 'load_state.dart';
import 'sheet_template.dart';

/// One choice of a [PickerSheet].
@immutable
class PickerItem<T> {
  const PickerItem({
    required this.value,
    required this.title,
    this.subtitle,
    this.icon,
    this.key,
    this.destructive = false,
  });

  final T value;
  final String title;
  final String? subtitle;
  final IconData? icon;

  /// The row's key, for tests.
  final Key? key;

  /// A choice that removes or stops something: its icon shows in red.
  final bool destructive;

  bool matches(String query) {
    final q = query.toLowerCase();
    return title.toLowerCase().contains(q) ||
        (subtitle?.toLowerCase().contains(q) ?? false);
  }
}

/// A group of choices under an optional heading. Put Suggestions first.
@immutable
class PickerSection<T> {
  const PickerSection(this.items, {this.title});

  final String? title;
  final List<PickerItem<T>> items;
}

/// Opens a [PickerSheet] and returns the picked value, or null when the
/// user closes it or taps [addLabel].
Future<T?> showPickerSheet<T>(
  BuildContext context, {
  required String title,
  required List<PickerSection<T>> sections,
  String? subtitle,
  T? selected,
  OmniLoad state = const OmniLoad.data(),
  String? addLabel,
  VoidCallback? onAdd,
  int searchFrom = PickerSheet.defaultSearchFrom,
}) => showOmniSheet<T>(
  context,
  builder: (_) => PickerSheet<T>(
    title: title,
    subtitle: subtitle,
    sections: sections,
    selected: selected,
    state: state,
    addLabel: addLabel,
    onAdd: onAdd,
    searchFrom: searchFrom,
  ),
);

/// T7, pick one item (a mode, a room, a scene, a template, an app): a
/// [SheetTemplate] with a pinned search field once the list has more than
/// [searchFrom] choices, the [sections], a check on the [selected] one,
/// and an [addLabel] row at the end when the list can grow. Tapping a
/// row pops its value.
class PickerSheet<T> extends StatefulWidget {
  const PickerSheet({
    super.key,
    required this.title,
    required this.sections,
    this.subtitle,
    this.selected,
    this.state = const OmniLoad.data(),
    this.addLabel,
    this.onAdd,
    this.searchFrom = defaultSearchFrom,
  });

  static const defaultSearchFrom = 8;

  final String title;
  final String? subtitle;
  final List<PickerSection<T>> sections;
  final T? selected;
  final OmniLoad state;

  /// "Add a room". The sheet closes, then [onAdd] runs.
  final String? addLabel;
  final VoidCallback? onAdd;
  final int searchFrom;

  @override
  State<PickerSheet<T>> createState() => _PickerSheetState<T>();
}

class _PickerSheetState<T> extends State<PickerSheet<T>> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  int get _count => widget.sections.fold(0, (sum, s) => sum + s.items.length);

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim();
    final searchable = _count > widget.searchFrom;
    final sections = [
      for (final s in widget.sections)
        PickerSection<T>([
          for (final i in s.items)
            if (query.isEmpty || i.matches(query)) i,
        ], title: s.title),
    ].where((s) => s.items.isNotEmpty).toList();
    final state = widget.state.isData && _count == 0 && widget.addLabel == null
        ? const OmniLoad.empty()
        : widget.state;
    return SheetTemplate(
      title: widget.title,
      subtitle: widget.subtitle,
      state: state,
      pinned: searchable && widget.state.isData
          ? TextField(
              key: const ValueKey('picker-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(OmniIcons.search),
                hintText: 'Search',
              ),
            )
          : null,
      children: (context) => [
        if (sections.isEmpty && query.isNotEmpty)
          const OmniEmptyState(
            icon: OmniIcons.search,
            title: 'Nothing matches',
            compact: true,
          ),
        for (final s in sections) ...[
          if (s.title != null) OmniSectionHeader(s.title!),
          for (final item in s.items)
            OmniListRow(
              key: item.key,
              title: item.title,
              subtitle: item.subtitle,
              icon: item.icon,
              iconForeground: item.destructive ? OmniColors.bad : null,
              selected: item.value == widget.selected,
              trailing: item.value == widget.selected
                  ? Icon(
                      OmniIcons.check,
                      color: OmniPalette.of(context).accent,
                      key: const ValueKey('picker-chosen'),
                    )
                  : null,
              onTap: () => Navigator.of(context).pop(item.value),
            ),
        ],
        if (widget.addLabel != null)
          OmniListRow(
            key: const ValueKey('picker-add'),
            title: widget.addLabel!,
            icon: OmniIcons.add,
            divider: false,
            onTap: () {
              Navigator.of(context).pop();
              widget.onAdd?.call();
            },
          ),
      ],
    );
  }
}
