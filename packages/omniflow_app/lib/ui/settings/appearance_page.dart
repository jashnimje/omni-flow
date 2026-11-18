import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/appearance.dart';
import '../design/design.dart';

/// Settings, Appearance: light, dark or as the phone is set, OmniFlow's
/// teal or the wallpaper's colours, and pure black. The app recolours as
/// soon as a choice is made, and the choice stays on this phone.
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  /// How Settings sums the setting up.
  static String summary(Appearance a) => [
    ?switch (a.theme) {
      ThemeChoice.system => null,
      ThemeChoice.light => 'Light',
      ThemeChoice.dark => 'Dark',
    },
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
    Widget theme(ThemeChoice choice, IconData icon, String title, String sub) =>
        _Choice(
          key: ValueKey('appearance-theme-${choice.name}'),
          title: title,
          subtitle: sub,
          icon: icon,
          selected: appearance.theme == choice,
          onTap: () => notifier.change(appearance.copyWith(theme: choice)),
        );
    return FormPage.instant(
      title: 'Appearance',
      children: (context) => [
        const OmniSectionHeader('Theme'),
        theme(
          ThemeChoice.system,
          OmniIcons.themeSystem,
          'System',
          'Light or dark, as your phone is set',
        ),
        theme(
          ThemeChoice.light,
          OmniIcons.themeLight,
          'Light',
          'Light screens all the time',
        ),
        theme(
          ThemeChoice.dark,
          OmniIcons.themeDark,
          'Dark',
          'Dark screens all the time',
        ),
        const OmniSectionHeader('Colours'),
        _Choice(
          key: const ValueKey('appearance-teal'),
          title: 'Teal',
          subtitle: 'The OmniFlow colours',
          swatch: OmniPalette.of(context).accent,
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
            _ =>
              'Picks up the colours of your phone\'s wallpaper, so OmniFlow '
                  'matches the rest of your phone',
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
          subtitle: _pureBlackWords,
          subtitleLines: 3,
          divider: false,
          semanticLabel:
              'Pure black, ${appearance.pureBlack ? 'on' : 'off'}. '
              '$_pureBlackWords',
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
    );
  }
}

const _pureBlackWords =
    'Fully black screens in the dark theme. On many phones this saves '
    'battery';

/// One choice: an [icon], or a round swatch of a colour, the words, and a
/// tick when chosen.
class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.swatch,
    this.icon,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Color? swatch;
  final IconData? icon;

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
        icon: icon,
        leading: icon != null
            ? null
            : Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: swatch ?? palette.raised,
                  border: Border.all(color: palette.line),
                ),
                child: swatch == null
                    ? Icon(
                        OmniIcons.color,
                        size: 18,
                        color: OmniPalette.of(context).text,
                      )
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
