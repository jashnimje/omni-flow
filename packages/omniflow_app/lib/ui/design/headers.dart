import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'buttons.dart';
import 'icons.dart';
import 'tokens.dart';

/// A section heading: the title on the left, and on the right an accent
/// action ("Edit", "All", "＋ Add pin") or an accent [trailingText] (a count).
class OmniSectionHeader extends StatelessWidget {
  const OmniSectionHeader(
    this.title, {
    super.key,
    this.actionLabel,
    this.onAction,
    this.trailingText,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final hasAction = actionLabel != null;
    return Padding(
      // The 48 dp action button is taller than the text, so it takes the
      // vertical padding instead of pushing the next section down.
      padding: hasAction
          ? const EdgeInsetsDirectional.only(start: 2)
          : const EdgeInsetsDirectional.fromSTEB(
              2,
              OmniSpace.md,
              2,
              OmniSpace.sm,
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: OmniText.section),
            ),
          ),
          if (trailingText != null)
            Text(
              trailingText!,
              style: OmniText.caption.copyWith(
                color: OmniPalette.of(context).accent,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (hasAction)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: OmniPalette.of(context).accent,
                minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                padding: const EdgeInsets.symmetric(horizontal: OmniSpace.sm),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// The title of a tab's root screen: 28 type that shrinks to 22 as
/// [collapse] goes from 0 to 1 (the page scrolling), with icon [actions]
/// on the right (search, notifications) and an optional [subtitle] line.
class OmniScreenTitle extends StatelessWidget {
  const OmniScreenTitle(
    this.title, {
    super.key,
    this.subtitle,
    this.actions = const [],
    this.collapse = 0,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final double collapse;

  @override
  Widget build(BuildContext context) {
    final t = collapse.clamp(0.0, 1.0);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        2,
        OmniSpace.sm * (1 - t) + 2,
        0,
        2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle.lerp(
                      OmniText.largeTitle,
                      OmniText.screenTitle,
                      t,
                    ),
                  ),
                ),
              ),
              ...actions,
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(bottom: OmniSpace.gap),
              child: Text(subtitle!, style: OmniText.caption),
            ),
        ],
      ),
    );
  }
}

/// How far the page's main list scrolls before its title is fully small.
const _collapseDistance = 56.0;

/// Turns the vertical scrolling of the list inside [child] into a 0 to 1
/// [collapse] for a large title.
class _CollapseOnScroll extends StatefulWidget {
  const _CollapseOnScroll({required this.builder, required this.child});

  final Widget Function(BuildContext context, double collapse) builder;
  final Widget child;

  @override
  State<_CollapseOnScroll> createState() => _CollapseOnScrollState();
}

class _CollapseOnScrollState extends State<_CollapseOnScroll> {
  final _collapse = ValueNotifier(0.0);

  @override
  void dispose() {
    _collapse.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      final v = (n.metrics.pixels / _collapseDistance).clamp(0.0, 1.0);
      if ((v - _collapse.value).abs() > 0.001) _collapse.value = v;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ValueListenableBuilder<double>(
        valueListenable: _collapse,
        builder: (context, value, _) => widget.builder(context, value),
      ),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: widget.child,
        ),
      ),
    ],
  );
}

/// A pushed page: the back chevron and icon [actions] in a bar, the
/// title large under it that slides into the bar as [body] scrolls, then
/// [body] with the screen padding. [close] shows a cross instead of the
/// chevron (the Add flow). It draws edge to edge, clear of the system
/// bars.
class OmniPage extends StatelessWidget {
  const OmniPage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.floatingActionButton,
    this.bottom,
    this.close = false,
    this.padded = true,
    this.large = true,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;

  /// Pinned under the body (Test run and Save, a selection bar).
  final Widget? bottom;
  final bool close;
  final bool padded;

