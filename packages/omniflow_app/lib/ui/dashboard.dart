import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Room cards with one control per capability, built from the capability
/// types the engine reports. Nothing here knows about a specific device.
class Dashboard extends ConsumerWidget {
  const Dashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    return devices.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) {
        if (list.isEmpty) {
          return const Center(
            child: Text(
              'No devices yet. Add one with omni device add, or discover them.',
            ),
          );
        }
        final rooms = <String, List<Json>>{};
        for (final d in list) {
          rooms.putIfAbsent((d['room'] as String?) ?? 'Other', () => []).add(d);
        }
        return RefreshIndicator(
          onRefresh: () => ref.read(devicesProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final room in rooms.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: Text(
                    room.key,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final d in room.value) DeviceCard(device: d),
              ],
            ],
          ),
        );
      },
    );
  }
}

class DeviceCard extends ConsumerWidget {
  const DeviceCard({super.key, required this.device});

  final Json device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = (device['capabilities'] as List? ?? const []).cast<Map>();
    final state = Map<String, Object?>.from(
      device['state'] as Map? ?? const {},
    );
    return Card(
      key: ValueKey('device-${device['id']}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${device['name']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final c in caps)
              CapabilityControl(
                deviceId: device['id'] as String,
                capability: Map<String, Object?>.from(c),
                state: state,
              ),
          ],
        ),
      ),
    );
  }
}

/// One control for one capability, chosen by capability type.
class CapabilityControl extends ConsumerStatefulWidget {
  const CapabilityControl({
    super.key,
    required this.deviceId,
    required this.capability,
    required this.state,
  });

  final String deviceId;
  final Json capability;
  final Json state;

  @override
  ConsumerState<CapabilityControl> createState() => _CapabilityControlState();
}

class _CapabilityControlState extends ConsumerState<CapabilityControl> {
  double? _dragging;
  final _text = TextEditingController();

  Json get cap => widget.capability;
  String get id => cap['id'] as String;
  Object? get current =>
      cap['stateKey'] == null ? null : widget.state[cap['stateKey']];
  Json get valueParam => Map<String, Object?>.from(
    (cap['params'] as Map? ?? const {})['value'] as Map? ?? const {},
  );

  Future<void> _invoke(Json params) => callEngine(ref, 'device.invoke', {
    'id': widget.deviceId,
    'capability': id,
    'params': params,
  });

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = Text('${cap['label']}');
    final key = ValueKey('${widget.deviceId}.$id');
    switch (cap['type']) {
      case 'toggle':
        return SwitchListTile(
          key: key,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: label,
          value: current == true,
          onChanged: (v) => _invoke({'value': v}),
        );
      case 'level' || 'color_temp':
        final min = (valueParam['min'] as num? ?? 0).toDouble();
        final max = (valueParam['max'] as num? ?? 100).toDouble();
        final value =
            (_dragging ?? (current is num ? (current! as num).toDouble() : min))
                .clamp(min, max);
        return Row(
          key: key,
          children: [
            SizedBox(width: 110, child: label),
            Expanded(
              child: Slider(
                min: min,
                max: max,
                value: value,
                label: '${value.round()}${valueParam['unit'] ?? ''}',
                divisions: (max - min).round().clamp(1, 100),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) {
                  setState(() => _dragging = null);
                  _invoke({'value': v.round()});
                },
              ),
            ),
          ],
        );
      case 'action':
        if ((cap['params'] as Map? ?? const {}).isNotEmpty) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: key,
            onPressed: () => _invoke(const {}),
            child: label,
          ),
        );
      case 'dpad_remote':
        final keys = (valueParam['values'] as List? ?? const []).cast<String>();
        return Wrap(
          key: key,
          spacing: 6,
          children: [
            for (final k in keys)
              OutlinedButton(
                onPressed: () => _invoke({'value': k}),
                child: Text(k),
              ),
          ],
        );
      case 'text_command':
        return Row(
          key: key,
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                decoration: InputDecoration(labelText: cap['label'] as String),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: () {
                if (_text.text.isNotEmpty) _invoke({'value': _text.text});
              },
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
