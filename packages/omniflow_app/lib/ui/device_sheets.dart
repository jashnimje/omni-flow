import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'add_thing.dart' show followNext;
import 'setup_page.dart' show settingValue;

/// A device id from its name: lower snake case, as the engine requires.
String deviceIdFor(String name) {
  final id = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return RegExp(r'^[a-z]').hasMatch(id) ? id : 'device_$id';
}

Future<void> showAddDevice(BuildContext context, {String? driver}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddDeviceSheet(driver: driver),
    );

/// Adds a device by hand: pick its driver, scan for it or type its
/// address, then name it and put it in a room. A virtual driver (a place,
/// a person) takes no address. The setup
/// page then walks the steps the engine says come next (device.add returns
/// `next` too).
class AddDeviceSheet extends ConsumerStatefulWidget {
  const AddDeviceSheet({super.key, this.driver});

  /// The driver picked when the sheet opens.
  final String? driver;

  @override
  ConsumerState<AddDeviceSheet> createState() => _AddDeviceSheetState();
}

class _AddDeviceSheetState extends ConsumerState<AddDeviceSheet> {
  List<Json>? _drivers;
  String? _driver;
  List<Json>? _found;
  var _scanning = false;
  var _adding = false;
  String? _stableId;
  final _host = TextEditingController();
  final _name = TextEditingController();
  final _room = TextEditingController();
  final _settings = <String, TextEditingController>{};

  /// The driver's settings typed as text: not secrets, which go through
  /// pairing or omni secret set, and not a board's pins, which the pin
  /// sheet sets.
  List<Json> get _settingFields {
    final driver = _drivers?.where((d) => d['id'] == _driver).firstOrNull;
    if (driver == null || driver['board'] == true) return const [];
    return [
      for (final s in (driver['settings'] as List? ?? const []))
        if ((s as Map)['secret'] != true) Map<String, Object?>.from(s),
    ];
  }

  TextEditingController _settingField(String key) =>
      _settings.putIfAbsent(key, TextEditingController.new);

  bool get _virtual =>
      _drivers?.where((d) => d['id'] == _driver).firstOrNull?['transport'] ==
      'virtual';

  @override
  void initState() {
    super.initState();
    _driver = widget.driver;
    _loadDrivers();
  }

  Future<void> _loadDrivers() async {
    final result = await callEngine(ref, 'driver.list');
    if (!mounted) return;
    setState(
      () => _drivers = [
        for (final d in (result['drivers'] as List? ?? const []))
          Map<String, Object?>.from(d as Map),
      ],
    );
  }

