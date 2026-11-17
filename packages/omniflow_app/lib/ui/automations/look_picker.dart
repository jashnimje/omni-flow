import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../rules/rule_spec.dart';
import '../design/automation_look.dart';
import '../design/design.dart';

/// The icon for an automation's `icon` name, or the bolt. Rules, links and
/// scenes pick from the one set in [AutomationLook.icons].
IconData automationIcon(String? name) =>
    AutomationLook.icons[name] ?? Symbols.bolt_rounded;

/// The colour for an automation's `color`: one of [AutomationLook.colors],
/// any other `#RRGGBB` as it is, or the first colour of the palette (teal)
/// when it has none. The palette is the rule's own data, so it does not
/// follow the app's accent.
Color automationColor(String? hex) {
  if (AutomationLook.colorOf(hex) case final c?) return c;
  final v = int.tryParse((hex ?? '').replaceFirst('#', ''), radix: 16);
  return v == null || hex!.length != 7
      ? AutomationLook.colors.values.first.color
      : Color(0xFF000000 | v);
}

/// What a screen reader says for each colour.
final colorNames = {
  for (final e in AutomationLook.colors.entries) e.key: e.value.name,
};

/// What a screen reader and the editor say for each icon of
/// [AutomationLook.icons].
const iconWords = <String, String>{
  'bolt': 'Bolt',
  'home': 'Home',
  'sunrise': 'Sunrise',
  'moon': 'Moon',
  'tv': 'TV',
  'lightbulb': 'Light bulb',
  'movie': 'Film',
  'music': 'Music',
  'fan': 'Fan',
  'lock': 'Lock',
  'car': 'Car',
  'bell': 'Bell',
  'heart': 'Heart',
  'star': 'Star',
  'leaf': 'Leaf',
  'fire': 'Fire',
};

/// "Teal, Bolt": how an automation looks, in words.
String lookWords(Look look, {String fallbackIcon = 'bolt'}) {
  final icon = look.icon ?? fallbackIcon;
  return '${colorNames[look.color] ?? colorNames.values.first}, '
      '${iconWords[icon] ?? icon}';
}

/// The colour and icon an automation shows with.
typedef Look = ({String? color, String? icon});

/// Picks an automation's or a scene's colour and icon from the palette:
/// one sheet, one icon set and one way of marking the picked one for
/// both. [fallbackIcon] is the icon it wears with none of its own. Null
/// when closed without Done.
Future<Look?> pickLook(
  BuildContext context,
  Look current, {
  String fallbackIcon = 'bolt',
}) {
  var color = current.color;
  var icon = current.icon;
  return showOmniSheet<Look>(
    context,
    builder: (_) => StatefulBuilder(
      builder: (context, setState) => SheetTemplate(
        title: 'Colour and icon',
        subtitle: 'How it shows on Home and in the list.',
        primaryLabel: 'Done',
        primaryKey: const ValueKey('look-done'),
        onPrimary: () =>
            Navigator.of(context).pop<Look>((color: color, icon: icon)),
        children: (context) => [
          const OmniSectionHeader('Colour'),
          Wrap(
            children: [
              for (final hex in automationColors)
                ColorSwatchButton(
                  key: ValueKey('look-color-${hex.substring(1)}'),
                  color: automationColor(hex),
                  label: 'Colour ${colorNames[hex] ?? hex}',
                  selected: (color ?? automationColors.first) == hex,
                  onPressed: () => setState(() => color = hex),
                ),
            ],
          ),
          const OmniSectionHeader('Icon'),
          Wrap(
            children: [
              for (final name in automationIconNames)
                _IconChoice(
                  key: ValueKey('look-icon-$name'),
                  label: 'Icon ${iconWords[name] ?? name}',
                  selected: (icon ?? fallbackIcon) == name,
                  onTap: () => setState(() => icon = name),
                  icon: automationIcon(name),
                  color: automationColor(color),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// One icon to pick: a 48 dp target, ringed and tinted when it is the one
/// picked, like [ColorSwatchButton].
class _IconChoice extends StatelessWidget {
  const _IconChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.icon,
    required this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: selected,
    label: label,
    excludeSemantics: true,
    child: InkResponse(
      onTap: onTap,
      radius: 24,
      child: SizedBox.square(
        dimension: OmniSpace.target,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: 0.18) : null,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? OmniColors.text : Colors.transparent,
                width: 2,
              ),
            ),
            child: Icon(
              icon,
              size: 24,
              color: selected ? color : OmniColors.muted,
            ),
          ),
        ),
      ),
    ),
  );
}
