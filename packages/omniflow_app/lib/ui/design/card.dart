import 'package:flutter/material.dart';

import 'tokens.dart';

/// A card: a title row with an optional [trailing] widget (a switch, a
/// value), then [child]. [highlighted] draws the accent border of the
/// search's "Do it" result.
class OmniCard extends StatelessWidget {
  const OmniCard({
    super.key,
    this.title,
    this.trailing,
    this.child,
    this.onTap,
    this.highlighted = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: OmniSpace.screen,
      vertical: OmniSpace.md,
    ),
    this.margin = const EdgeInsets.only(bottom: OmniSpace.gap),
  });

  final String? title;
  final Widget? trailing;
  final Widget? child;
  final VoidCallback? onTap;
  final bool highlighted;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(OmniRadii.card);
    final content = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || trailing != null)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 24),
              child: Row(
                children: [
                  Expanded(
                    child: title == null
                        ? const SizedBox.shrink()
                        : Text(title!, style: OmniText.bodyStrong),
                  ),
                  ?trailing,
                ],
              ),
            ),
          if ((title != null || trailing != null) && child != null)
            const SizedBox(height: 6),
          ?child,
        ],
      ),
    );
    final palette = OmniPalette.of(context);
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: OmniDepth.surface(
          color: palette.card,
          radius: radius,
          border: highlighted ? palette.accentLine : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: OmniSheen(
            child: onTap == null
                ? content
                : InkWell(onTap: onTap, child: content),
          ),
        ),
      ),
    );
  }
}

/// The faint light along the top of a card or tile ([OmniDepth.sheen]),
/// under [child].
class OmniSheen extends StatelessWidget {
  const OmniSheen({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(gradient: OmniDepth.sheen),
    child: child,
  );
}

enum HeroTone { accent, plain, problem }

/// The large card at the top of a device, sensor, tag or place page: a
/// [title] in 18 and a [subtitle] line, an optional [trailing] (the power
/// button) and [child] below (a chart). [centered] stacks a big [icon] over
/// centred text (a tag, a pairing step).
class OmniHeroCard extends StatelessWidget {
  const OmniHeroCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.child,
    this.footer,
    this.icon,
    this.centered = false,
    this.tone = HeroTone.accent,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? child;

  /// A second caption under [child] ("Last 24 h · low 21.0 · high 29.5").
  final String? footer;
  final IconData? icon;
  final bool centered;
  final HeroTone tone;

  @override
  Widget build(BuildContext context) {
    final accent = tone == HeroTone.accent;
    final palette = OmniPalette.of(context);
    final captionColor = switch (tone) {
      HeroTone.accent => palette.onAccentSoft,
      HeroTone.plain => OmniColors.muted,
      HeroTone.problem => OmniColors.bad,
    };
    final caption = OmniText.caption.copyWith(color: captionColor);
    final align = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final text = Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 44, color: OmniColors.text),
          const SizedBox(height: OmniSpace.sm),
        ],
        Text(
          title,
          style: OmniText.heroTitle,
          textAlign: centered ? TextAlign.center : null,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: caption,
            textAlign: centered ? TextAlign.center : null,
          ),
        ],
      ],
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: OmniSpace.md),
      padding: const EdgeInsets.all(OmniSpace.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(OmniRadii.hero),
        color: accent ? null : palette.card,
        gradient: accent
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette.heroTop, palette.heroBottom],
              )
            : null,
        border: Border.all(
          color: switch (tone) {
            HeroTone.accent => palette.accentLine,
            HeroTone.plain => OmniDepth.edgeOn(palette.card),
            HeroTone.problem => OmniColors.badLine,
          },
        ),
        boxShadow: OmniDepth.shadow,
      ),
      child: Column(
        crossAxisAlignment: align,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing == null)
            text
          else
            Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: OmniSpace.md),
                trailing!,
              ],
            ),
          if (child != null) ...[const SizedBox(height: OmniSpace.sm), child!],
          if (footer != null) ...[
            const SizedBox(height: OmniSpace.xs),
            Text(footer!, style: caption),
          ],
        ],
      ),
    );
  }
}
