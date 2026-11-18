import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'device_text.dart';

/// The parts of a light's page that pick what it shows: white, a colour or
/// one of its scenes, shared with the step editor. What a light can do
/// comes from its capabilities and their params, as the engine lists them;
/// what it is doing comes from the device's `mode`.

/// The capability that sets [d]'s scenes: the one whose `scene` param
/// lists its choices.
Json? sceneCapabilityOf(DeviceView d) =>
    d.capabilities.where((c) => sceneChoicesOf(c).isNotEmpty).firstOrNull;

/// The scenes [capability] takes, each `{value, label, group, groupLabel,
/// icon, takes?}`, or none.
List<Json> sceneChoicesOf(Json? capability) {
  final params = capability?['params'];
  final scene = params is Map ? params['scene'] : null;
  final choices = scene is Map ? scene['choices'] : null;
  return [
    for (final c in choices is List ? choices : const [])
      if (c is Map) Map<String, Object?>.from(c),
  ];
}

/// Whether [choice] takes the param [key] (a moving scene takes `speed`).
bool choiceTakes(Json? choice, String key) =>
    (choice?['takes'] as List?)?.contains(key) ?? false;

/// What [d] is doing, as the engine words it: `{kind, label, ...}`.
Json? modeOf(DeviceView d) => d.json['mode'] is Map
    ? Map<String, Object?>.from(d.json['mode'] as Map)
    : null;

/// Scenes as a grid of tiles, one group at a time: Functional, Static and
/// Dynamic. The [active] one is lit. A tap picks it.
class SceneGrid extends StatefulWidget {
  const SceneGrid({
    super.key,
    required this.choices,
    required this.active,
    required this.onPick,
  });

  final List<Json> choices;
  final String? active;
  final ValueChanged<String>? onPick;

  @override
  State<SceneGrid> createState() => _SceneGridState();
}

class _SceneGridState extends State<SceneGrid> {
  String? _group;

