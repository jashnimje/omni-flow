import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show thingIdFor;

import '../../api/engine_calls.dart' show DeviceView;
import '../../state/house.dart' show houseShownProvider, newHomePlace;
import '../../state/providers.dart';
import '../add/add_page.dart' show openAddThing;
import '../automations/automations_state.dart';
import '../automations/new_automation.dart' show openNewAutomation;
import '../design/design.dart';
import '../devices/device_text.dart';
import '../settings/home_location_page.dart'
    show homeLocationProvider, openHomeLocation;
import '../settings/phone_access.dart';
import '../settings/places_page.dart' show homeZone, zonesProvider;

/// The steps of setting up a home, in order.
enum SetupStep { you, home, presence, device, automation }

/// Which setup steps are done, read from the home itself: a person, home's
/// location, a Wi-Fi network at the home place, a device, an automation.
/// Nothing is stored about the setup, so it resumes where the home stands.
class SetupProgress {
  const SetupProgress(this.done, [this.steps = SetupStep.values]);

  final Set<SetupStep> done;

  /// The steps this setup goes through: all of them for the first run,
  /// fewer for a house added later.
  final List<SetupStep> steps;

  int get count => steps.where(done.contains).length;
  bool get complete => count == steps.length;

  /// The first step not done, or null when all are.
  SetupStep? get next => steps.where((s) => !done.contains(s)).firstOrNull;

  /// The same progress over [only].
  SetupProgress over(List<SetupStep> only) => SetupProgress(done, only);
}

final setupProgressProvider = Provider.autoDispose<SetupProgress?>((ref) {
  final devices = ref.watch(devicesProvider).value;
  final zones = ref.watch(zonesProvider).value;
  final home = ref.watch(homeLocationProvider);
  final automations = ref.watch(automationsProvider).value;
  if (devices == null) return null;
  final views = [for (final d in devices) DeviceView(d)];
  final zone = zones == null ? null : homeZone(zones);
  final ssids = (zone?['wifi'] as Map?)?['ssids'] as List? ?? const [];
  return SetupProgress({
    if (views.any((d) => d.driver == 'person')) SetupStep.you,
    if (home.value?.isSet == true) SetupStep.home,
    if (ssids.isNotEmpty) SetupStep.presence,
    if (views.any(
      (d) => d.driver != 'phone' && !presenceDrivers.contains(d.driver),
    ))
      SetupStep.device,
    if (automations?.any((a) => !a.isScene) == true) SetupStep.automation,
  });
});

/// Opens the home setup on its first open step, or on [start]. A house
/// added later goes through only [steps].
Future<void> openHomeSetup(
  BuildContext context, {
  SetupStep? start,
  List<SetupStep> steps = SetupStep.values,
}) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute<void>(
    builder: (_) => HomeSetupPage(start: start, steps: steps),
  ),
);

/// A short setup for a fresh phone: who you are, where home is, how the
/// phone knows you are home, then a first device and a first automation.
/// Every step can be skipped, and Settings opens it again where it stopped.
class HomeSetupPage extends ConsumerStatefulWidget {
  const HomeSetupPage({super.key, this.start, this.steps = SetupStep.values});

  final SetupStep? start;
  final List<SetupStep> steps;

  @override
  ConsumerState<HomeSetupPage> createState() => _HomeSetupPageState();
}

class _HomeSetupPageState extends ConsumerState<HomeSetupPage> {
  SetupStep? _step;
  var _finished = false;
  var _busy = false;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _step = widget.start;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  SetupStep? _current(SetupProgress? progress) {
    if (_finished) return null;
    return _step ?? progress?.next;
  }

  void _go(SetupStep? from) {
    final steps = widget.steps;
    final i = from == null ? -1 : steps.indexOf(from);
    setState(() {
      if (i + 1 >= steps.length) {
        _finished = true;
      } else {
        _step = steps[i + 1];
      }
    });
  }

  void _back(SetupStep step) {
    final i = widget.steps.indexOf(step);
    if (i > 0) setState(() => _step = widget.steps[i - 1]);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Adds the person and makes this phone theirs, so arriving and leaving
  /// home follow this phone.
  Future<void> _addPerson() => _run(() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final api = ref.read(engineApiProvider);
    final devices = ref.read(devicesProvider.notifier);
    final id = thingIdFor(name);
    final added = await api.addDevice({
      'id': id,
      'name': name,
      'driver': 'person',
    });
    if (!added.ok) return;
    final phone = (ref.read(devicesProvider).value ?? const <Json>[])
        .where((d) => d['driver'] == 'phone')
        .firstOrNull;
    if (phone != null) {
      await api.configureThing('${phone['id']}', {'person': id});
    }
    await devices.refresh();
    if (mounted) _go(SetupStep.you);
  });

