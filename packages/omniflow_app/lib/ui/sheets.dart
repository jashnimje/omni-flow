import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'device_sheets.dart';

const pinModes = ['out', 'in_pullup', 'in', 'pwm', 'servo', 'adc'];
const _modeHelp = {
  'out': 'switch (relay, LED)',
  'in_pullup': 'button to ground',
  'in': 'digital input',
  'pwm': 'level 0 to 100%',
  'servo': 'angle 0 to 180',
  'adc': 'analog sensor 0 to 100%',
};

/// A hint only. The engine checks the name and says why it refuses one.
final _pinName = RegExp(r'^[a-z][a-z0-9_]*$');

/// Names the pins of an OmniFlow board. Every change goes to the engine,
/// which checks it against the board and sets the board up.
class PinSheet extends ConsumerStatefulWidget {
  const PinSheet({super.key, required this.device});

  final Json device;

  @override
  ConsumerState<PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends ConsumerState<PinSheet> {
  late Map<String, Object?> _pins = _pinsOf(widget.device);
  final _name = TextEditingController();
  final _pin = TextEditingController();
  var _mode = 'out';
  var _saving = false;

  static Map<String, Object?> _pinsOf(Json device) => Map<String, Object?>.from(
    (device['settings'] as Map? ?? const {})['pins'] as Map? ?? const {},
  );

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  /// Sends [next], then shows the pins the engine holds, which after a
  /// refused setup are not the ones the sheet sent.
  Future<void> _save(Map<String, Object?> next) async {
    final client = ref.read(engineClientProvider);
    final devices = ref.read(devicesProvider.notifier);
    setState(() => _saving = true);
    final result = await callClient(client, 'board.pins', {
      'id': widget.device['id'],
      'pins': next,
    });
    await devices.refresh();
    if (!mounted) return;
    final fresh = ref
        .read(devicesProvider)
        .value
        ?.where((d) => d['id'] == widget.device['id'])
        .firstOrNull;
    setState(() {
      _saving = false;
      _pins = fresh != null
          ? _pinsOf(fresh)
          : (result['ok'] == true ? next : _pins);
      if (result['ok'] == true) {
        _name.clear();
        _pin.clear();
      }
    });
    if (result['provisionError'] != null) {
      showMessage('Saved. The board is offline: ${result['provisionError']}');
    }
  }

  Future<void> _add(String name, int pin) async {
    if (_pins[name] case final Map old) {
      final replace = await confirm(
        context,
        title: 'Replace $name?',
        body:
            '$name is GPIO ${old['pin']}, ${old['mode']}. '
            'Saving makes it GPIO $pin, $_mode.',
        action: 'Replace',
      );
      if (!replace || !mounted) return;
    }
    await _save({
      ..._pins,
      name: {'pin': pin, 'mode': _mode},
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    final pin = int.tryParse(_pin.text);
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
            Text(
              'Pins of ${widget.device['name']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_pins.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No pins named yet. Name one below: it appears as a control.',
                ),
              ),
            for (final e in _pins.entries)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(e.key),
                subtitle: Text(
                  'GPIO ${(e.value as Map)['pin']}, ${(e.value as Map)['mode']}',
                ),
                trailing: IconButton(
                  key: ValueKey('pin-remove-${e.key}'),
                  tooltip: 'Remove ${e.key}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _saving
                      ? null
                      : () => _save({..._pins}..remove(e.key)),
                ),
              ),
            const Divider(),
            TextField(
              key: const ValueKey('pin-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'relay',
                errorText: name.isNotEmpty && !_pinName.hasMatch(name)
                    ? 'Start with a lower case letter, then letters, digits or _'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const ValueKey('pin-number'),
              controller: _pin,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'GPIO',
                hintText: 'the number printed on the board',
              ),
              onChanged: (_) => setState(() {}),
            ),
            DropdownButtonFormField<String>(
              key: const ValueKey('pin-mode'),
              initialValue: _mode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Used as'),
              items: [
                for (final m in pinModes)
                  DropdownMenuItem(
                    value: m,
                    child: Text(
                      '$m - ${_modeHelp[m]}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (m) => setState(() => _mode = m ?? 'out'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('pin-save'),
              onPressed: name.isNotEmpty && pin != null && !_saving
                  ? () => _add(name, pin)
                  : null,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save pin'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A state key a link can watch: `device.key`, with a label for people.
/// Capability keys come first, other raw keys sit behind More.
typedef LinkSource = ({String value, String label, bool capability});

/// Connects one device to another: pick what to watch, what to drive, and
/// how. The engine says which modes and targets fit the source
/// (link.options), writes the flow and validates it.
class LinkSheet extends ConsumerStatefulWidget {
  const LinkSheet({super.key, this.fromDevice});

  final String? fromDevice;

  @override
  ConsumerState<LinkSheet> createState() => _LinkSheetState();
}

class _LinkSheetState extends ConsumerState<LinkSheet> {
  String? _from;
  String? _to;
  String? _mode;
  var _direction = 'above';
  var _more = false;
  final _options = <String, Json>{};
  final _limit = TextEditingController();
  final _set = TextEditingController(text: 'true');

  static const modeLabels = {
    'toggle': 'Toggle',
    'follow': 'Follow',
    'threshold': 'Threshold',
  };

  @override
  void dispose() {
    _limit.dispose();
    _set.dispose();
    super.dispose();
  }

  static List<LinkSource> sources(List<Json> devices) => [
    for (final d in devices)
      ...() {
        final caps = [
          for (final c in (d['capabilities'] as List? ?? const []).cast<Map>())
            if (c['stateKey'] != null) c,
        ];
        final covered = {for (final c in caps) c['stateKey']};
        return [
          for (final c in caps)
            (
              value: '${d['id']}.${c['stateKey']}',
              label: '${d['name']} - ${c['label']}',
              capability: true,
            ),
          for (final k in (d['state'] as Map? ?? const {}).keys)
            if (!covered.contains(k))
              (
                value: '${d['id']}.$k',
                label: '${d['name']} - $k',
                capability: false,
              ),
        ];
      }(),
  ];

  /// `<device name> - <capability label>` for a `device.capability` target.
  static String targetLabel(List<Json> devices, String to) {
    if (to.split('.') case [final deviceId, final capabilityId]) {
      return _targetLabel(devices, deviceId, capabilityId) ?? to;
    }
    return to;
  }

  static String? _targetLabel(
    List<Json> devices,
    String deviceId,
    String capabilityId,
  ) {
    final device = devices.where((d) => d['id'] == deviceId).firstOrNull;
    final capability = (device?['capabilities'] as List? ?? const [])
        .cast<Map>()
        .where((c) => c['id'] == capabilityId)
        .firstOrNull;
    return device == null || capability == null
        ? null
        : '${device['name']} - ${capability['label']}';
  }

  /// A press toggles and a reading crosses a threshold, so those lead when
  /// the engine allows them.
  static String? suggestedMode(List<String> modes) => modes.contains('toggle')
      ? 'toggle'
      : modes.contains('threshold')
      ? 'threshold'
      : modes.firstOrNull;

  List<String> _modesOf(Json? options) => [
    for (final m in (options?['modes'] as List? ?? const []))
      if (modeLabels.containsKey(m)) m as String,
  ];

  void _choose(String from) {
    _from = from;
    _mode = suggestedMode(_modesOf(_options[from]));
    if (!_options.containsKey(from)) _loadOptions(from);
  }

  Future<void> _loadOptions(String from) async {
    final result = await ref.read(engineClientProvider).call('link.options', {
      'from': from,
    });
    if (!mounted) return;
    setState(() {
      _options[from] = result;
      if (_from == from) _mode = suggestedMode(_modesOf(result));
    });
  }

  Future<void> _create() async {
    Object? set;
    try {
      set = jsonDecode(_set.text);
    } on FormatException {
      set = _set.text;
    }
    final flows = ref.read(flowsProvider.notifier);
    final result = await callEngine(ref, 'link.create', {
      'from': _from,
      'to': _to,
      'mode': _mode,
      if (_mode == 'threshold') ...{
        _direction: num.tryParse(_limit.text),
        'set': set,
      },
      'trusted': true,
    });
    if (result['ok'] != true) return;
    await flows.refresh();
    if (mounted) Navigator.of(context).pop();
    showMessage('Linked: ${result['name']}');
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider).value ?? const [];
    final all = sources(devices);
    if (_from == null) {
      final mine = [
        for (final s in all)
          if (widget.fromDevice == null ||
              s.value.startsWith('${widget.fromDevice}.'))
            s,
      ];
      final first =
          mine.where((s) => s.capability).firstOrNull ?? mine.firstOrNull;
      if (first != null) {
        _more = !first.capability;
        _choose(first.value);
      }
    }
    final options = _options[_from];
    final modes = _modesOf(options);
    final to = [
      for (final t in (options?['targets'] as List? ?? const []).cast<Map>())
        if ((t['modes'] as List? ?? const []).contains(_mode)) '${t['to']}',
    ];
    if (_to != null && !to.contains(_to)) _to = null;
    final ready =
        _from != null &&
        _to != null &&
        modes.contains(_mode) &&
        (_mode != 'threshold' || num.tryParse(_limit.text) != null);
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
            Text('Link', style: Theme.of(context).textTheme.titleMedium),
            DropdownButtonFormField<String>(
              key: const ValueKey('link-from'),
              initialValue: _from,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'When this changes'),
              items: [
                for (final s in all)
                  if (_more || s.capability || s.value == _from)
                    DropdownMenuItem(value: s.value, child: Text(s.label)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _choose(v));
              },
            ),
            SwitchListTile(
              key: const ValueKey('link-more'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('More: every state key'),
              value: _more,
              onChanged: (v) => setState(() => _more = v),
            ),
            if (options != null && options['ok'] != true)
              Text(errorMessage(options), key: const ValueKey('link-error')),
            KeyedSubtree(
              key: const ValueKey('link-to'),
              // A new key resets the field when its choices change under it.
              child: DropdownButtonFormField<String>(
                key: ValueKey(to.join(',')),
                initialValue: _to,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Drive this'),
                items: [
                  for (final t in to)
                    DropdownMenuItem(
                      value: t,
                      child: Text(targetLabel(devices, t)),
                    ),
                ],
                onChanged: (v) => setState(() => _to = v),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              key: const ValueKey('link-mode'),
              segments: [
                for (final m in modeLabels.entries)
                  ButtonSegment(
                    value: m.key,
                    label: Text(m.value),
                    enabled: modes.contains(m.key),
                  ),
              ],
              emptySelectionAllowed: true,
              selected: {?_mode},
              onSelectionChanged: (s) {
                if (s.isNotEmpty) setState(() => _mode = s.single);
              },
            ),
            if (_mode == 'threshold') ...[
              Row(
                children: [
                  DropdownButton<String>(
                    value: _direction,
                    items: const [
                      DropdownMenuItem(
                        value: 'above',
                        child: Text('goes above'),
                      ),
                      DropdownMenuItem(
                        value: 'below',
                        child: Text('goes below'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _direction = v ?? 'above'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('link-limit'),
                      controller: _limit,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Number'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('link-set'),
                controller: _set,
                decoration: const InputDecoration(
                  labelText: 'Then set it to',
                  hintText: 'true, false or a number',
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('link-create'),
              onPressed: ready ? _create : null,
              child: const Text('Create link'),
            ),
          ],
        ),
      ),
    );
  }
}
