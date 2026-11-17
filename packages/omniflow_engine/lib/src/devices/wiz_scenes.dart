import 'wiz_pilot.dart' show WizBulb;

/// How a WiZ scene is grouped where it is picked.
enum WizSceneGroup {
  /// A light for a task or a time of day: Daylight, Focus, Night light.
  functional('functional', 'Functional'),

  /// One steady light: Warm white, Cozy, Candlelight.
  still('static', 'Static'),

  /// A light that moves, at a speed: Ocean, Party, Fireplace.
  dynamic('dynamic', 'Dynamic');

  const WizSceneGroup(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// One WiZ scene (a light mode): the `sceneId` a bulb takes and reports,
/// its name, and which bulb kinds play it.
class WizScene {
  const WizScene(
    this.id,
    this.slug,
    this.name,
    this.group,
    this.icon, {
    this.white = false,
    this.dimmable = false,
  });

  final int id;

  /// The value a step or the CLI names it by: `ocean`, `night_light`.
  final String slug;
  final String name;
  final WizSceneGroup group;

  /// A Material Symbols name for the app's icon set.
  final String icon;

  /// Whether a tunable white bulb plays it. Every colour bulb plays all.
  final bool white;

  /// Whether a one-white (dimmable) bulb plays it.
  final bool dimmable;

  /// Whether it moves and takes a `speed` (10 to 200).
  bool get dynamic => group == WizSceneGroup.dynamic;

  /// Whether a bulb of [kind] (`WizBulb.kind`) plays it. An unknown kind
  /// is taken as a colour bulb.
  bool playsOn(String? kind) => switch (kind) {
    'white' => white,
    'dimmable' => dimmable,
    'socket' => false,
    _ => true,
  };

  Map<String, Object?> toChoice() => {
    'value': slug,
    'label': name,
    'group': group.wireName,
    'groupLabel': group.label,
    'icon': icon,
    if (dynamic) 'takes': const ['speed'],
  };
}

/// The WiZ scenes, in the order the app shows them.
///
/// Ids and names are pywizlight's `SCENES`, and which bulbs play which are
/// its `TW_SCENES` (tunable white) and `DW_SCENES` (dimmable white), from
/// https://github.com/sbidy/pywizlight/blob/master/pywizlight/scenes.py.
/// Colour bulbs (`BulbClass.RGB`) play every scene but the TV sync ones
/// (201 to 204), which need the WiZ app's screen sync, and those are left
/// out with Rhythm (1000), which a bulb refuses over the LAN (-32602 from
/// an ESP25_SHRGB_01 on firmware 1.38), and the ten custom modes (256 to
/// 265), whose light is whatever the user made in the WiZ app.
///
/// The groups are OmniFlow's. A scene is dynamic exactly when a bulb
/// reports a `speed` for it: an ESP25_SHRGB_01 on firmware 1.38 reports
/// one in `getPilot` for 1 to 5, 7, 8, 20 to 28, 30 to 33 and 36, and none
/// for the rest.
const wizScenes = <WizScene>[
  // Functional.
  WizScene(
    12,
    'daylight',
    'Daylight',
    WizSceneGroup.functional,
    'sunny',
    white: true,
  ),
  WizScene(
    15,
    'focus',
    'Focus',
    WizSceneGroup.functional,
    'center_focus_strong',
    white: true,
  ),
  WizScene(16, 'relax', 'Relax', WizSceneGroup.functional, 'spa', white: true),
  WizScene(
    18,
    'tv_time',
    'TV time',
    WizSceneGroup.functional,
    'tv',
    white: true,
  ),
  WizScene(
    14,
    'night_light',
    'Night light',
    WizSceneGroup.functional,
    'nightlight',
    white: true,
    dimmable: true,
  ),
  WizScene(
    9,
    'wake_up',
    'Wake-up',
    WizSceneGroup.functional,
    'wb_sunny',
    white: true,
    dimmable: true,
  ),
  WizScene(
    10,
    'bedtime',
    'Bedtime',
    WizSceneGroup.functional,
    'bedtime',
    white: true,
    dimmable: true,
  ),
  WizScene(
    35,
    'alarm',
    'Alarm',
    WizSceneGroup.functional,
    'alarm',
    white: true,
    dimmable: true,
  ),
  WizScene(
    17,
    'true_colors',
    'True colors',
    WizSceneGroup.functional,
    'gradient',
  ),
  WizScene(
    19,
    'plantgrowth',
    'Plantgrowth',
    WizSceneGroup.functional,
    'potted_plant',
  ),
  // Static.
  WizScene(
    11,
    'warm_white',
    'Warm white',
    WizSceneGroup.still,
    'wb_incandescent',
    white: true,
  ),
  WizScene(
    13,
    'cool_white',
    'Cool white',
    WizSceneGroup.still,
    'ac_unit',
    white: true,
  ),
  WizScene(
    34,
    'white',
    'White',
    WizSceneGroup.still,
    'lightbulb',
    dimmable: true,
  ),
  WizScene(6, 'cozy', 'Cozy', WizSceneGroup.still, 'chair', white: true),
  WizScene(
    29,
    'candlelight',
    'Candlelight',
    WizSceneGroup.still,
    'candle',
    white: true,
    dimmable: true,
  ),
  WizScene(
    40,
    'dim_to_warm',
    'Dim-to-warm',
    WizSceneGroup.still,
    'brightness_medium',
    white: true,
  ),
  // Dynamic.
  WizScene(1, 'ocean', 'Ocean', WizSceneGroup.dynamic, 'waves'),
  WizScene(2, 'romance', 'Romance', WizSceneGroup.dynamic, 'favorite'),
  WizScene(3, 'sunset', 'Sunset', WizSceneGroup.dynamic, 'wb_twilight'),
  WizScene(4, 'party', 'Party', WizSceneGroup.dynamic, 'celebration'),
  WizScene(5, 'fireplace', 'Fireplace', WizSceneGroup.dynamic, 'fireplace'),
  WizScene(7, 'forest', 'Forest', WizSceneGroup.dynamic, 'forest'),
  WizScene(
    8,
    'pastel_colors',
    'Pastel colors',
    WizSceneGroup.dynamic,
    'palette',
  ),
  WizScene(20, 'spring', 'Spring', WizSceneGroup.dynamic, 'local_florist'),
  WizScene(21, 'summer', 'Summer', WizSceneGroup.dynamic, 'beach_access'),
  WizScene(22, 'fall', 'Fall', WizSceneGroup.dynamic, 'eco'),
  WizScene(23, 'deep_dive', 'Deep dive', WizSceneGroup.dynamic, 'scuba_diving'),
  WizScene(24, 'jungle', 'Jungle', WizSceneGroup.dynamic, 'park'),
  WizScene(25, 'mojito', 'Mojito', WizSceneGroup.dynamic, 'local_bar'),
  WizScene(26, 'club', 'Club', WizSceneGroup.dynamic, 'nightlife'),
  WizScene(27, 'christmas', 'Christmas', WizSceneGroup.dynamic, 'redeem'),
  WizScene(28, 'halloween', 'Halloween', WizSceneGroup.dynamic, 'skull'),
  WizScene(
    30,
    'golden_white',
    'Golden white',
    WizSceneGroup.dynamic,
    'brightness_7',
    white: true,
  ),
  WizScene(
    31,
    'pulse',
    'Pulse',
    WizSceneGroup.dynamic,
    'monitor_heart',
    white: true,
    dimmable: true,
  ),
  WizScene(
    32,
    'steampunk',
    'Steampunk',
    WizSceneGroup.dynamic,
    'precision_manufacturing',
    white: true,
    dimmable: true,
  ),
  WizScene(
    33,
    'diwali',
    'Diwali',
    WizSceneGroup.dynamic,
    'emoji_objects',
    white: true,
  ),
  WizScene(
    36,
    'snowy_sky',
    'Snowy sky',
    WizSceneGroup.dynamic,
    'weather_snowy',
  ),
];

/// The scene id Rhythm has. A bulb refuses it over the LAN.
const wizRhythmId = 1000;

final _byId = {for (final s in wizScenes) s.id: s};
final _bySlug = {for (final s in wizScenes) s.slug: s};

WizScene? wizSceneById(Object? id) => id is num ? _byId[id.round()] : null;

WizScene? wizSceneBySlug(Object? slug) => slug is String ? _bySlug[slug] : null;

/// The scene [value] names: a slug (`ocean`), its name (`Ocean`), or an id.
WizScene? wizSceneOf(Object? value) => switch (value) {
  final num id => wizSceneById(id),
  final String s =>
    _bySlug[s] ??
        _bySlug[s.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_')] ??
        (int.tryParse(s.trim()) == null
            ? null
            : wizSceneById(int.parse(s.trim()))),
  _ => null,
};

/// The scenes a bulb of [kind] plays, every one when the kind is unknown.
List<WizScene> wizScenesFor(String? kind) => [
  for (final s in wizScenes)
    if (s.playsOn(kind)) s,
];

/// A colour in a word, for a sentence and the device's mode: "red",
/// "warm white" (only the white channels), "white" (no hue to speak of).
String colourWords(num r, num g, num b, {num c = 0, num w = 0}) {
  final max = [r, g, b].reduce((a, v) => a > v ? a : v).toDouble();
  final min = [r, g, b].reduce((a, v) => a < v ? a : v).toDouble();
  if (max <= 0) {
    if (c > 0 && w > 0) return 'white';
    if (w > 0) return 'warm white';
    if (c > 0) return 'cool white';
    return 'off';
  }
  final saturation = (max - min) / max;
  if (saturation < 0.15) return 'white';
  final d = max - min;
  double hue;
  if (max == r) {
    hue = 60 * (((g - b) / d) % 6);
  } else if (max == g) {
    hue = 60 * ((b - r) / d + 2);
  } else {
    hue = 60 * ((r - g) / d + 4);
  }
  if (hue < 0) hue += 360;
  return switch (hue) {
    < 15 => 'red',
    < 40 => 'orange',
    < 70 => 'yellow',
    < 160 => 'green',
    < 200 => 'cyan',
    < 255 => 'blue',
    < 290 => 'purple',
    < 340 => 'pink',
    _ => 'red',
  };
}

/// Words for a white temperature: "warm white", "neutral white", "cool
/// white".
String whiteWords(num kelvin) => kelvin < 3500
    ? 'warm white'
    : kelvin > 5000
    ? 'cool white'
    : 'neutral white';

String _capital(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// What a WiZ bulb is doing, from its state as `getPilot` or `syncPilot`
/// report it, or null when the state says nothing about it yet.
///
/// `{kind, label}`, `kind` being `scene`, `colour` or `white`. A scene
/// adds `scene` (its slug), `sceneId`, `dynamic` and, when moving,
/// `speed`. A colour adds `r`, `g`, `b`, `c` and `w`; a white `temp`. A
/// scene wins over the white some report with it (Warm white says 2700 K).
Map<String, Object?>? wizModeOf(Map<String, Object?> state) {
  final id = state['sceneId'];
  if (id is num && id > 0) {
    final scene = wizSceneById(id);
    final rounded = id.round();
    return {
      'kind': 'scene',
      'label':
          scene?.name ??
          (rounded == wizRhythmId
              ? 'Rhythm'
              : rounded >= 256 && rounded <= 265
              ? 'Custom mode ${rounded - 255}'
              : 'Scene $rounded'),
      'scene': ?scene?.slug,
      'sceneId': rounded,
      'dynamic': scene?.dynamic ?? state['speed'] is num,
      if (state['speed'] case final num speed) 'speed': speed.round(),
    };
  }
  final rgb = [state['r'], state['g'], state['b']];
  final cw = [state['c'], state['w']];
  if (rgb.every((v) => v is num) || cw.any((v) => v is num && v > 0)) {
    num n(Object? v) => v is num ? v : 0;
    final (r, g, b, c, w) = (
      n(rgb[0]),
      n(rgb[1]),
      n(rgb[2]),
      n(cw[0]),
      n(cw[1]),
    );
    return {
      'kind': 'colour',
      'label': _capital(colourWords(r, g, b, c: c, w: w)),
      'r': r.round(),
      'g': g.round(),
      'b': b.round(),
      'c': c.round(),
      'w': w.round(),
    };
  }
  if (state['temp'] case final num temp when temp > 0) {
    return {
      'kind': 'white',
      'label': '${_capital(whiteWords(temp))} ${temp.round()} K',
      'temp': temp.round(),
    };
  }
  return null;
}

/// The scenes [bulb] plays, as the choices of the `scene` param a UI and an
/// agent pick from: `{value, label, group, groupLabel, icon, takes?}`.
List<Map<String, Object?>> wizSceneChoices(WizBulb? bulb) => [
  for (final s in wizScenesFor(bulb?.kind)) s.toChoice(),
];

/// A light step in words: "Ocean scene, speed 150" for a scene named
/// [sceneName], "pink colour, brightness 60%" for a `color_rgb`, "warm
/// white 2700 K" for a `color_temp` in kelvin. Null for any other step, or
/// one whose values are not plain numbers (a `{{%level}}`). [sceneMoves]
/// says whether the scene takes its speed.
String? lightStepWords({
  required String? type,
  required Map params,
  String? unit,
  String? sceneName,
  bool sceneMoves = true,
}) {
  num? n(String k) => params[k] is num ? params[k] as num : null;
  final dim = n('brightness') == null
      ? null
      : 'brightness ${n('brightness')!.round()}%';
  if (sceneName != null && params['scene'] != null) {
    return [
      '$sceneName scene',
      if (n('speed') != null && sceneMoves) 'speed ${n('speed')!.round()}',
      ?dim,
    ].join(', ');
  }
  if (type == 'color_rgb' && [n('r'), n('g'), n('b')].every((v) => v != null)) {
    final colour = colourWords(
      n('r')!,
      n('g')!,
      n('b')!,
      c: n('c') ?? 0,
      w: n('w') ?? 0,
    );
    return [
      colour.endsWith('white') ? colour : '$colour colour',
      ?dim,
    ].join(', ');
  }
  if (type == 'color_temp' && unit == 'K' && n('value') != null) {
    final k = n('value')!.round();
    return ['${whiteWords(k)} $k K', ?dim].join(', ');
  }
  return null;
}
