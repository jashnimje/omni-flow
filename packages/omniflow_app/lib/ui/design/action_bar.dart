import 'package:flutter/material.dart';

import 'tokens.dart';

/// The commit row pinned at the bottom of a form, editor, step or sheet:
/// a [leading] text button (Back), a ghost [secondary] (Skip, Test run)
/// and the [primary] button (Save, Done, Add). [missing] says why the
/// primary is off, above the row. With large text the buttons stack, the
/// primary first, so no label is cut.
class OmniActionBar extends StatelessWidget {
  const OmniActionBar({
    super.key,
    this.primary,
    this.secondary,
    this.leading,
    this.missing,
  });

  final Widget? primary;
  final Widget? secondary;
  final Widget? leading;
  final String? missing;

  /// Above this text scale the buttons stack instead of sharing a row.
  static const stackAbove = 1.3;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final stacked = scale > stackAbove;
    final order = [?primary, ?secondary, ?leading];
    final buttons = stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < order.length; i++) ...[
                if (i > 0) const SizedBox(height: OmniSpace.sm),
                order[i],
              ],
            ],
          )
        : Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: OmniSpace.sm),
              ],
              if (secondary != null) Expanded(child: secondary!),
              if (secondary != null && primary != null)
                const SizedBox(width: OmniSpace.sm),
              if (primary != null) Expanded(child: primary!),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (missing != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.sm),
            child: Semantics(
              liveRegion: true,
              child: Text(
                missing!,
                key: const ValueKey('action-bar-missing'),
                textAlign: TextAlign.center,
                style: OmniText.caption,
              ),
            ),
          ),
        buttons,
      ],
    );
  }
}
