import 'dart:convert';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../ui/design/tokens.dart';

/// Where the app's colours come from: OmniFlow's teal, or the phone's
/// wallpaper (Android dynamic colour).
enum ColourSource { teal, wallpaper }

/// Light or dark: as the phone is set (the default), or always one.
enum ThemeChoice {
  system,
  light,
  dark;

  ThemeMode get mode => switch (this) {
    system => ThemeMode.system,
    light => ThemeMode.light,
    dark => ThemeMode.dark,
  };

  /// The brightness the app shows when the phone is set to [phone].
  Brightness brightnessOn(Brightness phone) => switch (this) {
    system => phone,
    light => Brightness.light,
    dark => Brightness.dark,
  };
}

/// The Appearance setting. It lives on this phone only.
@immutable
class Appearance {
  const Appearance({
    this.theme = ThemeChoice.system,
    this.colours = ColourSource.teal,
    this.pureBlack = false,
  });

  factory Appearance.fromJson(Map<String, Object?> json) => Appearance(
    theme: ThemeChoice.values.asNameMap()[json['theme']] ?? ThemeChoice.system,
    colours: json['colours'] == 'wallpaper'
        ? ColourSource.wallpaper
        : ColourSource.teal,
    pureBlack: json['pureBlack'] == true,
  );

  final ThemeChoice theme;
  final ColourSource colours;

  /// Black screens in place of the dark grey, for OLED phones. Only the
  /// dark theme has it.
  final bool pureBlack;

  Appearance copyWith({
    ThemeChoice? theme,
    ColourSource? colours,
    bool? pureBlack,
  }) => Appearance(
    theme: theme ?? this.theme,
    colours: colours ?? this.colours,
    pureBlack: pureBlack ?? this.pureBlack,
  );

  Map<String, Object?> toJson() => {
    'theme': theme.name,
    'colours': colours.name,
    'pureBlack': pureBlack,
  };

  /// The palette this setting gives in [brightness], with [wallpaper] the
  /// phone's scheme of that brightness, or null where the phone has none
  /// (teal is used then).
  OmniPalette palette(
    ColorScheme? wallpaper, {
    Brightness brightness = Brightness.dark,
  }) {
    final dark = brightness == Brightness.dark;
    var p = dark ? OmniPalette.teal : OmniPalette.tealLight;
    if (pureBlack && dark) p = p.pureBlack();
    if (colours == ColourSource.wallpaper && wallpaper != null) {
      p = p.withScheme(wallpaper);
    }
    return p;
  }

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.theme == theme &&
      other.colours == colours &&
      other.pureBlack == pureBlack;

  @override
  int get hashCode => Object.hash(theme, colours, pureBlack);
}

abstract interface class AppearanceStore {
  Future<Appearance> read();
  Future<void> write(Appearance appearance);
}

/// A small JSON file next to the app's own data. Where it cannot be read
/// (tests, a first launch) the default look is used.
class FileAppearanceStore implements AppearanceStore {
  const FileAppearanceStore();

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/appearance.json');

  @override
  Future<Appearance> read() async {
    try {
      final text = await (await _file()).readAsString();
      final json = jsonDecode(text);
      return json is Map
          ? Appearance.fromJson(Map<String, Object?>.from(json))
          : const Appearance();
    } on Object {
      return const Appearance();
    }
  }

  @override
  Future<void> write(Appearance appearance) async {
    try {
      await (await _file()).writeAsString(jsonEncode(appearance.toJson()));
    } on Object {
      return;
    }
  }
}

/// Keeps the setting in memory: tests, and phones that cannot write files.
class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this.saved = const Appearance()]);

  Appearance saved;

  @override
  Future<Appearance> read() async => saved;

  @override
  Future<void> write(Appearance appearance) async => saved = appearance;
}

final appearanceStoreProvider = Provider<AppearanceStore>(
  (ref) => const FileAppearanceStore(),
);

class AppearanceNotifier extends AsyncNotifier<Appearance> {
  @override
  Future<Appearance> build() => ref.watch(appearanceStoreProvider).read();

  Future<void> change(Appearance next) async {
    state = AsyncData(next);
    await ref.read(appearanceStoreProvider).write(next);
  }
}

final appearanceProvider =
    AsyncNotifierProvider<AppearanceNotifier, Appearance>(
      AppearanceNotifier.new,
    );

/// The phone's wallpaper colours as a dark and a light scheme, or null
/// where Android does not offer them (before Android 12, and in tests).
final _wallpaperSchemesProvider =
    FutureProvider<({ColorScheme dark, ColorScheme light})?>((ref) async {
      try {
        final core = await DynamicColorPlugin.getCorePalette();
        if (core == null) return null;
        Color tone(int t) => Color(core.primary.get(t));
        // The dark and light schemes' tones of the wallpaper's primary
        // palette.
        return (
          dark: ColorScheme.dark(
            primary: tone(80),
            onPrimary: tone(20),
            primaryContainer: tone(30),
            onPrimaryContainer: tone(90),
          ),
          light: ColorScheme.light(
            primary: tone(40),
            onPrimary: tone(100),
            primaryContainer: tone(90),
            onPrimaryContainer: tone(10),
          ),
        );
      } on Object {
        return null;
      }
    });

/// The phone's wallpaper colours as a dark scheme, or null where the phone
/// has none.
final wallpaperSchemeProvider = FutureProvider<ColorScheme?>(
  (ref) async => (await ref.watch(_wallpaperSchemesProvider.future))?.dark,
);

/// The same colours as a light scheme.
final wallpaperLightSchemeProvider = FutureProvider<ColorScheme?>(
  (ref) async => (await ref.watch(_wallpaperSchemesProvider.future))?.light,
);

Appearance _appearance(Ref ref) =>
    ref.watch(appearanceProvider).value ?? const Appearance();

/// The dark palette the theme is built from, as the setting says.
final darkPaletteProvider = Provider<OmniPalette>((ref) {
  final appearance = _appearance(ref);
  final wallpaper = appearance.colours == ColourSource.wallpaper
      ? ref.watch(wallpaperSchemeProvider).value
      : null;
  return appearance.palette(wallpaper);
});

/// The light palette, as the setting says.
final lightPaletteProvider = Provider<OmniPalette>((ref) {
  final appearance = _appearance(ref);
  final wallpaper = appearance.colours == ColourSource.wallpaper
      ? ref.watch(wallpaperLightSchemeProvider).value
      : null;
  return appearance.palette(wallpaper, brightness: Brightness.light);
});

/// Light, dark or as the phone is set.
final themeChoiceProvider = Provider<ThemeChoice>(
  (ref) => _appearance(ref).theme,
);

/// The palette the app shows now: the light or the dark one, by the
/// setting and, for System, the phone's own brightness.
OmniPalette shownPalette(WidgetRef ref, BuildContext context) {
  final brightness = ref
      .watch(themeChoiceProvider)
      .brightnessOn(MediaQuery.platformBrightnessOf(context));
  return ref.watch(
    brightness == Brightness.light ? lightPaletteProvider : darkPaletteProvider,
  );
}
