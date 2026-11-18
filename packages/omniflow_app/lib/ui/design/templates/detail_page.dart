import 'package:flutter/material.dart';

import '../headers.dart';
import '../icons.dart';
import '../banner.dart';
import '../disclosure.dart';
import '../tokens.dart';
import 'load_state.dart';

/// T3, one thing (a device, sensor, tag, board, place, hub or run): the
/// large title is its name, header [actions] (star, more), [banners]
/// (offline, needs pairing), the [hero] card with its main control,
/// optional [tabs] chips, then the [children], then the collapsed
/// [sections] (Automations, Activity, More settings). While it loads it
/// shows the page skeleton, and when the thing is gone the [notFound]
/// state.
class DetailPage extends StatelessWidget {
  const DetailPage({
    super.key,
    required this.title,
    required List<Widget> Function(BuildContext context) this.children,
    this.actions = const [],
    this.banners = const [],
    this.hero,
    this.tabs,
    this.state = const OmniLoad.data(),
    this.notFound,
    this.bottom,
    this.controller,
    this.sections,
  }) : body = null;

  /// A detail page whose body under the hero is not a list (the TV tabs):
  /// [body] fills the rest, edge to edge, and pads itself.
  const DetailPage.custom({
    super.key,
    required this.title,
    required Widget Function(BuildContext context) this.body,
    this.actions = const [],
    this.banners = const [],
    this.hero,
    this.tabs,
    this.state = const OmniLoad.data(),
    this.notFound,
    this.bottom,
  }) : children = null,
       controller = null,
       sections = null;

  final String title;
  final List<Widget> actions;
  final List<Widget> banners;
  final Widget? hero;

  /// Chips under the hero that switch the body (the TV tabs).
  final Widget? tabs;

  /// [OmniLoadStatus.empty] means the thing is not here any more.
  final OmniLoad state;

  /// Defaults to [DetailPage.gone].
  final Widget? notFound;

  /// A decision bar (Reject and Approve on a review).
  final Widget? bottom;
  final ScrollController? controller;

  final List<Widget> Function(BuildContext context)? children;

  /// The secondary information, after [children]: each an
  /// [OmniDisclosure], closed until tapped, in the standard order
  /// (docs/ui/design-v2.md, The collapsed section). A [DetailPage.custom]
  /// body places its own.
  final List<OmniDisclosure> Function(BuildContext context)? sections;
  final Widget Function(BuildContext context)? body;

  /// The not-found state every detail page shares.
  static const gone = OmniEmptyState(
    icon: OmniIcons.info,
    title: 'This is not here any more',
    message: 'It may have been removed.',
  );

  List<Widget> _top() => [
    ?hero,
    if (hero != null) const SizedBox(height: OmniSpace.md),
    ?tabs,
    if (tabs != null) const SizedBox(height: OmniSpace.sm),
  ];

  List<Widget> _sections(BuildContext context) {
    final list = sections?.call(context) ?? const <OmniDisclosure>[];
    return [if (list.isNotEmpty) const SizedBox(height: OmniSpace.md), ...list];
  }

  @override
  Widget build(BuildContext context) => OmniPage(
    title: title,
    actions: state.isData ? actions : const [],
    padded: false,
    bottom: state.isData ? bottom : null,
    body: Builder(
      builder: (context) {
        if (state.isData && body != null) {
          return omniCustomBody(
            context,
            state: state,
            banners: banners,
            body: (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: OmniSpace.screenPadding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _top(),
                  ),
                ),
                Expanded(child: body!(context)),
              ],
            ),
          );
        }
        return ListView(
          controller: controller,
          padding: omniBodyPadding(OmniInsets.bottom(context)),
          children: omniStateChildren(
            context,
            state: state,
            skeleton: OmniSkeleton.page,
            skeletonRows: 3,
            empty: notFound ?? gone,
            banners: banners,
            fullPageError: true,
            data: (context) => [
              ..._top(),
              ...children!(context),
              ..._sections(context),
            ],
          ),
        );
      },
    ),
  );
}
