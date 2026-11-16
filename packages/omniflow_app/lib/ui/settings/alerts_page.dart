import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/house_calls.dart';
import '../../state/house_providers.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../home/mode_picker.dart' show modeIcon;

/// The Settings row that opens [AlertsPage].
class AlertsSettingsRow extends StatelessWidget {
  const AlertsSettingsRow({super.key});

  @override
  Widget build(BuildContext context) => OmniListRow(
    key: const ValueKey('settings-alerts'),
    icon: OmniIcons.notifications,
    title: 'Alerts and modes',
    subtitle: 'Offline and low battery alerts, house modes',
    chevron: true,
    onTap: () =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const AlertsPage())),
  );
}

/// The built-in alerts, on or off, and the house modes: your own modes
/// and whether the mode follows who is home.
class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key});

  Future<void> _call(
    WidgetRef ref,
    Future<Map<String, Object?>> Function(HouseApi api) call,
  ) async {
    final r = await call(ref.read(houseApiProvider));
    if (r['ok'] != true) showMessage(errorMessage(r));
    ref.invalidate(houseAlertsProvider);
    await ref.read(houseModeProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(houseAlertsProvider).value;
    final modes = ref.watch(houseModeProvider).value;
    return OmniPage(
      title: 'Alerts and modes',
      body: ListView(
        key: const ValueKey('alerts-list'),
        children: [
          const OmniSectionHeader('Alerts'),
          OmniListRow(
            key: const ValueKey('alert-offline'),
            icon: OmniIcons.wifi,
            title: 'A device goes offline',
            subtitle: 'after 10 minutes, and again when it is back',
            trailing: Switch(
              value: alerts?.offline ?? true,
              onChanged: alerts == null
                  ? null
                  : (on) => _call(ref, (api) => api.setAlerts(offline: on)),
            ),
          ),
          OmniListRow(
            key: const ValueKey('alert-battery'),
            icon: Icons.battery_alert_rounded,
            title: 'A battery runs low',
            subtitle: 'a sensor or this phone under 15%',
            trailing: Switch(
              value: alerts?.battery ?? true,
              onChanged: alerts == null
                  ? null
                  : (on) => _call(ref, (api) => api.setAlerts(battery: on)),
            ),
          ),
          if (modes != null) ...[
            const OmniSectionHeader('House modes'),
            OmniListRow(
              key: const ValueKey('mode-follow'),
              icon: OmniIcons.person,
              title: 'The mode follows who is home',
              subtitle: 'Away when everyone leaves, Home when someone is back',
              trailing: Switch(
                value: modes.followPresence,
                onChanged: (on) => _call(ref, (api) => api.followPresence(on)),
              ),
            ),
            for (final m in modes.modes)
              OmniListRow(
                key: ValueKey('mode-row-${m.id}'),
                icon: modeIcon(m.id),
                title: m.name,
                subtitle: m.builtIn ? 'built in' : null,
                trailing: m.builtIn
                    ? null
                    : OmniIconAction(
                        key: ValueKey('mode-remove-${m.id}'),
                        icon: OmniIcons.delete,
                        label: 'Remove ${m.name}',
                        onPressed: () => _call(
                          ref,
                          (api) => api.setModes([
                            for (final c in modes.custom)
                              if (c != m.name) c,
                          ]),
                        ),
                      ),
              ),
            OmniListRow(
              key: const ValueKey('mode-add'),
              icon: OmniIcons.add,
              title: 'Add a mode',
              subtitle: 'like Guests or Movie night',
              onTap: () => _addMode(context, ref, modes),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _addMode(
    BuildContext context,
    WidgetRef ref,
    HouseModes modes,
  ) async {
    final name = TextEditingController();
    final added = await showOmniSheet<String>(
      context,
      builder: (context) => Owning(
        [name],
        child: OmniSheet(
          title: 'Add a mode',
          children: [
            TextField(
              key: const ValueKey('mode-add-name'),
              controller: name,
              autofocus: true,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'Mode name'),
            ),
            const SizedBox(height: OmniSpace.md),
            OmniButton(
              key: const ValueKey('mode-add-done'),
              label: 'Add',
              onPressed: () => Navigator.of(context).pop(name.text.trim()),
            ),
          ],
        ),
      ),
    );
    if (added == null || added.isEmpty) return;
    await _call(ref, (api) => api.setModes([...modes.custom, added]));
  }
}
