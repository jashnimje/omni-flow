import 'package:flutter/material.dart';

import 'tokens.dart';

/// Opens [builder] as a bottom sheet over the whole app (above the tab
/// bar), dimming what is behind it. It slides in over 250 ms, or appears at
/// once under reduced motion.
Future<T?> showOmniSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  isDismissible: dismissible,
  enableDrag: dismissible,
  useSafeArea: true,
  backgroundColor: OmniPalette.of(context).sheet,
  barrierColor: OmniColors.scrim,
  showDragHandle: false,
  sheetAnimationStyle: OmniMotion.reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(duration: OmniMotion.slow),
  shape: RoundedRectangleBorder(
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(OmniRadii.sheet),
    ),
    side: BorderSide(color: OmniPalette.of(context).line),
  ),
  builder: builder,
);

/// The body of a sheet: the grab handle, a header ([title], [subtitle] and
/// a [trailing] widget such as the power switch), then [children], then
/// the pinned [actions]. It scrolls when taller than the screen and keeps
/// clear of the keyboard and of the system navigation bar.
class OmniSheet extends StatelessWidget {
  const OmniSheet({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    this.pinned,
    this.actions,
    required this.children,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;

  /// Under the title and outside the scroll, so it stays in view: a
  /// picker's search field.
  final Widget? pinned;

  /// Under the scrolling [children] and outside the scroll: an
  /// [OmniActionBar] with the sheet's commit button.
  final Widget? actions;
  final List<Widget> children;

  /// The space under a sheet's last widget: the gesture or 3-button
  /// navigation bar (the app draws edge to edge and the sheet's safe area
  /// leaves the bottom open), then 16.
  static double bottomPadding(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + OmniSpace.lg;

  @override
  Widget build(BuildContext context) {
    final bottom = bottomPadding(context);
    final hasHeader = title != null || trailing != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpace.screen,
              OmniSpace.md,
              OmniSpace.screen,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const OmniSheetHandle(),
                if (hasHeader)
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (title != null)
                              Semantics(
                                header: true,
                                child: Text(
                                  title!,
                                  style: OmniText.titleMedium,
                                ),
                              ),
                            if (subtitle != null)
                              Text(subtitle!, style: OmniText.caption),
                          ],
                        ),
                      ),
                      ?trailing,
                    ],
                  ),
                if (hasHeader) const SizedBox(height: OmniSpace.sm),
                if (pinned != null) ...[
                  pinned!,
                  const SizedBox(height: OmniSpace.sm),
                ],
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                OmniSpace.screen,
                0,
                OmniSpace.screen,
                actions == null ? bottom : OmniSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
          if (actions != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                OmniSpace.screen,
                OmniSpace.sm,
                OmniSpace.screen,
                bottom,
              ),
              child: actions,
            ),
        ],
      ),
    );
  }
}

/// The grab handle at the top of a sheet, in the palette's line colour.
/// Sheets that draw their own body (`PinSheet`, `LinkSheet`) use it too.
class OmniSheetHandle extends StatelessWidget {
  const OmniSheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      key: const ValueKey('omni-sheet-handle'),
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(bottom: OmniSpace.md),
      decoration: BoxDecoration(
        color: OmniPalette.of(context).line,
        borderRadius: BorderRadius.circular(OmniRadii.handle),
      ),
    ),
  );
}
