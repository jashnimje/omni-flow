import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nfc/nfc.dart';
import '../../service/permissions.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/device_text.dart';

/// What Android lets OmniFlow do on this phone. Null means not known (off
/// Android, or the system did not say).
class PhoneAccessState {
  const PhoneAccessState({
    this.localNetwork,
    this.localNetworkNeeded = false,
    this.location,
    this.locationAlways,
    this.notifications,
    this.nfc,
    this.batteryUnrestricted,
    this.running,
  });

  final bool? localNetwork;

  /// Whether this Android asks for local network access at all (17 on).
  final bool localNetworkNeeded;
  final bool? location;

  /// Location all the time: without it Android hides the Wi-Fi name from
  /// the background service, so a Wi-Fi place works only while OmniFlow is
  /// open.
  final bool? locationAlways;
  final bool? notifications;
  final bool? nfc;

  /// True when battery optimisation is off for OmniFlow.
  final bool? batteryUnrestricted;

  /// Whether the background service runs.
  final bool? running;

  bool get backgroundOk => running != false && batteryUnrestricted != false;
}

/// Reads and asks for what the screens need. Every call is safe off
/// Android: it answers unknown or false and never throws.
abstract interface class PhoneAccess {
  Future<PhoneAccessState> read();
  Future<bool> askLocalNetwork();
  Future<bool> askLocation();
  Future<bool> askLocationAlways();
  Future<bool> askNotifications();

  /// Asks Android to stop optimising OmniFlow for battery, or opens the
  /// system list where the user can.
  Future<bool> fixBattery();
  Future<void> openAppSettings();
}

class AndroidPhoneAccess implements PhoneAccess {
  const AndroidPhoneAccess({
    required this.nfc,
    this.permissions = const Permissions(),
  });

  final NfcAdapter nfc;
  final Permissions permissions;

  static Future<T?> _try<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }

  @override
  Future<PhoneAccessState> read() async {
    final status = await permissions.status();
    final notify = await _try(
      FlutterForegroundTask.checkNotificationPermission,
    );
    return PhoneAccessState(
      localNetwork: status?['localNetwork'] as bool?,
      localNetworkNeeded: status?['localNetworkNeeded'] == true,
      location: status?['location'] as bool?,
      locationAlways: status?['locationAlways'] as bool?,
      notifications: notify == null
          ? null
          : notify == NotificationPermission.granted,
      nfc: await _try(nfc.isAvailable),
      batteryUnrestricted: await _try(
        () => FlutterForegroundTask.isIgnoringBatteryOptimizations,
      ),
      running: await _try(() => FlutterForegroundTask.isRunningService),
    );
  }

  @override
  Future<bool> askLocalNetwork() => permissions.askForLocalNetwork();

  @override
  Future<bool> askLocation() => permissions.askForWifiName();

  @override
  Future<bool> askLocationAlways() => permissions.askForWifiNameAlways();

  @override
  Future<bool> askNotifications() async =>
      await _try(FlutterForegroundTask.requestNotificationPermission) ==
      NotificationPermission.granted;

  @override
  Future<bool> fixBattery() async {
    final asked = await _try(
      FlutterForegroundTask.requestIgnoreBatteryOptimization,
    );
    if (asked == true) return true;
    return await _try(
          FlutterForegroundTask.openIgnoreBatteryOptimizationSettings,
        ) ??
        false;
  }

  @override
  Future<void> openAppSettings() => permissions.openAppSettings();
}

final phoneAccessProvider = Provider<PhoneAccess>(
  (ref) => AndroidPhoneAccess(nfc: ref.watch(nfcAdapterProvider)),
);

final phoneAccessStateProvider = FutureProvider<PhoneAccessState>(
  (ref) => ref.watch(phoneAccessProvider).read(),
);

/// "Allowed", "Not allowed" or "Not needed on this phone".
String accessWord(bool? granted, {bool needed = true}) => !needed
    ? 'Not needed on this Android'
    : switch (granted) {
        true => 'Allowed',
        false => 'Not allowed',
        null => 'Not known',
      };

/// One permission with why OmniFlow needs it and a grant button.
class PermissionRow extends StatelessWidget {
  const PermissionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.why,
    required this.granted,
    required this.onGrant,
    required this.id,
    this.needed = true,
    this.grantLabel = 'Allow',
    this.stateText,
  });

  /// Names the grant button's key, `grant-<id>`.
  final String id;

  /// Said instead of Allowed or Not allowed.
  final String? stateText;

  final IconData icon;
  final String title;
  final String why;
  final bool? granted;
  final bool needed;
  final VoidCallback? onGrant;
  final String grantLabel;

  @override
  Widget build(BuildContext context) {
    final ok = granted == true || !needed;
    return OmniListRow(
      icon: icon,
      title: title,
      subtitle: '$why\n${stateText ?? accessWord(granted, needed: needed)}',
      subtitleLines: 4,
      trailing: ok
          ? const Icon(
              AreaIcons.ok,
              color: OmniColors.accent,
              semanticLabel: 'Allowed',
            )
          : TextButton(
              key: ValueKey('grant-$id'),
              onPressed: onGrant,
              style: TextButton.styleFrom(
                foregroundColor: OmniColors.accent,
                minimumSize: const Size(OmniSpace.target, OmniSpace.target),
              ),
              child: Text(grantLabel),
            ),
    );
  }
}

