import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/appearance.dart';
import '../design/design.dart';

/// Settings, Appearance: OmniFlow's teal or the wallpaper's colours, and
/// pure black. The app recolours as soon as a choice is made, and the
/// choice stays on this phone.
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  /// How Settings sums the setting up.
  static String summary(Appearance a) => [
    switch (a.colours) {
      ColourSource.teal => 'Teal',
      ColourSource.wallpaper => 'Wallpaper colours',
    },
    if (a.pureBlack) 'pure black',
  ].join(' · ');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance =
        ref.watch(appearanceProvider).value ?? const Appearance();
    final wallpaper = appearance.colours == ColourSource.wallpaper
        ? ref.watch(wallpaperSchemeProvider)
        : null;
    final notifier = ref.read(appearanceProvider.notifier);
    void pick(ColourSource source) =>
        notifier.change(appearance.copyWith(colours: source));
    return OmniPage(
      title: 'Appearance',
      body: ListView(
        key: const ValueKey('appearance-list'),
        padding: EdgeInsets.only(bottom: OmniInsets.bottom(context)),
        children: [
          const OmniSectionHeader('Colours'),
          _Choice(
            key: const ValueKey('appearance-teal'),
            title: 'Teal',
            subtitle: 'The OmniFlow colours',
            swatch: OmniColors.accent,
            selected: appearance.colours == ColourSource.teal,
            onTap: () => pick(ColourSource.teal),
          ),
          _Choice(
            key: const ValueKey('appearance-wallpaper'),
            title: 'Wallpaper colours',
            subtitle: switch (wallpaper) {
              AsyncData(value: null) =>
                'This phone does not share its wallpaper colours, so '
                    'OmniFlow stays teal. It needs Android 12 or later.',
              _ => 'Takes its colours from your wallpaper',
            },
            swatch: wallpaper?.value?.primary,
            selected: appearance.colours == ColourSource.wallpaper,
            onTap: () => pick(ColourSource.wallpaper),
          ),
          const OmniSectionHeader('Background'),
          OmniListRow(
            key: const ValueKey('appearance-pure-black'),
            icon: OmniIcons.screen,
            title: 'Pure black',
            subtitle: 'Black screens, which use less power on OLED phones',
            divider: false,
            semanticLabel:
                'Pure black, ${appearance.pureBlack ? 'on' : 'off'}. '
                'Black screens, which use less power on OLED phones',
            onTap: () => notifier.change(
              appearance.copyWith(pureBlack: !appearance.pureBlack),
            ),
            trailing: ExcludeSemantics(
              child: Switch(
                key: const ValueKey('appearance-pure-black-switch'),
                value: appearance.pureBlack,
                onChanged: (v) =>
                    notifier.change(appearance.copyWith(pureBlack: v)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One colour choice: a round swatch, the words, and a tick when chosen.
class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.swatch,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: OmniListRow(
        title: title,
        subtitle: subtitle,
        subtitleLines: 3,
        semanticLabel: '$title. $subtitle',
        leading: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: swatch ?? palette.raised,
            border: Border.all(color: palette.line),
          ),
          child: swatch == null
              ? const Icon(OmniIcons.color, size: 18, color: OmniColors.text)
              : null,
        ),
        trailing: selected
            ? Icon(OmniIcons.check, color: palette.accent)
            : const SizedBox(width: 24),
        onTap: onTap,
      ),
    );
  }
}