  List<(String, String)> get _groups {
    final seen = <String, String>{};
    for (final c in widget.choices) {
      seen.putIfAbsent('${c['group']}', () => '${c['groupLabel']}');
    }
    return [for (final e in seen.entries) (e.key, e.value)];
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final active = widget.choices
        .where((c) => c['value'] == widget.active)
        .firstOrNull;
    final group =
        _group ?? '${active?['group'] ?? groups.firstOrNull?.$1 ?? ''}';
    final shown = [
      for (final c in widget.choices)
        if (groups.length < 2 || c['group'] == group) c,
    ];
    final columns = OmniWidth.of(context).tileColumns + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (groups.length > 1)
          OmniSegmented<String>(
            key: const ValueKey('scene-groups'),
            segments: [
              for (final (id, label) in groups) OmniSegment(id, label),
            ],
            selected: group,
            onChanged: (g) => setState(() => _group = g),
          ),
        for (var i = 0; i < shown.length; i += columns)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var j = 0; j < columns; j++) ...[
                  if (j > 0) const SizedBox(width: OmniSpace.md),
                  Expanded(
                    child: i + j < shown.length
                        ? _tile(shown[i + j])
                        : const SizedBox(),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _tile(Json c) {
    final value = '${c['value']}';
    final on = value == widget.active;
    return OmniTile(
      key: ValueKey('scene-$value'),
      icon: OmniIcons.forScene(c['icon'] as String?),
      name: '${c['label'] ?? value}',
      on: on,
      offline: widget.onPick == null,
      chevron: false,
      tapHint: on ? null : 'Sets this scene',
      onTap: widget.onPick == null ? null : () => widget.onPick!(value),
    );
  }
}

/// Ten colours to pick at a tap, sent as r, g and b.
class ColourSwatches extends StatelessWidget {
  const ColourSwatches({super.key, required this.onPick});

  final void Function(Json rgb)? onPick;

  static const colours = {
    'Red': Color(0xFFFF6B6B),
    'Orange': Color(0xFFFF9F43),
    'Yellow': Color(0xFFFFD93D),
    'Green': Color(0xFF6BCB77),
    'Cyan': Color(0xFF4DD8E6),
    'Blue': Color(0xFF4D96FF),
    'Purple': Color(0xFFB18CFF),
    'Pink': Color(0xFFFF6FB5),
    'Deep red': Color(0xFFFF0000),
    'Deep blue': Color(0xFF0000FF),
  };

  static Json rgbOf(Color c) => {
    'r': (c.r * 255).round(),
    'g': (c.g * 255).round(),
    'b': (c.b * 255).round(),
  };

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: OmniSpace.xs,
    children: [
      for (final e in colours.entries)
        Semantics(
          button: true,
          enabled: onPick != null,
          label: e.key,
          excludeSemantics: true,
          onTap: onPick == null ? null : () => onPick!(rgbOf(e.value)),
          child: OmniTapTarget(
            key: ValueKey('swatch-${e.key}'),
            onTap: onPick == null ? null : () => onPick!(rgbOf(e.value)),
            child: Opacity(
              opacity: onPick == null ? 0.4 : 1,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: e.value,
                  shape: BoxShape.circle,
                  border: Border.all(color: OmniPalette.of(context).line),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// The swatches, then the wheel for any other colour.
class ColourPicker extends StatelessWidget {
  const ColourPicker({super.key, required this.value, required this.onPick});

  /// The colour shown as picked: r, g and b, or null.
  final Json? value;
  final void Function(Json rgb)? onPick;

  static Color? colourOf(Json? rgb) {
    if (rgb == null) return null;
    final [r, g, b] = [
      for (final k in ['r', 'g', 'b']) rgb[k],
    ];
    if (r is! num || g is! num || b is! num || (r + g + b) <= 0) return null;
    return Color.fromARGB(255, r.round(), g.round(), b.round());
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ColourSwatches(onPick: onPick),
      const SizedBox(height: OmniSpace.md),
      Center(
        child: OmniColourWheel(
          key: const ValueKey('colour-wheel'),
          value: colourOf(value),
          onPick: onPick == null
              ? null
              : (c) => onPick!(ColourSwatches.rgbOf(c)),
        ),
      ),
    ],
  );
}

/// Four named whites from warm to cool, those inside [min] to [max]
/// kelvin. The kelvin shows only on the slider, so the chips stay words.
class WhitePresets extends StatelessWidget {
  const WhitePresets({
    super.key,
    required this.min,
    required this.max,
    required this.value,
    required this.onPick,
  });

  final double min;
  final double max;
  final num? value;
  final ValueChanged<int>? onPick;

  static const presets = [
    ('Candle', 2200),
    ('Warm', 2700),
    ('Neutral', 4000),
    ('Daylight', 5000),
  ];

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: OmniSpace.sm,
    runSpacing: OmniSpace.xs,
    children: [
      for (final (label, k) in presets)
        if (k >= min && k <= max)
          OmniFilterChip(
            key: ValueKey('white-$k'),
            label: label,
            selected: value?.round() == k,
            onTap: onPick == null ? null : () => onPick!(k),
          ),
    ],
  );
}

const _warmth = LightWhite.kelvin;
const _cool = LightWhite.mired;

enum LightMode {
  white('White'),
  colour('Colour'),
  scene('Effects');

  const LightMode(this.label);

  final String label;
}

/// A light's White, Colour and Effects (its scenes), one at a time under
/// one segmented control, starting on what the light is doing. The scene speed shows
/// only while the light is in a scene that moves.
class LightModePanel extends ConsumerStatefulWidget {
  const LightModePanel({super.key, required this.device});

  final DeviceView device;

  /// The modes [d] has: white for a warmth, colour for r, g and b, scenes
  /// for a scene list.
  static List<LightMode> modesOf(DeviceView d) => [
    if (d.capabilityOf('color_temp') != null) LightMode.white,
    if (d.capabilityOf('color_rgb') != null) LightMode.colour,
    if (sceneCapabilityOf(d) != null) LightMode.scene,
  ];

  @override
  ConsumerState<LightModePanel> createState() => _LightModePanelState();
}

class _LightModePanelState extends ConsumerState<LightModePanel> {
  LightMode? _picked;

  LightMode? _current(DeviceView d) => switch (modeOf(d)?['kind']) {
    'scene' => LightMode.scene,
    'colour' => LightMode.colour,
    'white' => LightMode.white,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final modes = LightModePanel.modesOf(d);
    if (modes.isEmpty) return const SizedBox.shrink();
    final now = _current(d);
    final shown =
        _picked ?? (now != null && modes.contains(now) ? now : modes.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: OmniSpace.sm),
        if (modes.length > 1)
          OmniSegmented<LightMode>(
            key: ValueKey('light-mode-${d.id}'),
            segments: [for (final m in modes) OmniSegment(m, m.label)],
            selected: shown,
            onChanged: (m) => setState(() => _picked = m),
          ),
        ...switch (shown) {
          LightMode.white => _white(d),
          LightMode.colour => _colour(d),
          LightMode.scene => _scenes(d),
        },
      ],
    );
  }

  Future<void> _send(DeviceView d, Json cap, Json params) =>
      ref.read(engineApiProvider).invoke(d.id, '${cap['id']}', params);

  List<Widget> _white(DeviceView d) {
    final cap = d.capabilityOf('color_temp')!;
    final range = rangeOf(cap);
    final value = d.state[cap['stateKey']];
    final mired = range.unit == 'mired';
    final kelvin = value is num ? kelvinOf(value, range.unit) : null;
    final lit = modeOf(d)?['kind'] != 'scene' && modeOf(d)?['kind'] != 'colour';
    return [
      OmniLabelledSlider(
        key: ValueKey('slider-${d.id}.${cap['id']}'),
        label: 'Warmth',
        value: value is num ? value.toDouble() : range.min,
        min: range.min,
        max: range.max,
        step: 1,
        format: (v) => value is! num
            ? '-'
            : mired
            ? formatValue(kelvinOf(v, 'mired') ?? v, 'K')
            : formatValue(v.round(), range.unit),
        fill: mired ? _cool : _warmth,
        labelOnFill: LightWhite.onWarm,
        onChangeEnd: d.online
            ? (v) => _send(d, cap, {'value': v.round()})
            : null,
      ),
      if (!mired) ...[
        const SizedBox(height: OmniSpace.sm),
        WhitePresets(
          min: range.min,
          max: range.max,
          value: lit ? kelvin : null,
          onPick: d.online ? (k) => _send(d, cap, {'value': k}) : null,
        ),
      ],
    ];
  }

  List<Widget> _colour(DeviceView d) {
    final cap = d.capabilityOf('color_rgb')!;
    final mode = modeOf(d);
    final colour = mode?['kind'] == 'colour' ? mode : null;
    final params = cap['params'] is Map ? cap['params'] as Map : const {};
    num channel(String k) => colour?[k] is num ? colour![k] as num : 0;
    Json rgb() => {
      for (final k in ['r', 'g', 'b']) k: channel(k).round(),
    };
    Widget white(String key, String label) => Padding(
      padding: const EdgeInsets.only(top: OmniSpace.xs),
      child: OmniLabelledSlider(
        key: ValueKey('slider-${d.id}.${cap['id']}.$key'),
        label: label,
        value: channel(key).toDouble(),
        max: 255,
        step: 1,
        format: (v) => formatValue((v / 255 * 100).round(), '%'),
        fill: key == 'w' ? _warmth : _cool,
        labelOnFill: LightWhite.onWarm,
        onChangeEnd: d.online
            ? (v) => _send(d, cap, {
                ...rgb(),
                for (final k in ['c', 'w'])
                  if (params.containsKey(k))
                    k: k == key ? v.round() : channel(k).round(),
              })
            : null,
      ),
    );
    return [
      ColourPicker(
        value: colour,
        onPick: d.online ? (rgb) => _send(d, cap, rgb) : null,
      ),
      if (params.containsKey('w') || params.containsKey('c')) ...[
        const OmniSectionHeader('White channels'),
        if (params.containsKey('w')) white('w', 'Warm white'),
        if (params.containsKey('c')) white('c', 'Cool white'),
      ],
    ];
  }

  List<Widget> _scenes(DeviceView d) {
    final cap = sceneCapabilityOf(d)!;
    final choices = sceneChoicesOf(cap);
    final mode = modeOf(d);
    final active = mode?['kind'] == 'scene' ? mode!['scene'] as String? : null;
    final choice = choices.where((c) => c['value'] == active).firstOrNull;
    final speed = (cap['params'] as Map?)?['speed'];
    return [
      SceneGrid(
        key: ValueKey('scene-grid-${d.id}'),
        choices: choices,
        active: active,
        onPick: d.online ? (s) => _send(d, cap, {'scene': s}) : null,
      ),
      if (active != null && choiceTakes(choice, 'speed') && speed is Map)
        OmniLabelledSlider(
          key: ValueKey('slider-${d.id}.${cap['id']}.speed'),
          label: '${choice!['label']} speed',
          value: ((mode!['speed'] as num?) ?? 100).toDouble(),
          min: (speed['min'] as num? ?? 10).toDouble(),
          max: (speed['max'] as num? ?? 200).toDouble(),
          step: 1,
          format: (v) => formatValue(v.round(), '%'),
          onChangeEnd: d.online
              ? (v) => _send(d, cap, {'scene': active, 'speed': v.round()})
              : null,
        ),
    ];
  }
}