/// 7.1, This phone: background running with the battery state and a fix
/// button, then each permission with its state and a grant button.
class PhoneAccessPage extends ConsumerStatefulWidget {
  const PhoneAccessPage({super.key});

  @override
  ConsumerState<PhoneAccessPage> createState() => _PhoneAccessPageState();
}

class _PhoneAccessPageState extends ConsumerState<PhoneAccessPage> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // A grant made in the system settings shows when the user comes back.
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.invalidate(phoneAccessStateProvider),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _ask(
    Future<bool> Function(PhoneAccess) ask,
    String refused,
  ) async {
    final ok = await ask(ref.read(phoneAccessProvider));
    ref.invalidate(phoneAccessStateProvider);
    if (!ok) showMessage(refused);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(phoneAccessStateProvider).value;
    final access = ref.read(phoneAccessProvider);
    if (state == null) {
      return const OmniPage(title: 'This phone', body: SizedBox());
    }
    return OmniPage(
      title: 'This phone',
      body: ListView(
        key: const ValueKey('phone-access'),
        children: [
          const OmniSectionHeader('Running in the background'),
          if (!state.backgroundOk)
            OmniBanner.warning(
              state.running == false
                  ? 'OmniFlow is not running, so automations wait until you '
                        'open the app.'
                  : 'Android may stop OmniFlow to save battery, and your '
                        'automations stop with it.',
              key: const ValueKey('background-warning'),
              actionLabel: 'Fix',
              onAction: () => _ask(
                (a) => a.fixBattery(),
                'Turn off battery optimisation for OmniFlow in the list '
                'Android showed.',
              ),
            ),
          OmniListRow(
            key: const ValueKey('background-state'),
            icon: OmniIcons.settings,
            title: state.running == false ? 'Not running' : 'Running',
            subtitle: switch (state.batteryUnrestricted) {
              true => 'Battery saver off for OmniFlow',
              false => 'Battery saver can stop it',
              null => 'Battery saver state not known',
            },
            dot: state.backgroundOk ? StatusKind.online : StatusKind.warning,
          ),
          if (state.batteryUnrestricted == false)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.sm),
              child: OmniButton(
                key: const ValueKey('fix-battery'),
                label: 'Stop battery saver closing OmniFlow',
                onPressed: () => _ask(
                  (a) => a.fixBattery(),
                  'Turn off battery optimisation for OmniFlow in the list '
                  'Android showed.',
                ),
              ),
            ),
          const OmniSectionHeader('Permissions'),
          PermissionRow(
            key: const ValueKey('permission-local-network'),
            id: 'local-network',
            icon: AreaIcons.nearby,
            title: 'Nearby devices and local network',
            why:
                'Lets OmniFlow find and control the lights, plugs, TVs and '
                'boards on your Wi-Fi.',
            granted: state.localNetwork,
            needed: state.localNetworkNeeded,
            onGrant: () => _ask(
              (a) => a.askLocalNetwork(),
              'Without it OmniFlow cannot reach devices on your Wi-Fi. You '
              'can allow it in the system settings.',
            ),
          ),
          PermissionRow(
            key: const ValueKey('permission-location'),
            id: 'location',
            icon: AreaIcons.location,
            title: 'Location',
            why:
                'Android tells apps the Wi-Fi name only with location access. '
                'Places use the name to know when you are home.',
            granted: state.location,
            onGrant: () => _ask(
              (a) => a.askLocation(),
              'Without location access Wi-Fi places cannot tell where you '
              'are.',
            ),
          ),
          if (state.location == true)
            PermissionRow(
              key: const ValueKey('permission-location-always'),
              id: 'location-always',
              icon: AreaIcons.location,
              title: 'Location all the time',
              why:
                  'With the screen off Android hides the Wi-Fi name unless '
                  'location is allowed all the time, so arriving home would '
                  'go unnoticed. Choose "Allow all the time" on the page '
                  'that opens.',
              granted: state.locationAlways,
              onGrant: () => _ask(
                (a) => a.askLocationAlways(),
                'Arriving home works only while OmniFlow is open until '
                'location is allowed all the time.',
              ),
            ),
          PermissionRow(
            key: const ValueKey('permission-nfc'),
            id: 'nfc',
            icon: OmniIcons.tag,
            title: 'NFC',
            why: 'Reads and writes the tags that start automations.',
            granted: state.nfc,
            stateText: switch (state.nfc) {
              true => 'On',
              false => 'Off, or this phone has no NFC',
              null => 'Not known',
            },
            grantLabel: 'Settings',
            onGrant: access.openAppSettings,
          ),
          PermissionRow(
            key: const ValueKey('permission-notifications'),
            id: 'notifications',
            icon: AreaIcons.notify,
            title: 'Notifications',
            why:
                'Shows that OmniFlow is running, and what your automations '
                'announce.',
            granted: state.notifications,
            onGrant: () => _ask(
              (a) => a.askNotifications(),
              'Without notifications you will not see what automations '
              'announce.',
            ),
          ),
          const SizedBox(height: OmniSpace.lg),
          OmniButton.ghost(
            key: const ValueKey('open-app-settings'),
            label: 'Open OmniFlow in system settings',
            onPressed: access.openAppSettings,
          ),
          const SizedBox(height: OmniSpace.xl),
        ],
      ),
    );
  }
}
