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
/// a [trailing] widget such as the power switch), then [children]. It
/// scrolls when taller than the screen and keeps clear of the keyboard.
class OmniSheet extends StatelessWidget {
  const OmniSheet({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.children,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OmniSpace.screen,
        OmniSpace.md,
        OmniSpace.screen,
        OmniSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: OmniSpace.md),
              decoration: BoxDecoration(
                color: OmniColors.line,
                borderRadius: BorderRadius.circular(OmniRadii.handle),
              ),
            ),
          ),
          if (title != null || trailing != null)
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title != null)
                        Semantics(
                          header: true,
                          child: Text(title!, style: OmniText.titleMedium),
                        ),
                      if (subtitle != null)
                        Text(subtitle!, style: OmniText.caption),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          if (title != null || trailing != null)
            const SizedBox(height: OmniSpace.sm),
          ...children,
        ],
      ),
    ),
  );
}
