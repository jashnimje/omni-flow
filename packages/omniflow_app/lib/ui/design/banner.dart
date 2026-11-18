import 'package:flutter/material.dart';

import 'buttons.dart';
import 'icons.dart';
import 'tokens.dart';

enum BannerKind { info, warning, error }

/// A banner in the flow of a screen: info (blue, "Nothing was sent"),
/// warning (amber, a review waiting) or error (red, a device not
/// answering), with an optional action and close button. Warnings and
/// errors are announced when they appear.
class OmniBanner extends StatelessWidget {
  const OmniBanner({
    super.key,
    required this.kind,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.onClose,
    this.icon,
    this.showIcon = true,
  });

  const OmniBanner.info(
    this.message, {
    super.key,
    this.actionLabel,
    this.onAction,
    this.onClose,
    this.icon,
    this.showIcon = false,
  }) : kind = BannerKind.info;

  const OmniBanner.warning(
    this.message, {
    super.key,
    this.actionLabel,
    this.onAction,
    this.onClose,
    this.icon,
    this.showIcon = true,
  }) : kind = BannerKind.warning;

  const OmniBanner.error(
    this.message, {
    super.key,
    this.actionLabel,
    this.onAction,
    this.onClose,
    this.icon,
    this.showIcon = true,
  }) : kind = BannerKind.error;

  final BannerKind kind;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onClose;
  final IconData? icon;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final p = OmniPalette.of(context);
    final (bg, fg, glyph) = switch (kind) {
      BannerKind.info => (p.infoSoft, p.info, OmniIcons.info),
      BannerKind.warning => (p.warnSoft, p.warn, OmniIcons.warning),
      BannerKind.error => (p.badSoft, p.bad, OmniIcons.error),
    };
    return Semantics(
      liveRegion: kind != BannerKind.info,
      container: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: OmniSpace.md),
        constraints: const BoxConstraints(minHeight: OmniSpace.row),
        padding: EdgeInsets.fromLTRB(
          OmniSpace.lg,
          onClose == null ? OmniSpace.md : 0,
          onClose == null ? OmniSpace.lg : 0,
          actionLabel == null ? OmniSpace.md : 0,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(OmniRadii.banner),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    // Centres the first line on the 48 dp close button.
                    padding: EdgeInsets.only(top: onClose == null ? 0 : 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showIcon) ...[
                          Icon(icon ?? glyph, size: 20, color: fg),
                          const SizedBox(width: OmniSpace.sm),
                        ],
                        Expanded(
                          child: Text(
                            message,
                            style: OmniText.caption.copyWith(
                              color: fg,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (onClose != null)
                  OmniIconAction(
                    icon: OmniIcons.close,
                    label: 'Dismiss',
                    color: fg,
                    onPressed: onClose,
                  ),
              ],
            ),
            if (actionLabel != null)
              Padding(
                padding: EdgeInsets.only(left: showIcon ? 20 : 0),
                child: TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: fg,
                    minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: OmniText.label.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Text(actionLabel!),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What a screen shows when it has nothing: a big muted icon, a title, a
/// line on why, and an [action] (an Add button). [compact] is the "nothing
/// matches" of a filtered list or a sheet: less padding and no icon.
class OmniEmptyState extends StatelessWidget {
  const OmniEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.padding,
    this.iconColor,
    this.large = false,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  /// Defaults to 40 above and below, or 16 when [compact].
  final EdgeInsetsGeometry? padding;

  /// The palette's muted grey by default.
  final Color? iconColor;

  /// A welcome screen's title at screen-title size (22) instead of 16.
  final bool large;

  /// Smaller padding and no icon, for a filter that matches nothing.
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding:
        padding ??
        EdgeInsets.symmetric(
          horizontal: 18,
          vertical: compact ? OmniSpace.lg : OmniSpace.xxl,
        ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact) ...[
          Icon(
            icon,
            size: 48,
            color: iconColor ?? OmniPalette.of(context).muted,
          ),
          const SizedBox(height: OmniSpace.sm),
        ],
        Semantics(
          header: !compact,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: large
                ? OmniText.screenTitle.copyWith(fontWeight: FontWeight.w700)
                : OmniText.section,
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: OmniSpace.xs),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: OmniText.body.copyWith(color: OmniPalette.of(context).muted),
          ),
        ],
        if (action != null) ...[const SizedBox(height: OmniSpace.lg), action!],
      ],
    ),
  );
}

/// A page that could not open at all: the error icon, what happened, and
/// Try again. A page that has something to show keeps it and puts an
/// [OmniBanner.error] above it instead.
class OmniErrorState extends StatelessWidget {
  const OmniErrorState({
    super.key,
    this.title = 'This did not open',
    this.message,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    child: OmniEmptyState(
      icon: OmniIcons.error,
      iconColor: OmniPalette.of(context).bad,
      title: title,
      message: message,
      action: onRetry == null
          ? null
          : OmniButton.ghost(
              key: const ValueKey('omni-retry'),
              label: retryLabel,
              icon: OmniIcons.retry,
              expand: false,
              onPressed: onRetry,
            ),
    ),
  );
}
