import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../service/permissions.dart';
import '../design/design.dart';
import '../settings/places_page.dart' show PlacesPage, zonesProvider;
import 'home_presence.dart';

/// The Android switches the service reads in `Permissions.status`, and
/// the system pages that turn them on.
abstract interface class PhoneSwitches {
  /// `{locationOn, exactAlarms, ...}`, or null off Android.
  Future<Map<String, Object?>?> status();
  Future<void> openLocationSwitch();
  Future<void> openExactAlarms();
}

class AndroidPhoneSwitches implements PhoneSwitches {
  const AndroidPhoneSwitches([this.permissions = const Permissions()]);

  final Permissions permissions;

  @override
  Future<Map<String, Object?>?> status() => permissions.status();

  @override
  Future<void> openLocationSwitch() => permissions.openLocationSwitch();

  @override
  Future<void> openExactAlarms() => permissions.askForExactAlarms();
}

final phoneSwitchesProvider = Provider<PhoneSwitches>(
  (ref) => const AndroidPhoneSwitches(),
);

/// What the phone's switches are now. Read again each time the app comes
/// back, so a switch turned on in Android's settings clears its notice.
final phoneSwitchStatusProvider = FutureProvider<Map<String, Object?>?>((
  ref,
) async {
  try {
    return await ref.watch(phoneSwitchesProvider).status();
  } on Object {
    return null;
  }
});

/// One thing on Home that stops part of OmniFlow from working, with the
/// button that fixes it.
class HomeNotice {
  const HomeNotice({
    required this.id,
    required this.message,
    required this.action,
    required this.onAction,
    this.warning = true,
  });

  final String id;
  final String message;
  final String action;
  final VoidCallback onAction;
  final bool warning;
}

/// The notices for [presence], the phone's [status] switches and whether
/// any place uses Wi-Fi ([wifiPlace]).
List<HomeNotice> homeNotices({
  required PresenceShown? presence,
  required Map<String, Object?>? status,
  required bool wifiPlace,
  required VoidCallback setUpPresence,
  required VoidCallback turnOnLocation,
  required VoidCallback allowAlarms,
}) => [
  if (presence == PresenceShown.notSetUp)
    HomeNotice(
      id: 'presence',
      message:
          '$presenceNotSetUp. OmniFlow cannot tell yet whether you are home, '
          'so it does not say you are away.',
      action: 'Set up presence',
      onAction: setUpPresence,
      warning: false,
    ),
  if (wifiPlace && status?['locationOn'] == false)
    HomeNotice(
      id: 'location-off',
      message: 'Location is off, so arriving by Wi-Fi cannot be seen.',
      action: 'Turn on location',
      onAction: turnOnLocation,
    ),
  if (status?['exactAlarms'] == false)
    HomeNotice(
      id: 'alarms-off',
      message:
          'Alarms and reminders is off, so timed automations may run late.',
      action: 'Allow it',
      onAction: allowAlarms,
    ),
];

/// Home's notice: presence that nothing detects, or an Android switch
/// that stops arrivals or timed automations from working. At most one
/// shows, in that order.
class HomeNotices extends ConsumerStatefulWidget {
  const HomeNotices({super.key, required this.devices});

  final List<DeviceView> devices;

  @override
  ConsumerState<HomeNotices> createState() => _HomeNoticesState();
}

class _HomeNoticesState extends ConsumerState<HomeNotices> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.invalidate(phoneSwitchStatusProvider),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zones = ref.watch(zonesProvider).value ?? const <Json>[];
    final switches = ref.read(phoneSwitchesProvider);
    final notices = homeNotices(
      presence: watchPresence(ref, widget.devices),
      status: ref.watch(phoneSwitchStatusProvider).value,
      wifiPlace: zones.any((z) => z['wifi'] is Map && zoneDetects(z)),
      setUpPresence: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const PlacesPage())),
      turnOnLocation: switches.openLocationSwitch,
      allowAlarms: switches.openExactAlarms,
    );
    if (notices.isEmpty) return const SizedBox.shrink();
    // One notice at a time, the one that matters most, so Home stays calm.
    // The next shows once it is fixed.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final n in notices.take(1))
          n.warning
              ? OmniBanner.warning(
                  n.message,
                  key: ValueKey('home-notice-${n.id}'),
                  actionLabel: n.action,
                  onAction: n.onAction,
                )
              : OmniBanner.info(
                  n.message,
                  key: ValueKey('home-notice-${n.id}'),
                  actionLabel: n.action,
                  onAction: n.onAction,
                  showIcon: true,
                  icon: OmniIcons.place,
                ),
      ],
    );
  }
}
