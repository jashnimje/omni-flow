import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/home_location_calls.dart';
import '../../service/permissions.dart';
import '../../state/providers.dart';
import '../automations/sun_lighting_page.dart'
    show openSunLighting, sunlightProvider;
import '../design/design.dart';
import 'cities.dart';

/// Where home is, or null while it loads, when it is not set, or when the
/// engine did not answer. It starts the move of a name an older build kept
/// on this phone, which reads it again once the engine has the name.
final FutureProvider<HomeLocationView?> homeLocationProvider =
    FutureProvider.autoDispose<HomeLocationView?>((ref) {
      ref.read(homePlaceNamesMoveProvider);
      return HomeLocationApi(ref.watch(engineClientProvider)).read();
    });

/// Sends a name an older build kept on this phone to the engine, once a
/// run of the app, and reads home again when it did.
final FutureProvider<void> homePlaceNamesMoveProvider = FutureProvider<void>((
  ref,
) async {
  final moved = await moveHomePlaceNames(
    HomeLocationApi(ref.read(engineClientProvider)),
    ref.read(homePlaceNamesStoreProvider),
  );
  if (moved) ref.invalidate(homeLocationProvider);
});

/// Where the phone is, from a fix Android already has.
abstract interface class PhoneLocation {
  /// Asks for location access, and is true when it is granted.
  Future<bool> ask();

  /// The last fix, or null without access or a fix.
  Future<({double latitude, double longitude})?> here();
}

/// The phone's location through the same location permission Wi-Fi places
/// and presence use.
class AndroidPhoneLocation implements PhoneLocation {
  const AndroidPhoneLocation([this.permissions = const Permissions()]);

  final Permissions permissions;

  @override
  Future<bool> ask() => permissions.askForWifiName();

  @override
  Future<({double latitude, double longitude})?> here() =>
      permissions.lastLocation();
}

final phoneLocationProvider = Provider<PhoneLocation>(
  (ref) => const AndroidPhoneLocation(),
);

/// A city picked for home, and where it is.
typedef NamedPlace = ({String name, double latitude, double longitude});

/// The names of places picked for home, as older builds kept them on this
/// phone, in `home_place_names.json`, before `home.location` kept the
/// name. Only read once, to send the name to the engine, then deleted.
abstract interface class HomePlaceNamesStore {
  Future<List<NamedPlace>> read();
  Future<void> delete();
}

class FileHomePlaceNamesStore implements HomePlaceNamesStore {
  const FileHomePlaceNamesStore();

  Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}/home_place_names.json',
  );

  @override
  Future<List<NamedPlace>> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final json = jsonDecode(await file.readAsString());
      return [
        for (final p in json is List ? json : const [])
          if (p is Map &&
              p['name'] is String &&
              p['latitude'] is num &&
              p['longitude'] is num)
            (
              name: p['name'] as String,
              latitude: (p['latitude'] as num).toDouble(),
              longitude: (p['longitude'] as num).toDouble(),
            ),
      ];
    } on Object {
      // Damaged, or no storage here (tests): no names.
      return const [];
    }
  }

  @override
  Future<void> delete() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } on Object {
      // No storage here (tests), or already gone.
    }
  }
}

/// Holds the names in memory, for tests.
class MemoryHomePlaceNamesStore implements HomePlaceNamesStore {
  MemoryHomePlaceNamesStore([List<NamedPlace>? places]) : places = [...?places];

  List<NamedPlace> places;
  var deleted = false;

  @override
  Future<List<NamedPlace>> read() async => deleted ? const [] : places;

  @override
  Future<void> delete() async {
    places = [];
    deleted = true;
  }
}

final homePlaceNamesStoreProvider = Provider<HomePlaceNamesStore>(
  (ref) => const FileHomePlaceNamesStore(),
);

/// Sends the engine the name [store] kept on this phone for home's place,
/// when the engine has none, then deletes [store]'s file. True when it
/// sent a name. A read or a send that fails keeps the file, so the next
/// run of the app tries again.
Future<bool> moveHomePlaceNames(
  HomeLocationApi api,
  HomePlaceNamesStore store,
) async {
  final kept = await store.read();
  if (kept.isEmpty) return false;
  final view = await api.read();
  if (view == null) return false;
  final match = view.isSet && view.name == null
      ? kept.where((p) => _same(p, view.latitude!, view.longitude!)).firstOrNull
      : null;
  if (match != null) {
    final sent = await api.set(
      view.latitude!,
      view.longitude!,
      name: match.name,
    );
    if (sent['ok'] != true) return false;
  }
  await store.delete();
  return match != null;
}

