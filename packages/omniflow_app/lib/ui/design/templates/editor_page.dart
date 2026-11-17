import 'package:flutter/material.dart';

import '../action_bar.dart';
import '../buttons.dart';
import '../headers.dart';
import '../tokens.dart';
import 'form_page.dart';
import 'load_state.dart';

/// T5, the rule editor and the scene editor: a small title from the start
/// so the canvas gets the height, a more menu in [actions], the [views]
/// switch (Sentence and Diagram) pinned under the bar, [banners], then
/// either the padded [children] list or an edge to edge [canvas]. The
/// sticky bar holds [secondaryLabel] (Test run) and [primaryLabel]
/// (Save); [missing] says why Save is off. [dirty] guards back.
///
/// [title] is the rule's name or "Automation" while it loads, never its id.
class EditorPage extends StatelessWidget {
  const EditorPage({
    super.key,
    required this.title,
    required this.onPrimary,
    this.children,
    this.canvas,
    this.views,
    this.actions = const [],
    this.banners = const [],
    this.primaryLabel = 'Save',
    this.primaryKey,
    this.secondaryLabel,
    this.onSecondary,
    this.secondaryKey,
    this.missing,
    this.dirty = false,
    this.discardWhat = 'this automation',
    this.discardNew = false,
    this.onDiscard,
    this.state = const OmniLoad.data(),
    this.empty,
  }) : assert(
         (children == null) != (canvas == null),
         'Give an EditorPage either children or a canvas',
       );

  final String title;

  /// The sentence view: padded rows in a list.
  final List<Widget> Function(BuildContext context)? children;

  /// The diagram view: fills the body edge to edge and pads itself.
  final WidgetBuilder? canvas;
  final Widget? views;
  final List<Widget> actions;
  final List<Widget> banners;
  final String primaryLabel;
  final VoidCallback? onPrimary;
  final Key? primaryKey;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Key? secondaryKey;
  final String? missing;
  final bool dirty;
  final String discardWhat;

  /// Whether it was never saved (see [OmniDiscardGuard.isNew]).
  final bool discardNew;
  final VoidCallback? onDiscard;
  final OmniLoad state;

  /// For [OmniLoadStatus.empty]: "This is not a rule" and the like.
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    return OmniDiscardGuard(
      dirty: dirty,
      what: discardWhat,
      isNew: discardNew,
      onDiscard: onDiscard,
      child: OmniPage(
        title: title,
        large: false,
        padded: false,
        actions: ready ? actions : const [],
        bottom: ready
            ? OmniActionBar(
                missing: onPrimary == null ? missing : null,
                secondary: secondaryLabel == null
                    ? null
                    : OmniButton.ghost(
                        key:
                            secondaryKey ??
                            const ValueKey('template-secondary'),
                        label: secondaryLabel!,
                        onPressed: onSecondary,
                      ),
                primary: OmniButton(
                  key: primaryKey ?? const ValueKey('template-primary'),
                  label: primaryLabel,
                  onPressed: onPrimary,
                ),
              )
            : null,
        body: Builder(builder: _body),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final pinnedViews = ready && views != null
        ? Padding(
            padding: const EdgeInsets.fromLTRB(
              OmniSpace.screen,
              0,
              OmniSpace.screen,
              OmniSpace.sm,
            ),
            child: views,
          )
        : null;
    final Widget main;
    if (ready && canvas != null) {
      main = omniCustomBody(
        context,
        state: state,
        banners: banners,
        body: canvas!,
      );
    } else {
      main = ListView(
        padding: omniBodyPadding(OmniInsets.bottom(context)),
        children: omniStateChildren(
          context,
          state: state,
          skeleton: OmniSkeleton.page,
          skeletonRows: 3,
          empty: empty,
          banners: banners,
          fullPageError: true,
          data: (context) => children!(context),
        ),
      );
    }
    if (pinnedViews == null) return main;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        pinnedViews,
        Expanded(child: main),
      ],
    );
  }

  bool get ready => state.isData;
}
