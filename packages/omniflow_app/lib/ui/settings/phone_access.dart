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
    this.usageAccess,
    this.notificationAccess,
    this.bluetooth,
    this.bluetoothNeeded = false,
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

  /// Usage access, which "An app opens" triggers need to see the app on
  /// screen.
  final bool? usageAccess;

  /// Notification access, for "A notification arrives from" triggers.
  final bool? notificationAccess;

  /// Bluetooth connect, for "A Bluetooth device connects" triggers.
  final bool? bluetooth;

  /// Whether this Android asks for Bluetooth connect at all (12 on).
  final bool bluetoothNeeded;

  bool get backgroundOk => running != false && batteryUnrestricted != false;
}

/// Asks for what the phone triggers need. The rule editor calls these when
/// the person picks the trigger, and This phone has a row for each. Usage
/// and notification access open their system page, so the answer is known
/// only when the person comes back. Safe off Android: each answers false.
abstract interface class TriggerAccess {
  /// "An app opens": the system's usage access page.
  Future<bool> askUsageAccess();

  /// "A notification arrives from": the system's notification access page.
  Future<bool> askNotificationAccess();

  /// "A Bluetooth device connects": the Bluetooth connect permission.
  Future<bool> askBluetooth();

  /// Opens the picker for the three Quick Settings tiles.
  Future<bool> pickTiles();

  /// Opens the picker for up to four launcher shortcuts.
  Future<bool> pickShortcuts();
}

class AndroidTriggerAccess implements TriggerAccess {
  const AndroidTriggerAccess([this.permissions = const Permissions()]);

  final Permissions permissions;

  @override
  Future<bool> askUsageAccess() => permissions.call('usageAccess');

  @override
  Future<bool> askNotificationAccess() =>
      permissions.call('notificationAccess');

  @override
  Future<bool> askBluetooth() => permissions.call('bluetooth');

  @override
  Future<bool> pickTiles() => permissions.call('pickTiles');

  @override
  Future<bool> pickShortcuts() => permissions.call('pickShortcuts');
}

final triggerAccessProvider = Provider<TriggerAccess>(
  (ref) => const AndroidTriggerAccess(),
);

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
      usageAccess: status?['usageAccess'] as bool?,
      notificationAccess: status?['notificationAccess'] as bool?,
      bluetooth: status?['bluetooth'] as bool?,
      bluetoothNeeded: status?['bluetoothNeeded'] == true,
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
    final accent = OmniPalette.of(context).accent;
    return OmniListRow(
      icon: icon,
      title: title,
      subtitle: '$why\n${stateText ?? accessWord(granted, needed: needed)}',
      subtitleLines: 6,
      trailing: ok
          ? Icon(AreaIcons.ok, color: accent, semanticLabel: 'Allowed')
          : TextButton(
              key: ValueKey('grant-$id'),
              onPressed: onGrant,
              style: TextButton.styleFrom(
                foregroundColor: accent,
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

  Future<void> _askTrigger(
    Future<bool> Function(TriggerAccess) ask,
    String refused,
  ) async {
    final ok = await ask(ref.read(triggerAccessProvider));
    ref.invalidate(phoneAccessStateProvider);
    if (!ok) showMessage(refused);
  }

  /// The phone trigger permissions, then the Run from anywhere pickers.
  /// Hidden where Android did not say (off the phone).
  List<Widget> _triggerRows(PhoneAccessState state) => [
    if (state.usageAccess != null)
      PermissionRow(
        key: const ValueKey('permission-usage-access'),
        id: 'usage-access',
        icon: OmniIcons.phone,
        title: 'Usage access',
        why:
            'Lets "An app opens" automations see which app is on screen. '
            'OmniFlow checks every few seconds while the screen is on, and '
            'only for your automations. Turn on OmniFlow on the page that '
            'opens.',
        granted: state.usageAccess,
        grantLabel: 'Settings',
        onGrant: () => _askTrigger(
          (a) => a.askUsageAccess(),
          'Open Settings, Usage access, and turn on OmniFlow.',
        ),
      ),
    if (state.notificationAccess != null)
      PermissionRow(
        key: const ValueKey('permission-notification-access'),
        id: 'notification-access',
        icon: OmniIcons.notifications,
        title: 'Notification access',
        why:
            'Lets "A notification arrives from" automations start when an '
            'app you pick posts one. The text stays on this phone. Turn on '
            'OmniFlow on the page that opens.',
        granted: state.notificationAccess,
        grantLabel: 'Settings',
        onGrant: () => _askTrigger(
          (a) => a.askNotificationAccess(),
          'Open Settings, Notification access, and turn on OmniFlow.',
        ),
      ),
    if (state.bluetooth != null)
      PermissionRow(
        key: const ValueKey('permission-bluetooth'),
        id: 'bluetooth',
        icon: OmniIcons.bluetooth,
        title: 'Bluetooth devices',
        why:
            'Lets "A Bluetooth device connects" automations know when your '
            'headphones, car or watch connect.',
        granted: state.bluetooth,
        needed: state.bluetoothNeeded,
        onGrant: () => _askTrigger(
          (a) => a.askBluetooth(),
          'Without it OmniFlow cannot tell when a Bluetooth device '
          'connects. You can allow it in the system settings.',
        ),
      ),
    if (state.usageAccess != null) ...[
      const OmniSectionHeader('Run from anywhere'),
      OmniListRow(
        key: const ValueKey('pick-tiles'),
        subtitleLines: 3,
        icon: OmniIcons.automations,
        title: 'Quick Settings tiles',
        subtitle:
            'Pick what each of the three OmniFlow tiles runs. A long press '
            'on a tile opens this too.',
        onTap: () => _askTrigger(
          (a) => a.pickTiles(),
          'OmniFlow could not open the tile picker.',
        ),
      ),
      OmniListRow(
        key: const ValueKey('pick-shortcuts'),
        subtitleLines: 3,
        icon: OmniIcons.star,
        title: 'Launcher shortcuts',
        subtitle:
            'Pick up to four favourites to show when you long press the '
            'OmniFlow icon.',
        onTap: () => _askTrigger(
          (a) => a.pickShortcuts(),
          'OmniFlow could not open the shortcut picker.',
        ),
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(phoneAccessStateProvider);
    final access = ref.read(phoneAccessProvider);
    return FormPage.instant(
      key: const ValueKey('phone-access'),
      title: 'Phone setup',
      state: OmniLoad.of(
        loaded,
        error: 'OmniFlow could not read what this phone allows.',
        onRetry: () => ref.invalidate(phoneAccessStateProvider),
      ),
      children: (context) => [
        if (loaded.value case final state?) ...[
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
          ..._triggerRows(state),
          const SizedBox(height: OmniSpace.lg),
          OmniButton.ghost(
            key: const ValueKey('open-app-settings'),
            label: 'Open OmniFlow in system settings',
            onPressed: access.openAppSettings,
          ),
        ],
      ],
    );
  }
}
