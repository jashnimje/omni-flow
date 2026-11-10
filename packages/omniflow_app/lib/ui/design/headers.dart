import 'package:flutter/material.dart';

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
          ? const EdgeInsets.fromLTRB(2, 0, 0, 0)
          : const EdgeInsets.fromLTRB(2, 12, 2, 8),
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
                color: OmniColors.accent,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (hasAction)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: OmniColors.accent,
                minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                padding: const EdgeInsets.symmetric(horizontal: 8),
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

/// The title of a tab's root screen: 22 type, with icon [actions] on the
/// right (search, notifications) and an optional [subtitle] line.
class OmniScreenTitle extends StatelessWidget {
  const OmniScreenTitle(
    this.title, {
    super.key,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 6, 0, 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: OmniText.screenTitle),
              ),
            ),
            ...actions,
          ],
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(subtitle!, style: OmniText.caption),
          ),
      ],
    ),
  );
}

/// A pushed page: the back chevron, a 17 title, icon [actions], then
/// [body] with the screen padding. [close] shows a cross instead of the
/// chevron (the Add flow).
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
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;

  /// Pinned under the body (Test run and Save, a selection bar).
  final Widget? bottom;
  final bool close;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: canPop ? 0 : OmniSpace.screen,
        leading: canPop
            ? OmniIconAction(
                icon: close ? OmniIcons.close : OmniIcons.back,
                label: close ? 'Close' : 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: Text(title, style: OmniText.pageTitle),
        actions: [...actions, const SizedBox(width: 4)],
      ),
      floatingActionButton: floatingActionButton,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: padded
                  ? Padding(padding: OmniSpace.screenPadding, child: body)
                  : body,
            ),
            if (bottom != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: bottom,
              ),
          ],
        ),
      ),
    );
  }
}

/// The root screen of a tab: the safe area, the screen padding, an
/// [OmniScreenTitle], then [body] filling the rest. [padded] false leaves
/// the body edge to edge (a list that pads itself).
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
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: OmniSpace.screenPadding,
            child: OmniScreenTitle(title, subtitle: subtitle, actions: actions),
          ),
          Expanded(
            child: padded
                ? Padding(padding: OmniSpace.screenPadding, child: body)
                : body,
          ),
        ],
      ),
    ),
  );
}
