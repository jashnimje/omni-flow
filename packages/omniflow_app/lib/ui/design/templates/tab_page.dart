import 'package:flutter/material.dart';

import '../headers.dart';
import '../tokens.dart';
import 'load_state.dart';

/// T1, the root of a tab: the large collapsing title, header [actions],
/// the [house] chip, pinned [filters], then the sectioned scroll body.
/// The body ends clear of the shell's floating button ([fab]) and draws
/// the skeleton, error and [empty] state from [state] itself.
class TabPage extends StatelessWidget {
  const TabPage({
    super.key,
    required this.title,
    required List<Widget> Function(BuildContext context) this.children,
    this.subtitle,
    this.actions = const [],
    this.house,
    this.filters,
    this.heroTitle = false,
    this.fab = true,
    this.state = const OmniLoad.data(),
    this.skeleton = OmniSkeleton.rows,
    this.empty,
    this.banners = const [],
    this.controller,
  }) : body = null;

  /// A tab whose body is not a plain list (Home's grid). [body] gets the
  /// padding the template would give, FAB clearance included; it shows
  /// only in the data case.
  const TabPage.custom({
    super.key,
    required this.title,
    required Widget Function(BuildContext context, EdgeInsets padding)
    this.body,
    this.subtitle,
    this.actions = const [],
    this.house,
    this.filters,
    this.heroTitle = false,
    this.fab = true,
    this.state = const OmniLoad.data(),
    this.skeleton = OmniSkeleton.rows,
    this.empty,
    this.banners = const [],
    this.controller,
  }) : children = null;

  final String title;
  final String? subtitle;

  /// Search, help, notifications. Search opens the global Search page.
  final List<Widget> actions;
  final Widget? house;
  final Widget? filters;

  /// The body opens with its own big title (Home's hero).
  final bool heroTitle;

  /// The shell draws a floating button on this tab, so the last row
  /// clears it. False for Settings.
  final bool fab;
  final OmniLoad state;
  final OmniSkeleton skeleton;

  /// Shown for [OmniLoadStatus.empty], with the tab's primary action.
  final Widget? empty;

  /// Notices above the data, under the error banner.
  final List<Widget> banners;
  final ScrollController? controller;

  final List<Widget> Function(BuildContext context)? children;
  final Widget Function(BuildContext context, EdgeInsets padding)? body;

  @override
  Widget build(BuildContext context) => OmniTabPage(
    title: title,
    subtitle: subtitle,
    actions: actions,
    heroTitle: heroTitle,
    house: house,
    filters: filters,
    padded: false,
    body: Builder(
      builder: (context) {
        final padding = omniBodyPadding(
          fab ? OmniInsets.fabClearance(context) : OmniInsets.bottom(context),
        );
        if (body != null && state.isData) {
          return omniCustomBody(
            context,
            state: state,
            banners: banners,
            body: (context) => body!(context, padding),
          );
        }
        return ListView(
          controller: controller,
          padding: padding,
          children: omniStateChildren(
            context,
            state: state,
            skeleton: skeleton,
            empty: empty,
            banners: banners,
            fullPageError: true,
            data: (context) => children!(context),
          ),
        );
      },
    ),
  );
}
