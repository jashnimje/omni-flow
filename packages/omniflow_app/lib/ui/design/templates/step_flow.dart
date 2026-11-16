import 'package:flutter/material.dart';

import '../action_bar.dart';
import '../buttons.dart';
import '../headers.dart';
import '../icons.dart';
import '../progress.dart';
import '../tokens.dart';
import 'load_state.dart';

/// T8, a guided setup with ordered steps: the close cross, [title] ("Set
/// up X"), the step bar under the bar ([current] of [count], 1-based),
/// the step [heading] and [why] line, the step body, and the sticky bar
/// with the step's [primaryLabel], Skip as ghost ([onSkip]) and Back as
/// the leading text button ([onBack]). The done step passes
/// `primaryLabel: 'Done'` and no skip or back. [onHelp] adds the "what to
/// try" help button to the header.
class StepFlow extends StatelessWidget {
  const StepFlow({
    super.key,
    required this.title,
    required this.count,
    required this.current,
    required this.children,
    required this.onPrimary,
    this.heading,
    this.why,
    this.primaryLabel = 'Next',
    this.primaryKey,
    this.missing,
    this.onSkip,
    this.skipLabel = 'Skip',
    this.onBack,
    this.backLabel = 'Back',
    this.onHelp,
    this.close = true,
    this.actions = const [],
    this.state = const OmniLoad.data(),
    this.banners = const [],
  });

  final String title;
  final int count;

  /// 1-based: the step the user is on.
  final int current;
  final List<Widget> Function(BuildContext context) children;
  final String? heading;
  final String? why;
  final String primaryLabel;
  final VoidCallback? onPrimary;
  final Key? primaryKey;
  final String? missing;
  final VoidCallback? onSkip;
  final String skipLabel;
  final VoidCallback? onBack;
  final String backLabel;
  final VoidCallback? onHelp;

  /// A cross that leaves the flow (it is entered modally). False shows
  /// the back chevron.
  final bool close;
  final List<Widget> actions;

  /// The flow's progress loading, or a step that failed (error banner
  /// with Try again).
  final OmniLoad state;
  final List<Widget> banners;

  @override
  Widget build(BuildContext context) => OmniPage(
    title: title,
    close: close,
    padded: false,
    actions: [
      ...actions,
      if (onHelp != null)
        OmniIconAction(
          key: const ValueKey('step-help'),
          icon: OmniIcons.about,
          label: 'Help with this step',
          onPressed: onHelp,
        ),
    ],
    bottom: state.isLoading
        ? null
        : OmniActionBar(
            missing: onPrimary == null ? missing : null,
            leading: onBack == null
                ? null
                : TextButton(
                    key: const ValueKey('step-back'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(
                        OmniSpace.target,
                        OmniSpace.target,
                      ),
                    ),
                    onPressed: onBack,
                    child: Text(backLabel),
                  ),
            secondary: onSkip == null
                ? null
                : OmniButton.ghost(
                    key: const ValueKey('step-skip'),
                    label: skipLabel,
                    onPressed: onSkip,
                  ),
            primary: OmniButton(
              key: primaryKey ?? const ValueKey('step-primary'),
              label: primaryLabel,
              onPressed: onPrimary,
            ),
          ),
    body: Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpace.screen,
              0,
              OmniSpace.screen,
              OmniSpace.md,
            ),
            child: OmniStepBar(count: count, current: current),
          ),
          Expanded(
            child: ListView(
              padding: omniBodyPadding(OmniInsets.bottom(context)),
              children: omniStateChildren(
                context,
                state: state,
                banners: banners,
                data: (context) => [
                  if (heading != null)
                    Semantics(
                      header: true,
                      child: Text(heading!, style: OmniText.titleMedium),
                    ),
                  if (why != null)
                    Padding(
                      padding: const EdgeInsets.only(top: OmniSpace.xs),
                      child: Text(why!, style: OmniText.caption),
                    ),
                  if (heading != null || why != null)
                    const SizedBox(height: OmniSpace.lg),
                  ...children(context),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
