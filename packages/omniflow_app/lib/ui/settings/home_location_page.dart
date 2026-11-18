import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/home_location_calls.dart';
import '../../service/permissions.dart';
import '../../state/providers.dart';
import '../automations/sun_lighting_page.dart'
    show openSunLighting, sunlightProvider;
import '../design/design.dart';

/// Where home is, or null while it loads, when it is not set, or when the
/// engine did not answer.
final homeLocationProvider = FutureProvider.autoDispose<HomeLocationView?>(
  (ref) => HomeLocationApi(ref.watch(engineClientProvider)).read(),
);

/// Where the phone is, from a fix Android already has.
abstract interface class PhoneLocation {
  /// Asks for location access, and is true when it is granted.
  Future<bool> ask();

  /// The last fix, or null without access or a fix.
  Future<({double latitude, double longitude})?> here();
}

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

void openHomeLocation(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const HomeLocationPage()));

/// "06:41", in the phone's own clock format.
String clockOf(BuildContext context, DateTime? at) =>
    at == null ? 'none today' : TimeOfDay.fromDateTime(at).format(context);

/// Settings' Home location row: where home is, or that it is not set.
class HomeLocationRow extends ConsumerWidget {
  const HomeLocationRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeLocationProvider).value;
    return OmniListRow(
      key: const ValueKey('settings-home-location'),
      icon: OmniIcons.place,
      title: 'Home location',
      subtitle: home?.isSet == true
          ? 'Sunrise ${clockOf(context, home!.sunrise)}, '
                'sunset ${clockOf(context, home.sunset)}'
          : 'Not set. Sunrise, sunset, the weather and Follow the sun need it',
      subtitleLines: 2,
      chevron: true,
      onTap: () => openHomeLocation(context),
    );
  }
}

/// Where home is: from this phone's last location, or typed as latitude
/// and longitude, with today's sunrise and sunset there.
class HomeLocationPage extends ConsumerStatefulWidget {
  const HomeLocationPage({super.key});

  @override
  ConsumerState<HomeLocationPage> createState() => _HomeLocationPageState();
}

class _HomeLocationPageState extends ConsumerState<HomeLocationPage> {
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  var _filled = false;
  var _busy = false;
  String? _problem;

  @override
  void dispose() {
    _latitude.dispose();
    _longitude.dispose();
    super.dispose();
  }

  static String _fixed(double v) => v.toStringAsFixed(4);

  Future<void> _save(double latitude, double longitude) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    final r = await HomeLocationApi(ref.read(engineClientProvider))
        .set(latitude, longitude);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      setState(() => _problem = errorMessage(r));
      return;
    }
    _latitude.text = _fixed(latitude);
    _longitude.text = _fixed(longitude);
    ref
      ..invalidate(homeLocationProvider)
      ..invalidate(sunlightProvider);
    showMessage('Home location saved');
  }

  Future<void> _useThisPhone() async {
    final phone = ref.read(phoneLocationProvider);
    setState(() => _problem = null);
    if (!await phone.ask()) {
      if (mounted) {
        setState(
          () => _problem =
              'OmniFlow needs location access to read where this phone is. '
              'Allow it, or type the place below.',
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
            'open a map once, then try again. Or type the place below.',
      );
      return;
    }
    await _save(here.latitude, here.longitude);
  }

  Future<void> _saveTyped() async {
    final lat = double.tryParse(_latitude.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_longitude.text.trim().replaceAll(',', '.'));
    if (lat == null || lon == null) {
      setState(
        () => _problem =
            'Type both as numbers, like 51.5074 and -0.1278. North and '
            'east are positive.',
      );
      return;
    }
    await _save(lat, lon);
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(homeLocationProvider);
    final view = home.value;
    if (!_filled && view != null) {
      _filled = true;
      if (view.isSet) {
        _latitude.text = _fixed(view.latitude!);
        _longitude.text = _fixed(view.longitude!);
      }
    }
    final set = view?.isSet == true;
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
            ? 'Today at home, ${_fixed(view!.latitude!)}, '
                  '${_fixed(view.longitude!)}'
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
          padding: EdgeInsets.only(top: OmniSpace.xs),
          child: Text(
            'Do this while you are at home.',
            style: OmniText.captionOf(context),
          ),
        ),
        const OmniSectionHeader('Or type it'),
        _NumberField(
          key: const ValueKey('home-location-latitude'),
          controller: _latitude,
          label: 'Latitude',
          hint: '51.5074, north is positive',
        ),
        _NumberField(
          key: const ValueKey('home-location-longitude'),
          controller: _longitude,
          label: 'Longitude',
          hint: '-0.1278, east is positive',
        ),
        OmniButton.ghost(
          key: const ValueKey('home-location-save'),
          label: 'Save this place',
          onPressed: _busy ? null : _saveTyped,
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
          padding: EdgeInsets.only(top: OmniSpace.sm),
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
