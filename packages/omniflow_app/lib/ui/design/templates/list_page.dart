import 'package:flutter/material.dart';

import '../headers.dart';
import '../tokens.dart';
import 'load_state.dart';

/// T2, a pushed list of many things of one kind: the large title, header
/// [actions] (add as an [OmniIconAction], more), a pinned [search] field
/// and [filters], sections of rows, and an optional [bottom] bar. It draws
/// the skeleton, error banner and [empty] state from [state].
///
/// Three bodies: [ListPage] takes the rows as a list, [ListPage.builder]
/// builds them lazily, and [ListPage.custom] takes any scroll view (a
/// reorderable list) and the padding to give it.
class ListPage extends StatelessWidget {
  const ListPage({
    super.key,
    required this.title,
    required List<Widget> Function(BuildContext context) this.children,
    this.actions = const [],
    this.close = false,
    this.search,
    this.filters,
    this.state = const OmniLoad.data(),
    this.skeletonRows = 5,
    this.empty,
    this.banners = const [],
    this.bottom,
    this.controller,
  }) : itemCount = null,
       itemBuilder = null,
       body = null;

  const ListPage.builder({
    super.key,
    required this.title,
    required int this.itemCount,
    required IndexedWidgetBuilder this.itemBuilder,
    this.actions = const [],
    this.close = false,
    this.search,
    this.filters,
    this.state = const OmniLoad.data(),
    this.skeletonRows = 5,
    this.empty,
    this.banners = const [],
    this.bottom,
    this.controller,
  }) : children = null,
       body = null;

  const ListPage.custom({
    super.key,
    required this.title,
    required Widget Function(BuildContext context, EdgeInsets padding)
    this.body,
    this.actions = const [],
    this.close = false,
    this.search,
    this.filters,
    this.state = const OmniLoad.data(),
    this.skeletonRows = 5,
    this.empty,
    this.banners = const [],
    this.bottom,
    this.controller,
  }) : children = null,
       itemCount = null,
       itemBuilder = null;

  final String title;
  final List<Widget> actions;

  /// A cross instead of the back chevron, for a flow entered modally.
  final bool close;

  /// Pinned under the title: the list's search field.
  final Widget? search;

  /// Pinned under [search]: filter chips or a segmented control.
  final Widget? filters;
  final OmniLoad state;
  final int skeletonRows;

  /// For [OmniLoadStatus.empty]: an [OmniEmptyState], `compact: true`
  /// when a search or filter matches nothing.
  final Widget? empty;
  final List<Widget> banners;

  /// A bulk or commit action ([OmniActionBar]). Null for most lists.
  final Widget? bottom;
  final ScrollController? controller;

  final List<Widget> Function(BuildContext context)? children;
  final int? itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  final Widget Function(BuildContext context, EdgeInsets padding)? body;

  @override
  Widget build(BuildContext context) => OmniPage(
    title: title,
    actions: actions,
    close: close,
    padded: false,
    bottom: state.isData ? bottom : null,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final pinned in [?search, ?filters])
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpace.screen,
              0,
              OmniSpace.screen,
              OmniSpace.sm,
            ),
            child: pinned,
          ),
        Expanded(child: Builder(builder: _body)),
      ],
    ),
  );

  Widget _body(BuildContext context) {
    final padding = omniBodyPadding(OmniInsets.bottom(context));
    if (state.isData && body != null) {
      return omniCustomBody(
        context,
        state: state,
        banners: banners,
        body: (context) => body!(context, padding),
      );
    }
    if (state.isData && itemBuilder != null) {
      final top = omniStateChildren(
        context,
        state: state,
        banners: banners,
        data: (_) => const [],
      );
      return ListView.builder(
        controller: controller,
        padding: padding,
        itemCount: top.length + itemCount!,
        itemBuilder: (context, i) =>
            i < top.length ? top[i] : itemBuilder!(context, i - top.length),
      );
    }
    return ListView(
      controller: controller,
      padding: padding,
      children: omniStateChildren(
        context,
        state: state,
        skeletonRows: skeletonRows,
        empty: empty,
        banners: banners,
        data: (context) => children!(context),
      ),
    );
  }
}