  @override
  void dispose() {
    _host.dispose();
    _name.dispose();
    _room.dispose();
    for (final c in _settings.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = null;
    });
    final result = await callEngine(ref, 'device.discover', {
      'driver': _driver,
    });
    if (!mounted) return;
    final found = [
      for (final f in (result['found'] as List? ?? const []))
        Map<String, Object?>.from(f as Map),
    ];
    // Known entries stay listed: a Hue bridge or Home Assistant instance has
    // one stable id for every device behind it.
    setState(() {
      _scanning = false;
      _found = [
        ...found.where((f) => f['knownAs'] == null),
        ...found.where((f) => f['knownAs'] != null),
      ];
    });
  }

  String _deviceName(String id) =>
      '${ref.read(devicesProvider).value?.where((d) => d['id'] == id).firstOrNull?['name'] ?? id}';

  void _pick(Json found) => setState(() {
    _host.text = '${found['host']}';
    _stableId = found['stableId'] as String?;
    if (_name.text.isEmpty && _stableId != null && found['knownAs'] == null) {
      _name.text = _stableId!;
    }
  });

  Future<void> _add() async {
    final devices = ref.read(devicesProvider.notifier);
    final navigator = Navigator.of(context);
    final name = _name.text.trim();
    final settings = {
      for (final f in _settingFields)
        if (_settingField('${f['key']}').text.trim() case final v
            when v.isNotEmpty)
          '${f['key']}': settingValue(v),
    };
    final id = deviceIdFor(name);
    setState(() => _adding = true);
    // device.add, not thing.add: thing.add refuses a find that matches a
    // device by host or stable id, and a hub's lights and entities share
    // both.
    final result = await callEngine(ref, 'device.add', {
      'id': id,
      'name': name,
      'driver': _driver,
      if (!_virtual) 'host': _host.text.trim(),
      if (_room.text.trim().isNotEmpty) 'room': _room.text.trim(),
      if (!_virtual) 'stableId': ?_stableId,
      if (settings.isNotEmpty) 'settings': settings,
    });
    if (mounted) setState(() => _adding = false);
    if (result['ok'] != true) return;
    await devices.refresh();
    if (result['provisionError'] != null) {
      showMessage('The board is offline: ${result['provisionError']}');
    }
    navigator.pop();
    await followNext(navigator, result, name: name, id: id);
  }

  @override
  Widget build(BuildContext context) {
    final drivers = _drivers;
    final found = _found;
    final virtual = _virtual;
    final ready =
        _driver != null &&
        (virtual || _host.text.trim().isNotEmpty) &&
        _name.text.trim().isNotEmpty &&
        !_adding;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add device', style: Theme.of(context).textTheme.titleMedium),
            if (drivers == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              DropdownButtonFormField<String>(
                key: const ValueKey('add-driver'),
                initialValue: _driver,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kind of device'),
                items: [
                  for (final d in drivers)
                    DropdownMenuItem(
                      value: d['id'] as String,
                      child: Text('${d['name']}'),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _driver = v;
                  _found = null;
                  _stableId = null;
                }),
              ),
            const SizedBox(height: 8),
            if (!virtual) ...[
              OutlinedButton.icon(
                key: const ValueKey('add-scan'),
                onPressed: _driver == null || _scanning ? null : _scan,
                icon: _scanning
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar),
                label: const Text('Scan the network'),
              ),
              if (found != null && found.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Nothing found. Type its address below.'),
                ),
              if (found != null)
                for (final f in found)
                  ListTile(
                    key: ValueKey('found-${f['host']}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _host.text == f['host']
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text('${f['host']}'),
                    subtitle: switch ((f['stableId'], f['knownAs'])) {
                      (_, final String known) => Text(
                        'Already used by ${_deviceName(known)}',
                        key: ValueKey('found-known-${f['host']}'),
                      ),
                      (final String id, _) => Text(id),
                      _ => null,
                    },
                    onTap: () => _pick(f),
                  ),
              TextField(
                key: const ValueKey('add-host'),
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: '192.168.1.40',
                ),
                onChanged: (_) => setState(() => _stableId = null),
              ),
            ],
            TextField(
              key: const ValueKey('add-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'Desk lamp',
                helperText: _name.text.trim().isEmpty
                    ? null
                    : 'Id: ${deviceIdFor(_name.text.trim())}',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('add-room'),
              controller: _room,
              decoration: const InputDecoration(
                labelText: 'Room',
                hintText: 'Study',
              ),
            ),
            for (final f in _settingFields)
              TextField(
                key: ValueKey('add-setting-${f['key']}'),
                controller: _settingField('${f['key']}'),
                decoration: InputDecoration(
                  labelText: '${f['label']}',
                  helperText: 'Text, or JSON for a list or an object',
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('add-save'),
              onPressed: ready ? _add : null,
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renames a device or moves it to another room.
Future<void> showEditDevice(BuildContext context, Json device) =>
    showDialog<void>(
      context: context,
      builder: (_) => EditDeviceDialog(device: device),
    );

class EditDeviceDialog extends ConsumerStatefulWidget {
  const EditDeviceDialog({super.key, required this.device});

  final Json device;

  @override
  ConsumerState<EditDeviceDialog> createState() => _EditDeviceDialogState();
}

class _EditDeviceDialogState extends ConsumerState<EditDeviceDialog> {
  late final _name = TextEditingController(text: '${widget.device['name']}');
  late final _room = TextEditingController(
    text: (widget.device['room'] as String?) ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    _room.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final d = widget.device;
    final devices = ref.read(devicesProvider.notifier);
    final result = await callEngine(ref, 'device.add', {
      'id': d['id'],
      'name': _name.text.trim(),
      'driver': d['driver'],
      'host': d['host'],
      'port': ?d['port'],
      if (_room.text.trim().isNotEmpty) 'room': _room.text.trim(),
      'stableId': ?d['stableId'],
      'settings': d['settings'] ?? const {},
      'replace': true,
      'provision': false,
    });
    if (result['ok'] != true) return;
    await devices.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Rename or move ${widget.device['name']}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('edit-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const ValueKey('edit-room'),
          controller: _room,
          decoration: const InputDecoration(labelText: 'Room'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('edit-save'),
        onPressed: _name.text.trim().isEmpty ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

/// Asks before removing a device, since its links and flows stop finding it.
Future<void> confirmRemoveDevice(
  BuildContext context,
  WidgetRef ref,
  Json device,
) async {
  final devices = ref.read(devicesProvider.notifier);
  final client = ref.read(engineClientProvider);
  final ok = await confirm(
    context,
    title: 'Remove ${device['name']}?',
    body: 'Flows and links that drive it stop working until it is added again.',
    action: 'Remove',
  );
  if (!ok) return;
  final result = await callClient(client, 'device.remove', {
    'id': device['id'],
  });
  if (result['ok'] == true) await devices.refresh();
}

/// A yes or no question, true when the user picks [action].
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;

/// Whether the Pair dialog can finish pairing [device]. A `secret` pairing
/// ends with the user storing a token, which the Pair dialog cannot take, so
/// it is left to Setup steps rather than offered as a step that cannot
/// complete.
bool pairsInApp(Map device) => switch (device['pairing']) {
  {'method': 'secret'} => false,
  Map() => true,
  _ => false,
};

/// Pairs a device the way its driver needs (a TV prompt, a Hue link
/// button). The engine says what the user does: the prompt comes from the
/// device's `pairing`, the outcome from device.pair.
Future<void> showPairDevice(BuildContext context, Json device) =>
    showDialog<void>(
      context: context,
      builder: (_) => PairDeviceDialog(device: device),
    );

class PairDeviceDialog extends ConsumerStatefulWidget {
  const PairDeviceDialog({super.key, required this.device});

  final Json device;

  @override
  ConsumerState<PairDeviceDialog> createState() => _PairDeviceDialogState();
}

class _PairDeviceDialogState extends ConsumerState<PairDeviceDialog> {
  var _pairing = false;
  var _paired = false;
  String? _outcome;

  Future<void> _pair() async {
    final devices = ref.read(devicesProvider.notifier);
    setState(() {
      _pairing = true;
      _outcome = null;
    });
    final result = await callEngine(ref, 'device.pair', {
      'id': widget.device['id'],
    });
    if (result['ok'] == true) await devices.refresh();
    if (!mounted) return;
    setState(() {
      _pairing = false;
      _paired = result['ok'] == true && result['paired'] == true;
      _outcome = result['ok'] == true
          ? '${result['message']}'
          : errorMessage(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pairing = widget.device['pairing'] as Map? ?? const {};
    return AlertDialog(
      title: Text('Pair ${widget.device['name']}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${pairing['prompt'] ?? ''}',
            key: const ValueKey('pair-prompt'),
          ),
          if (_pairing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_outcome != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_outcome!, key: const ValueKey('pair-outcome')),
            ),
        ],
      ),
      actions: [
        if (_paired)
          FilledButton(
            key: const ValueKey('pair-done'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          )
        else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            key: const ValueKey('pair-start'),
            onPressed: _pairing ? null : _pair,
            child: Text(_outcome == null ? 'Start pairing' : 'Try again'),
          ),
        ],
      ],
    );
  }
}