  /// False keeps the title small in the bar from the start.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    final leading = canPop
        ? OmniIconAction(
            icon: close ? OmniIcons.close : OmniIcons.back,
            label: close ? 'Close' : 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          )
        : null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: omniSystemBars,
      child: Scaffold(
        floatingActionButton: floatingActionButton,
        body: SafeArea(
          child: _CollapseOnScroll(
            builder: (context, collapse) => _PageBar(
              title: title,
              leading: leading,
              actions: actions,
              collapse: large ? collapse : 1,
            ),
            child: Column(
              children: [
                Expanded(
                  child: padded
                      ? Padding(padding: OmniSpace.screenPadding, child: body)
                      : body,
                ),
                if (bottom != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      OmniSpace.screen,
                      OmniSpace.sm,
                      OmniSpace.screen,
                      OmniSpace.md,
                    ),
                    child: bottom,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A page's bar. Open, the title sits large under the back button; as
/// [collapse] reaches 1 it shrinks and moves up beside it.
class _PageBar extends StatelessWidget {
  const _PageBar({
    required this.title,
    required this.leading,
    required this.actions,
    required this.collapse,
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final double collapse;

  @override
  Widget build(BuildContext context) {
    final t = collapse.clamp(0.0, 1.0);
    final scaler = MediaQuery.textScalerOf(context);
    final style = TextStyle.lerp(OmniText.largeTitle, OmniText.pageTitle, t)!;
    final small = scaler.scale(OmniText.pageTitle.fontSize!) * 1.3;
    final big = scaler.scale(OmniText.largeTitle.fontSize!) * 1.3;
    final bar = small + OmniSpace.lg > 56 ? small + OmniSpace.lg : 56.0;
    final height = bar + (big + OmniSpace.sm) * (1 - t);
    return SizedBox(
      height: height,
      child: CustomMultiChildLayout(
        delegate: _PageBarLayout(collapse: t, bar: bar),
        children: [
          if (leading != null) LayoutId(id: _Slot.leading, child: leading!),
          LayoutId(
            id: _Slot.actions,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...actions,
                const SizedBox(width: OmniSpace.xs),
              ],
            ),
          ),
          LayoutId(
            id: _Slot.title,
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Slot { leading, actions, title }

class _PageBarLayout extends MultiChildLayoutDelegate {
  _PageBarLayout({required this.collapse, required this.bar});

  final double collapse;
  final double bar;

  @override
  void performLayout(Size size) {
    var leadingWidth = 0.0;
    if (hasChild(_Slot.leading)) {
      final s = layoutChild(_Slot.leading, BoxConstraints.loose(size));
      positionChild(_Slot.leading, Offset(0, (bar - s.height) / 2));
      leadingWidth = s.width;
    }
    final actions = layoutChild(_Slot.actions, BoxConstraints.loose(size));
    positionChild(
      _Slot.actions,
      Offset(size.width - actions.width, (bar - actions.height) / 2),
    );
    double lerp(double a, double b) => a + (b - a) * collapse;
    final left = lerp(
      OmniSpace.screen + 2,
      leadingWidth == 0 ? OmniSpace.screen + 2 : leadingWidth,
    );
    final right = lerp(OmniSpace.screen, actions.width + OmniSpace.xs);
    final title = layoutChild(
      _Slot.title,
      BoxConstraints(
        maxWidth: (size.width - left - right).clamp(0, size.width),
      ),
    );
    final top = lerp(bar, (bar - title.height) / 2);
    positionChild(_Slot.title, Offset(left, top));
  }

  @override
  bool shouldRelayout(_PageBarLayout old) =>
      old.collapse != collapse || old.bar != bar;
}

/// The root screen of a tab: edge to edge under the status bar, the
/// screen padding, an [OmniScreenTitle] that shrinks as [body] scrolls,
/// then [body] filling the rest. [padded] false leaves the body edge to
/// edge (a list that pads itself).
class OmniTabPage extends StatelessWidget {
  const OmniTabPage({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.padded = true,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget body;
  final bool padded;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: omniSystemBars,
    child: Scaffold(
      body: SafeArea(
        bottom: false,
        child: _CollapseOnScroll(
          builder: (context, collapse) => Padding(
            padding: OmniSpace.screenPadding,
            child: OmniScreenTitle(
              title,
              subtitle: subtitle,
              actions: actions,
              collapse: collapse,
            ),
          ),
          child: padded
              ? Padding(padding: OmniSpace.screenPadding, child: body)
              : body,
        ),
      ),
    ),
  );
}