bool _same(NamedPlace p, double latitude, double longitude) =>
    (p.latitude - latitude).abs() < 0.0005 &&
    (p.longitude - longitude).abs() < 0.0005;

/// What to call home's place: the name the engine keeps with it, else
/// "Near" the listed city closest to it. Null when home is not set or is
/// far from every listed city.
String? homePlaceName(HomeLocationView? view) {
  if (view == null || !view.isSet) return null;
  if (view.name case final name?) return name;
  final near = nearestCity(view.latitude!, view.longitude!);
  return near == null ? null : 'Near ${near.label}';
}

void openHomeLocation(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const HomeLocationPage()));

/// "06:41", in the phone's own clock format.
String clockOf(BuildContext context, DateTime? at) =>
    at == null ? 'none today' : TimeOfDay.fromDateTime(at).format(context);

/// Settings' Home location row: the city home is in and today's sun
/// there, or that it is not set.
class HomeLocationRow extends ConsumerWidget {
  const HomeLocationRow({super.key, this.divider = true});

  final bool divider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeLocationProvider).value;
    final name = homePlaceName(home);
    final sun = home?.isSet == true
        ? 'sunrise ${clockOf(context, home!.sunrise)}, '
              'sunset ${clockOf(context, home.sunset)}'
        : null;
    return OmniListRow(
      key: const ValueKey('settings-home-location'),
      icon: OmniIcons.sun,
      title: 'Home location',
      subtitle: switch ((name, sun)) {
        (final String n, final String s) => '$n · $s',
        (null, final String s) => 'Set · $s',
        _ => 'Not set. Sunrise and sunset automations and the weather need it',
      },
      subtitleLines: 2,
      chevron: true,
      divider: divider,
      onTap: () => openHomeLocation(context),
    );
  }
}

/// Where home is: this phone's location, a city from the list, or, under
/// Advanced, latitude and longitude, with today's sunrise and sunset there.
class HomeLocationPage extends ConsumerStatefulWidget {
  const HomeLocationPage({super.key});

  @override
  ConsumerState<HomeLocationPage> createState() => _HomeLocationPageState();
}

class _HomeLocationPageState extends ConsumerState<HomeLocationPage> {
  final _city = TextEditingController();
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  var _filled = false;
  var _busy = false;
  String? _problem;

  @override
  void dispose() {
    _city.dispose();
    _latitude.dispose();
    _longitude.dispose();
    super.dispose();
  }

  static String _fixed(double v) => v.toStringAsFixed(4);

