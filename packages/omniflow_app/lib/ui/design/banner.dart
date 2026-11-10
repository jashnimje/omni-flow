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
    final (bg, fg, glyph) = switch (kind) {
      BannerKind.info => (OmniColors.infoSoft, OmniColors.info, OmniIcons.info),
      BannerKind.warning => (
        OmniColors.warnSoft,
        OmniColors.warn,
        OmniIcons.warning,
      ),
      BannerKind.error => (OmniColors.badSoft, OmniColors.bad, OmniIcons.error),
    };
    return Semantics(
      liveRegion: kind != BannerKind.info,
      container: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: OmniSpace.gap),
        padding: EdgeInsets.fromLTRB(
          12,
          onClose == null ? 10 : 0,
          onClose == null ? 12 : 0,
          actionLabel == null ? 10 : 0,
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
                    padding: EdgeInsets.only(top: onClose == null ? 0 : 15),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showIcon) ...[
                          Icon(icon ?? glyph, size: 16, color: fg),
                          const SizedBox(width: OmniSpace.sm),
                        ],
                        Expanded(
                          child: Text(
                            message,
                            style: TextStyle(
                              fontSize: 12,
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
                padding: EdgeInsets.only(left: showIcon ? 16 : 0),
                child: TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: fg,
                    minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(
                      fontSize: 12,
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
/// line on why, and an [action] (an Add button).
class OmniEmptyState extends StatelessWidget {
  const OmniEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 40),
    this.iconColor = OmniColors.muted,
    this.large = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  final Color iconColor;

  /// A welcome screen's title at screen-title size (22/650) instead of 17/600.
  final bool large;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: iconColor),
        const SizedBox(height: OmniSpace.sm),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: large ? 22 : 17,
            fontWeight: large ? FontWeight.w700 : FontWeight.w600,
            color: OmniColors.text,
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: OmniColors.muted),
          ),
        ],
        if (action != null) ...[const SizedBox(height: OmniSpace.lg), action!],
      ],
    ),
  );
}
