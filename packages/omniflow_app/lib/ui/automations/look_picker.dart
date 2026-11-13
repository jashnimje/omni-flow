import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../rules/rule_spec.dart';
import '../design/design.dart';

/// The icon for an automation's `icon` name, or the bolt.
IconData automationIcon(String? name) => switch (name) {
  'home' => Symbols.home_rounded,
  'sunrise' => Symbols.wb_twilight_rounded,
  'moon' => Symbols.bedtime_rounded,
  'tv' => Symbols.tv_rounded,
  'lightbulb' => Symbols.lightbulb_rounded,
  'movie' => Symbols.movie_rounded,
  'music' => Symbols.music_note_rounded,
  'fan' => Symbols.mode_fan_rounded,
  'lock' => Symbols.lock_rounded,
  'car' => Symbols.directions_car_rounded,
  'bell' => Symbols.notifications_rounded,
  'heart' => Symbols.favorite_rounded,
  'star' => Symbols.star_rounded,
  'leaf' => Symbols.eco_rounded,
  'fire' => Symbols.local_fire_department_rounded,
  _ => Symbols.bolt_rounded,
};

/// The colour for an automation's `color`, or the accent.
Color automationColor(String? hex) {
  final v = int.tryParse((hex ?? '').replaceFirst('#', ''), radix: 16);
  return v == null || hex!.length != 7
      ? OmniColors.accent
      : Color(0xFF000000 | v);
}

/// What a screen reader says for each colour.
const colorNames = {
  '#00F5D4': 'Teal',
  '#4D9DFF': 'Blue',
  '#A78BFA': 'Purple',
  '#F472B6': 'Pink',
  '#FB923C': 'Orange',
  '#FACC15': 'Yellow',
  '#34D399': 'Green',
  '#94A3B8': 'Grey',
};

/// The colour and icon an automation shows with.
typedef Look = ({String? color, String? icon});

/// Picks an automation's colour and icon from the palette. Null when left
/// without Done.
Future<Look?> pickLook(BuildContext context, Look current) {
  var color = current.color;
  var icon = current.icon;
  return showOmniSheet<Look>(
    context,
    builder: (_) => StatefulBuilder(
      builder: (context, setState) => OmniSheet(
        title: 'Colour and icon',
        subtitle: 'How it shows on Home and in the list.',
        children: [
          const Text('Colour', style: OmniText.caption),
          const SizedBox(height: OmniSpace.xs),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final hex in automationColors)
                _Swatch(
                  key: ValueKey('look-color-${hex.substring(1)}'),
                  label: colorNames[hex] ?? hex,
                  selected: (color ?? automationColors.first) == hex,
                  onTap: () => setState(() => color = hex),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: automationColor(hex),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: OmniSpace.md),
          const Text('Icon', style: OmniText.caption),
          const SizedBox(height: OmniSpace.xs),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final name in automationIconNames)
                _Swatch(
                  key: ValueKey('look-icon-$name'),
                  label: name,
                  selected: (icon ?? automationIconNames.first) == name,
                  onTap: () => setState(() => icon = name),
                  child: Icon(
                    automationIcon(name),
                    size: 26,
                    color: automationColor(color),
                  ),
                ),
            ],
          ),
          const SizedBox(height: OmniSpace.md),
          OmniButton(
            key: const ValueKey('look-done'),
            label: 'Done',
            onPressed: () =>
                Navigator.of(context).pop<Look>((color: color, icon: icon)),
          ),
        ],
      ),
    ),
  );
}

/// One colour or icon to pick, with a ring when it is the one picked.
class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    inMutuallyExclusiveGroup: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: OmniSpace.target,
        height: OmniSpace.target,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? OmniColors.text : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      ),
    ),
  );
}
