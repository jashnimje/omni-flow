import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show thingIdFor;

import '../../api/engine_calls.dart' show DeviceView;
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
  const SetupProgress(this.done);

  final Set<SetupStep> done;

  int get count => done.length;
  bool get complete => done.length == SetupStep.values.length;

  /// The first step not done, or null when all are.
  SetupStep? get next =>
      SetupStep.values.where((s) => !done.contains(s)).firstOrNull;
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

/// Opens the home setup on its first open step, or on [start].
Future<void> openHomeSetup(BuildContext context, {SetupStep? start}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => HomeSetupPage(start: start)),
    );

/// A short setup for a fresh phone: who you are, where home is, how the
/// phone knows you are home, then a first device and a first automation.
/// Every step can be skipped, and Settings opens it again where it stopped.
class HomeSetupPage extends ConsumerStatefulWidget {
  const HomeSetupPage({super.key, this.start});

  final SetupStep? start;

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
    final i = from == null ? -1 : SetupStep.values.indexOf(from);
    setState(() {
      if (i + 1 >= SetupStep.values.length) {
        _finished = true;
      } else {
        _step = SetupStep.values[i + 1];
      }
    });
  }

  void _back(SetupStep step) {
    final i = SetupStep.values.indexOf(step);
    if (i > 0) setState(() => _step = SetupStep.values[i - 1]);
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
    final zone = homeZone(zones) ?? const {'id': 'home', 'name': 'Home'};
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
    final progress = ref.watch(setupProgressProvider);
    final step = _current(progress);
    return OmniPage(
      title: 'Set up your home',
      actions: [
        TextButton(
          key: const ValueKey('setup-not-now'),
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            minimumSize: const Size(OmniSpace.target, OmniSpace.target),
          ),
          child: const Text('Not now'),
        ),
      ],
      body: progress == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: ValueKey('setup-${step?.name ?? 'done'}'),
              children: [
                _StepBar(step: step, progress: progress),
                const SizedBox(height: OmniSpace.md),
                ...switch (step) {
                  null => _doneBody(progress),
                  SetupStep.you => _youBody(progress),
                  SetupStep.home => _homeBody(progress),
                  SetupStep.presence => _presenceBody(progress),
                  SetupStep.device => _deviceBody(progress),
                  SetupStep.automation => _automationBody(progress),
                },
                if (step != null) ...[
                  const SizedBox(height: OmniSpace.sm),
                  Row(
                    children: [
                      if (step != SetupStep.values.first)
                        TextButton(
                          key: const ValueKey('setup-back'),
                          onPressed: _busy ? null : () => _back(step),
                          child: const Text('Back'),
                        ),
                      const Spacer(),
                      TextButton(
                        key: const ValueKey('setup-skip'),
                        onPressed: _busy ? null : () => _go(step),
                        child: Text(
                          progress.done.contains(step) ? 'Next' : 'Skip',
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  Widget _title(String title, String why) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(header: true, child: Text(title, style: OmniText.titleMedium)),
      const SizedBox(height: 4),
      Text(why, style: OmniText.body),
      const SizedBox(height: OmniSpace.md),
    ],
  );

  Widget _doneLine(String text, {Key? key}) => OmniBanner.info(text, key: key);

  List<Widget> _youBody(SetupProgress p) {
    final people = (ref.watch(devicesProvider).value ?? const <Json>[])
        .where((d) => d['driver'] == 'person')
        .map((d) => '${d['name'] ?? d['id']}')
        .toList();
    return [
      _title(
        'Who are you?',
        'Your name, so automations like "when I get home" know who is '
            'meant, and Home can greet you.',
      ),
      if (people.isNotEmpty)
        _doneLine(
          'You are set up as ${people.join(', ')}.',
          key: const ValueKey('setup-you-done'),
        )
      else ...[
        TextField(
          key: const ValueKey('setup-name'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your name'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _addPerson(),
        ),
        const SizedBox(height: OmniSpace.md),
        OmniButton(
          key: const ValueKey('setup-name-save'),
          label: 'Save',
          onPressed: _busy || _name.text.trim().isEmpty ? null : _addPerson,
        ),
      ],
    ];
  }

  List<Widget> _homeBody(SetupProgress p) => [
    _title(
      'Where is home?',
      'Sunrise and sunset, the weather and Follow the sun all need to know '
          'roughly where home is. It stays on this phone.',
    ),
    if (p.done.contains(SetupStep.home))
      _doneLine(
        'Home\'s location is set.',
        key: const ValueKey('setup-home-done'),
      ),
    OmniButton(
      key: const ValueKey('setup-home-location'),
      label: p.done.contains(SetupStep.home)
          ? 'Change home location'
          : 'Set home location',
      kind: p.done.contains(SetupStep.home)
          ? OmniButtonKind.ghost
          : OmniButtonKind.primary,
      onPressed: _busy
          ? null
          : () async {
              openHomeLocation(context);
            },
    ),
  ];

  List<Widget> _presenceBody(SetupProgress p) {
    final access = ref.watch(phoneAccessStateProvider).value;
    final phone = (ref.watch(devicesProvider).value ?? const <Json>[])
        .map(DeviceView.new)
        .where((d) => d.driver == 'phone')
        .firstOrNull;
    final ssid = phone?.state['wifi_ssid'];
    final wifi = ssid is String && ssid.isNotEmpty ? ssid : null;
    return [
      _title(
        'How does the phone know you are home?',
        'When the phone joins your home Wi-Fi, you are home. When it leaves '
            'for a few minutes, you are away. Android shows the Wi-Fi name '
            'only to apps allowed to use location.',
      ),
      _PermissionRow(
        id: 'location',
        title: '1. Allow location',
        why: 'So OmniFlow can read the Wi-Fi name',
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
      if (p.done.contains(SetupStep.presence))
        _doneLine(
          'Home has its Wi-Fi. Arriving and leaving now work.',
          key: const ValueKey('setup-presence-done'),
        )
      else if (wifi != null)
        OmniButton(
          key: const ValueKey('setup-use-wifi'),
          label: 'Use $wifi as home Wi-Fi',
          onPressed: _busy ? null : () => _useWifi(wifi),
        )
      else
        const Text(
          '3. Connect this phone to your home Wi-Fi, then come back here. '
          'The network shows here once Android lets OmniFlow see it.',
          key: ValueKey('setup-no-wifi'),
          style: OmniText.caption,
        ),
    ];
  }

  List<Widget> _deviceBody(SetupProgress p) => [
    _title(
      'Add your first device',
      'A light, plug, TV or speaker on your Wi-Fi. OmniFlow looks for them '
          'first, and you can add one by hand.',
    ),
    if (p.done.contains(SetupStep.device))
      _doneLine(
        'You have a device. Add more any time from Devices.',
        key: const ValueKey('setup-device-done'),
      ),
    OmniButton(
      key: const ValueKey('setup-add-device'),
      label: 'Add a device',
      icon: OmniIcons.add,
      kind: p.done.contains(SetupStep.device)
          ? OmniButtonKind.ghost
          : OmniButtonKind.primary,
      onPressed: _busy ? null : () => openAddThing(context),
    ),
  ];

  List<Widget> _automationBody(SetupProgress p) => [
    _title(
      'Make your first automation',
      'Something that happens by itself, like turn on the lamp when I get '
          'home, or switch everything off at bedtime.',
    ),
    if (p.done.contains(SetupStep.automation))
      _doneLine(
        'You have an automation. Find it under Automations.',
        key: const ValueKey('setup-automation-done'),
      ),
    OmniButton(
      key: const ValueKey('setup-new-automation'),
      label: 'Make an automation',
      icon: OmniIcons.automations,
      kind: p.done.contains(SetupStep.automation)
          ? OmniButtonKind.ghost
          : OmniButtonKind.primary,
      onPressed: _busy ? null : () => openNewAutomation(context),
    ),
  ];

  List<Widget> _doneBody(SetupProgress p) => [
    _title(
      p.complete ? 'Your home is set up' : 'That is all for now',
      p.complete
          ? 'You can change any of it in Settings.'
          : 'You did ${p.count} of ${SetupStep.values.length}. Settings, '
                'Set up your home picks up where you stopped.',
    ),
    OmniButton(
      key: const ValueKey('setup-finish'),
      label: 'Done',
      onPressed: () => Navigator.of(context).pop(),
    ),
  ];
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.step, required this.progress});

  final SetupStep? step;
  final SetupProgress progress;

  @override
  Widget build(BuildContext context) {
    final total = SetupStep.values.length;
    final at = step == null ? total : SetupStep.values.indexOf(step!) + 1;
    return Semantics(
      label: step == null
          ? '${progress.count} of $total steps done'
          : 'Step $at of $total, ${progress.count} done',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            step == null ? 'All steps' : 'Step $at of $total',
            key: const ValueKey('setup-step-count'),
            style: OmniText.caption,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final s in SetupStep.values) ...[
                Expanded(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: progress.done.contains(s)
                          ? OmniColors.accent
                          : s == step
                          ? OmniColors.muted
                          : OmniColors.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (s != SetupStep.values.last) const SizedBox(width: 4),
              ],
            ],
          ),
        ],
      ),
    );
  }
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
