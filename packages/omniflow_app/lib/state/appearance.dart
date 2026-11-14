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

/// The Appearance setting. It lives on this phone only.
@immutable
class Appearance {
  const Appearance({this.colours = ColourSource.teal, this.pureBlack = false});

  factory Appearance.fromJson(Map<String, Object?> json) => Appearance(
    colours: json['colours'] == 'wallpaper'
        ? ColourSource.wallpaper
        : ColourSource.teal,
    pureBlack: json['pureBlack'] == true,
  );

  final ColourSource colours;

  /// Black screens in place of the dark grey, for OLED phones.
  final bool pureBlack;

  Appearance copyWith({ColourSource? colours, bool? pureBlack}) => Appearance(
    colours: colours ?? this.colours,
    pureBlack: pureBlack ?? this.pureBlack,
  );

  Map<String, Object?> toJson() => {
    'colours': colours.name,
    'pureBlack': pureBlack,
  };

  /// The palette this setting gives, with [wallpaper] the phone's dark
  /// scheme, or null where the phone has none (teal is used then).
  OmniPalette palette(ColorScheme? wallpaper) {
    var p = OmniPalette.teal;
    if (pureBlack) p = p.pureBlack();
    if (colours == ColourSource.wallpaper && wallpaper != null) {
      p = p.withScheme(wallpaper);
    }
    return p;
  }

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.colours == colours &&
      other.pureBlack == pureBlack;

  @override
  int get hashCode => Object.hash(colours, pureBlack);
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

/// The phone's wallpaper colours as a dark scheme, or null where Android
/// does not offer them (before Android 12, and in tests).
final wallpaperSchemeProvider = FutureProvider<ColorScheme?>((ref) async {
  try {
    final core = await DynamicColorPlugin.getCorePalette();
    if (core == null) return null;
    // The dark scheme's tones of the wallpaper's primary palette.
    return ColorScheme.dark(
      primary: Color(core.primary.get(80)),
      onPrimary: Color(core.primary.get(20)),
      primaryContainer: Color(core.primary.get(30)),
      onPrimaryContainer: Color(core.primary.get(90)),
    );
  } on Object {
    return null;
  }
});

/// The palette the theme is built from, as the setting says.
final paletteProvider = Provider<OmniPalette>((ref) {
  final appearance = ref.watch(appearanceProvider).value ?? const Appearance();
  final wallpaper = appearance.colours == ColourSource.wallpaper
      ? ref.watch(wallpaperSchemeProvider).value
      : null;
  return appearance.palette(wallpaper);
});
