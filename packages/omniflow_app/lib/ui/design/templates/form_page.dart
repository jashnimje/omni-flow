import 'package:flutter/material.dart';

import '../action_bar.dart';
import '../buttons.dart';
import '../confirm.dart';
import '../headers.dart';
import '../tokens.dart';
import 'load_state.dart';

/// Asks before leaving while [dirty]: back, the chevron and system back
/// all stop at "Discard changes?" (red Discard). [onDiscard] runs before
/// the page pops, to clear the screen's own draft.
class OmniDiscardGuard extends StatelessWidget {
  const OmniDiscardGuard({
    super.key,
    required this.dirty,
    required this.child,
    this.what = 'this',
    this.onDiscard,
    this.isNew = false,
  });

  final bool dirty;
  final Widget child;

  /// Names what is lost: "What you changed in [what] is not saved".
  final String what;
  final VoidCallback? onDiscard;

  /// It was never saved, so there are no changes to lose, only [what]
  /// itself: "Discard [what]?".
  final bool isNew;

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !dirty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final ok = await confirm(
        context,
        title: isNew ? 'Discard $what?' : 'Discard changes?',
        body: isNew
            ? 'It has not been saved, so it will be lost.'
            : 'What you changed in $what is not saved and will be lost.',
        action: 'Discard',
        destructive: true,
      );
      if (!ok || !context.mounted) return;
      onDiscard?.call();
      Navigator.of(context).pop();
    },
    child: child,
  );
}

/// T4, create or edit one thing with fields: the large title, field
/// groups under section headers, and the sticky bottom bar with the
/// commit button ([commitLabel]) and an optional ghost secondary. While
/// [onCommit] is null the button is off and [missing] says why.
/// [saveError] is a failed save, shown at the top. [dirty] guards back.
///
/// [FormPage.instant] is the settings variant: the same body, no bottom
/// bar, each control applies at once.
class FormPage extends StatelessWidget {
  const FormPage({
    super.key,
    required this.title,
    required this.children,
    required this.onCommit,
    this.commitLabel = 'Save',
    this.commitKey,
    this.missing,
    this.secondaryLabel,
    this.onSecondary,
    this.saveError,
    this.dirty = false,
    this.discardWhat = 'this',
    this.discardNew = false,
    this.onDiscard,
    this.close = false,
    this.actions = const [],
    this.state = const OmniLoad.data(),
    this.banners = const [],
    this.controller,
  }) : instant = false;

  const FormPage.instant({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
    this.state = const OmniLoad.data(),
    this.banners = const [],
    this.controller,
  }) : instant = true,
       onCommit = null,
       commitLabel = '',
       commitKey = null,
       missing = null,
       secondaryLabel = null,
       onSecondary = null,
       saveError = null,
       dirty = false,
       discardWhat = '',
       discardNew = false,
       onDiscard = null,
       close = false;

  final String title;
  final List<Widget> Function(BuildContext context) children;
  final bool instant;
  final VoidCallback? onCommit;
  final String commitLabel;
  final Key? commitKey;
  final String? missing;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? saveError;
  final bool dirty;
  final String discardWhat;

  /// Whether it was never saved (see [OmniDiscardGuard.isNew]).
  final bool discardNew;
  final VoidCallback? onDiscard;
  final bool close;
  final List<Widget> actions;

  /// Loading an existing thing to edit. A new one starts as data.
  final OmniLoad state;
  final List<Widget> banners;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final bar = instant || !state.isData
        ? null
        : OmniActionBar(
            missing: onCommit == null ? missing : null,
            secondary: secondaryLabel == null
                ? null
                : OmniButton.ghost(
                    key: const ValueKey('template-secondary'),
                    label: secondaryLabel!,
                    onPressed: onSecondary,
                  ),
            primary: OmniButton(
              key: commitKey ?? const ValueKey('template-primary'),
              label: commitLabel,
              onPressed: onCommit,
            ),
          );
    return OmniDiscardGuard(
      dirty: dirty,
      what: discardWhat,
      isNew: discardNew,
      onDiscard: onDiscard,
      child: OmniPage(
        title: title,
        close: close,
        actions: actions,
        padded: false,
        bottom: bar,
        body: Builder(
          builder: (context) => ListView(
            controller: controller,
            padding: omniBodyPadding(OmniInsets.bottom(context)),
            children: omniStateChildren(
              context,
              state: state,
              skeleton: OmniSkeleton.page,
              skeletonRows: 3,
              fullPageError: true,
              banners: [
                if (saveError != null) OmniErrorBanner(saveError!),
                ...banners,
              ],
              data: children,
            ),
          ),
        ),
      ),
    );
  }
}