  Future<void> _save(double latitude, double longitude, {String? name}) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    final r = await HomeLocationApi(ref.read(engineClientProvider))
        .set(latitude, longitude, name: name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      setState(() => _problem = errorMessage(r));
      return;
    }
    _latitude.text = _fixed(latitude);
    _longitude.text = _fixed(longitude);
    _city.clear();
    ref
      ..invalidate(homeLocationProvider)
      ..invalidate(sunlightProvider);
    showMessage(name == null ? 'Home location saved' : 'Home is in $name');
  }

  Future<void> _useThisPhone() async {
    final phone = ref.read(phoneLocationProvider);
    setState(() => _problem = null);
    if (!await phone.ask()) {
      if (mounted) {
        setState(
          () => _problem =
              'OmniFlow needs location access to read where this phone is. '
              'Allow it, or search for your city below.',
        );
      }
      return;
    }
    final here = await phone.here();
    if (!mounted) return;
    if (here == null) {
      setState(
        () => _problem =
            'This phone has no location yet. Turn on location in Android, '
            'open a map once, then try again. Or search for your city below.',
      );
      return;
    }
    await _save(here.latitude, here.longitude);
  }

  Future<void> _saveTyped() async {
    final lat = double.tryParse(_latitude.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_longitude.text.trim().replaceAll(',', '.'));
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      setState(
        () => _problem =
            'Type both as numbers in degrees. Latitude is -90 to 90 and '
            'longitude -180 to 180, with north and east positive.',
      );
      return;
    }
    await _save(lat, lon);
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(homeLocationProvider);
    final view = home.value;
    final name = homePlaceName(view);
    if (!_filled && view != null) {
      _filled = true;
      if (view.isSet) {
        _latitude.text = _fixed(view.latitude!);
        _longitude.text = _fixed(view.longitude!);
      }
    }
    final set = view?.isSet == true;
    final query = _city.text.trim();
    final found = searchCities(query);
    return DetailPage(
      key: const ValueKey('home-location-page'),
      title: 'Home location',
      hero: OmniHeroCard(
        key: const ValueKey('home-location-hero'),
        tone: set ? HeroTone.accent : HeroTone.plain,
        icon: OmniIcons.sun,
        title: set
            ? 'Sunrise ${clockOf(context, view!.sunrise)}, '
                  'sunset ${clockOf(context, view.sunset)}'
            : home.isLoading
            ? 'Reading where home is'
            : 'Not set yet',
        subtitle: set
            ? 'Today in ${name ?? 'your home'}'
            : 'Sunrise and sunset automations, the weather and Follow '
                  'the sun need to know where home is.',
      ),
      children: (context) => [
        if (_problem case final p?)
          OmniBanner.warning(p, key: const ValueKey('home-location-problem')),
        OmniButton(
          key: const ValueKey('home-location-use-phone'),
          label: 'Use this phone\'s location',
          icon: OmniIcons.place,
          onPressed: _busy ? null : _useThisPhone,
        ),
        Padding(
          padding: const EdgeInsets.only(top: OmniSpace.xs),
          child: Text(
            'Do this while you are at home. It uses the same location '
            'access as knowing when you are home.',
            style: OmniText.captionOf(context),
          ),
        ),
        const OmniSectionHeader('Or pick your city'),
        TextField(
          key: const ValueKey('home-location-search'),
          controller: _city,
          textInputAction: TextInputAction.search,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            prefixIcon: Icon(OmniIcons.search),
            hintText: 'Search for your city',
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (query.isNotEmpty && found.isEmpty)
          Padding(
            key: const ValueKey('home-location-no-city'),
            padding: const EdgeInsets.only(top: OmniSpace.sm),
            child: Text(
              'No city by that name in the list. Try the nearest big city, '
              'or use this phone\'s location.',
              style: OmniText.captionOf(context),
            ),
          ),
        for (final c in found)
          OmniListRow(
            key: ValueKey('home-location-city-${c.name}'),
            icon: OmniIcons.place,
            title: c.name,
            subtitle: c.country,
            onTap: _busy
                ? null
                : () => _save(c.latitude, c.longitude, name: c.label),
          ),
        const SizedBox(height: OmniSpace.md),
        OmniDisclosure(
          key: const ValueKey('home-location-advanced'),
          icon: OmniIcons.tune,
          title: 'Advanced',
          summary: 'Type latitude and longitude',
          children: [
            _NumberField(
              key: const ValueKey('home-location-latitude'),
              controller: _latitude,
              label: 'Latitude',
              hint: 'In degrees, north is positive',
            ),
            _NumberField(
              key: const ValueKey('home-location-longitude'),
              controller: _longitude,
              label: 'Longitude',
              hint: 'In degrees, east is positive',
            ),
            OmniButton.ghost(
              key: const ValueKey('home-location-save'),
              label: 'Save this place',
              onPressed: _busy ? null : _saveTyped,
            ),
            const SizedBox(height: OmniSpace.sm),
          ],
        ),
        const OmniSectionHeader('What uses it'),
        OmniListRow(
          key: const ValueKey('home-location-sun'),
          icon: OmniIcons.sun,
          title: 'Follow the sun',
          subtitle: set
              ? 'Lights follow today\'s sun at home'
              : 'Turns on once home is set',
          chevron: true,
          onTap: () => openSunLighting(context),
        ),
        Padding(
          padding: const EdgeInsets.only(top: OmniSpace.sm),
          child: Text(
            'Sunrise and sunset are worked out on your own devices. If you '
            'add the weather, this place, rounded, is sent to Open-Meteo to '
            'read the forecast.',
            style: OmniText.captionOf(context),
          ),
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: OmniSpace.md),
    child: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        signed: true,
        decimal: true,
      ),
      decoration: InputDecoration(labelText: label, helperText: hint),
    ),
  );
}