  /// Makes [ssid] the home place's Wi-Fi.
  Future<void> _useWifi(String ssid) => _run(() async {
    final zones = ref.read(zonesProvider).value ?? const <Json>[];
    final zone = homeZone(zones) ?? newHomePlace(ref.read(houseShownProvider));
    final wifi = zone['wifi'] is Map
        ? Map<String, Object?>.from(zone['wifi'] as Map)
        : <String, Object?>{};
    final saved = await ref.read(engineApiProvider).saveZone({
      ...zone,
      'wifi': {
        ...wifi,
        'ssids': {
          ...(wifi['ssids'] as List? ?? const []).cast<String>(),
          ssid,
        }.toList(),
        'bssids': wifi['bssids'] ?? const <String>[],
        'required': wifi['required'] == true,
      },
    });
    if (!saved.ok) return;
    ref.invalidate(zonesProvider);
    await ref.read(devicesProvider.notifier).refresh();
    if (mounted) _go(SetupStep.presence);
  });

  Future<void> _ask(Future<bool> Function(PhoneAccess access) ask) =>
      _run(() async {
        await ask(ref.read(phoneAccessProvider));
        ref.invalidate(phoneAccessStateProvider);
        await ref.read(devicesProvider.notifier).refresh();
      });

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(setupProgressProvider)?.over(widget.steps);
    final step = _current(progress);
    final house = ref.watch(houseShownProvider);
    final steps = widget.steps;
    final total = steps.length;
    final at = step == null ? total : steps.indexOf(step) + 1;
    final done = step != null && (progress?.done.contains(step) ?? false);
    final (heading, why) = _words(step, progress);
    final (label, key, action) = _primary(step, progress);
    return StepFlow(
      key: ValueKey('setup-${step?.name ?? 'done'}'),
      title: widget.steps.length < SetupStep.values.length && house != null
          ? 'Set up ${house.name}'
          : 'Set up your home',
      count: total,
      current: at,
      heading: heading,
      why: why,
      state: progress == null
          ? const OmniLoad.loading()
          : const OmniLoad.data(),
      onBack: step == null || step == steps.first || _busy
          ? null
          : () => _back(step),
      onSkip: step == null || done || _busy ? null : () => _go(step),
      primaryLabel: label,
      primaryKey: key,
      onPrimary: _busy ? null : action,
      missing: step == SetupStep.you
          ? 'Type your name first.'
          : step == SetupStep.presence
          ? 'Connect this phone to your home Wi-Fi first, or skip.'
          : null,
      children: (context) => [
        ...switch (step) {
          null => const <Widget>[],
          SetupStep.you => _youBody(progress),
          SetupStep.home => _homeBody(progress),
          SetupStep.presence => _presenceBody(progress),
          SetupStep.device => _deviceBody(progress),
          SetupStep.automation => _automationBody(progress),
        },
      ],
    );
  }

  /// The step's title and why line.
  (String, String) _words(SetupStep? step, SetupProgress? p) => switch (step) {
    SetupStep.you => (
      'Who are you?',
      'So automations like "when I get home" know who you are.',
    ),
    SetupStep.home => (
      'Where is home?',
      'For sunrise, sunset and the weather. It stays on this phone.',
    ),
    SetupStep.presence => (
      'How does the phone know you are home?',
      'When the phone joins your home Wi-Fi, you are home. When it '
          'leaves, you are away.',
    ),
    SetupStep.device => (
      'Add your first device',
      'A light, plug, TV or speaker on your Wi-Fi.',
    ),
    SetupStep.automation => (
      'Make your first automation',
      'Something that happens by itself, like the lamp coming on when you '
          'get home.',
    ),
    null when p?.complete ?? false => (
      'Your home is set up',
      'You can change any of it in Settings.',
    ),
    null => (
      'That is all for now',
      'You did ${p?.count ?? 0} of ${widget.steps.length}. Settings, '
          'Set up your home picks up where you stopped.',
    ),
  };

  /// The step's one action in the bottom bar: what it does while the step
  /// is open, Next once it is done.
  (String, Key, VoidCallback?) _primary(SetupStep? step, SetupProgress? p) {
    if (step == null) {
      return (
        'Done',
        const ValueKey('setup-finish'),
        () => Navigator.of(context).pop(),
      );
    }
    final next = ('Next', const ValueKey('setup-next'), () => _go(step));
    if (p?.done.contains(step) ?? false) return next;
    return switch (step) {
      SetupStep.you => _youSave,
      SetupStep.home => (
        'Set home location',
        const ValueKey('setup-home-location'),
        () => openHomeLocation(context),
      ),
      SetupStep.presence => (
        _wifi == null ? 'Use this Wi-Fi' : 'Use $_wifi as home Wi-Fi',
        const ValueKey('setup-use-wifi'),
        _wifi == null ? null : () => _useWifi(_wifi!),
      ),
      SetupStep.device => (
        'Add a device',
        const ValueKey('setup-add-device'),
        () => openAddThing(context),
      ),
      SetupStep.automation => (
        'Make an automation',
        const ValueKey('setup-new-automation'),
        () => openNewAutomation(context),
      ),
    };
  }

  (String, Key, VoidCallback?) get _youSave => (
    'Save',
    const ValueKey('setup-name-save'),
    _name.text.trim().isEmpty ? null : _addPerson,
  );

  /// The Wi-Fi this phone is on now, as the phone thing reports it.
  String? get _wifi {
    final phone = (ref.watch(devicesProvider).value ?? const <Json>[])
        .map(DeviceView.new)
        .where((d) => d.driver == 'phone')
        .firstOrNull;
    final ssid = phone?.state['wifi_ssid'];
    return ssid is String && ssid.isNotEmpty ? ssid : null;
  }

  Widget _doneLine(String text, {Key? key}) => OmniBanner.info(text, key: key);

  List<Widget> _youBody(SetupProgress? p) {
    final people = (ref.watch(devicesProvider).value ?? const <Json>[])
        .where((d) => d['driver'] == 'person')
        .map((d) => '${d['name'] ?? d['id']}')
        .toList();
    return [
      if (people.isNotEmpty)
        _doneLine(
          'You are set up as ${people.join(', ')}.',
          key: const ValueKey('setup-you-done'),
        )
      else
        TextField(
          key: const ValueKey('setup-name'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your name'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _addPerson(),
        ),
    ];
  }

  List<Widget> _homeBody(SetupProgress? p) => [
    if (p?.done.contains(SetupStep.home) ?? false) ...[
      _doneLine(
        'Home\'s location is set.',
        key: const ValueKey('setup-home-done'),
      ),
      OmniButton.ghost(
        key: const ValueKey('setup-home-change'),
        label: 'Change home location',
        onPressed: _busy ? null : () => openHomeLocation(context),
      ),
    ],
  ];

  List<Widget> _presenceBody(SetupProgress? p) {
    final access = ref.watch(phoneAccessStateProvider).value;
    return [
      _PermissionRow(
        id: 'location',
        title: '1. Allow location',
        why: 'Android shows the Wi-Fi name only with location on',
        granted: access?.location,
        onAllow: _busy ? null : () => _ask((a) => a.askLocation()),
      ),
      _PermissionRow(
        id: 'location-always',
        title: '2. Allow it all the time',
        why:
            'So it still notices with the screen off. Pick "Allow all the '
            'time" on the next screen',
        granted: access?.locationAlways,
        onAllow: _busy ? null : () => _ask((a) => a.askLocationAlways()),
      ),
      const SizedBox(height: OmniSpace.sm),
      if (p?.done.contains(SetupStep.presence) ?? false)
        _doneLine(
          'Home has its Wi-Fi. Arriving and leaving now work.',
          key: const ValueKey('setup-presence-done'),
        )
      else if (_wifi == null)
        Text(
          '3. Connect this phone to your home Wi-Fi, then come back here. '
          'The network shows here once Android lets OmniFlow see it.',
          key: ValueKey('setup-no-wifi'),
          style: OmniText.captionOf(context),
        ),
    ];
  }

  List<Widget> _deviceBody(SetupProgress? p) => [
    if (p?.done.contains(SetupStep.device) ?? false) ...[
      _doneLine(
        'You have a device. Add more any time from Devices.',
        key: const ValueKey('setup-device-done'),
      ),
      OmniButton.ghost(
        key: const ValueKey('setup-add-another'),
        label: 'Add another device',
        icon: OmniIcons.add,
        onPressed: _busy ? null : () => openAddThing(context),
      ),
    ],
  ];

  List<Widget> _automationBody(SetupProgress? p) => [
    if (p?.done.contains(SetupStep.automation) ?? false) ...[
      _doneLine(
        'You have an automation. Find it under Automations.',
        key: const ValueKey('setup-automation-done'),
      ),
      OmniButton.ghost(
        key: const ValueKey('setup-new-another'),
        label: 'Make another automation',
        icon: OmniIcons.automations,
        onPressed: _busy ? null : () => openNewAutomation(context),
      ),
    ],
  ];
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.id,
    required this.title,
    required this.why,
    required this.granted,
    required this.onAllow,
  });

  final String id;
  final String title;
  final String why;
  final bool? granted;
  final VoidCallback? onAllow;

  @override
  Widget build(BuildContext context) => OmniListRow(
    key: ValueKey('setup-permission-$id'),
    title: title,
    subtitle: why,
    subtitleLines: 2,
    value: granted == true ? 'Allowed' : null,
    trailing: granted == true
        ? null
        : TextButton(
            key: ValueKey('setup-allow-$id'),
            onPressed: onAllow,
            style: TextButton.styleFrom(
              minimumSize: const Size(OmniSpace.target, OmniSpace.target),
            ),
            child: Text('Allow', semanticsLabel: 'Allow: $title'),
          ),
  );
}

/// The Settings row that opens the home setup again, with how far it got.
class HomeSetupRow extends ConsumerWidget {
  const HomeSetupRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(setupProgressProvider);
    return OmniListRow(
      key: const ValueKey('settings-home-setup'),
      icon: OmniIcons.home,
      title: 'Set up your home',
      subtitle: p == null
          ? 'Who you are, where home is, how the phone knows'
          : p.complete
          ? 'All done'
          : '${p.count} of ${SetupStep.values.length} done. Pick up where '
                'you stopped',
      dot: p == null || p.complete ? null : StatusKind.warning,
      chevron: true,
      onTap: () => openHomeSetup(context),
    );
  }
}
