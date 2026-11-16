import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'automations_state.dart';

/// A state key a link can watch: `device.key`, with a label for people.
/// Capability keys come first; other raw keys sit behind More.
typedef LinkSource = ({String value, String label, bool capability});

/// A quick link: this to that. Pick what to watch, what to drive and how.
/// The engine says which modes and targets fit the source (link.options),
/// writes the automation and checks it.
class LinkSheet extends ConsumerStatefulWidget {
  const LinkSheet({super.key, this.fromDevice});

  /// Starts from this device's first state key.
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
  var _busy = false;
  final _options = <String, Reply<Json>>{};
  final _limit = TextEditingController();
  final _set = TextEditingController();

  /// What the threshold sets its target to: on, off, or the number typed.
  var _setTo = 'on';

  static const modeLabels = {
    'toggle': 'Toggle',
    'follow': 'Follow',
    'threshold': 'Threshold',
  };

  static const modeHelp = {
    'toggle': 'Each press flips it on or off.',
    'follow': 'It takes the same value, scaled to fit.',
    'threshold': 'When the number crosses a line, it is set to a value.',
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
      final device = devices.where((d) => d['id'] == deviceId).firstOrNull;
      final capability = (device?['capabilities'] as List? ?? const [])
          .cast<Map>()
          .where((c) => c['id'] == capabilityId)
          .firstOrNull;
      if (device != null && capability != null) {
        return '${device['name']} - ${capability['label']}';
      }
    }
    return to;
  }

  /// A press toggles and a reading crosses a threshold, so those lead when
  /// the engine allows them.
  static String? suggestedMode(List<String> modes) => modes.contains('toggle')
      ? 'toggle'
      : modes.contains('threshold')
      ? 'threshold'
      : modes.firstOrNull;

  List<String> _modesOf(Reply<Json>? options) => [
    for (final m in (options?.value?['modes'] as List? ?? const []))
      if (modeLabels.containsKey(m)) m as String,
  ];

  void _choose(String from) {
    _from = from;
    _mode = suggestedMode(_modesOf(_options[from]));
    if (!_options.containsKey(from)) _loadOptions(from);
  }

  Future<void> _loadOptions(String from) async {
    final reply = await ref.read(engineApiProvider).linkOptions(from);
    if (!mounted) return;
    setState(() {
      _options[from] = reply;
      if (_from == from) _mode = suggestedMode(_modesOf(reply));
    });
  }

  Future<void> _create() async {
    final Object? set = switch (_setTo) {
      'on' => true,
      'off' => false,
      _ => num.tryParse(_set.text.trim()),
    };
    setState(() => _busy = true);
    final reply = await ref.read(engineApiProvider).createLink({
      'from': _from,
      'to': _to,
      'mode': _mode,
      if (_mode == 'threshold') ...{
        _direction: num.tryParse(_limit.text),
        'set': set,
      },
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (!reply.ok) return;
    await ref.read(automationsProvider.notifier).refresh();
    if (mounted) Navigator.of(context).pop();
    showMessage('Linked: ${reply.value!['name']}');
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
      for (final t
          in (options?.value?['targets'] as List? ?? const []).cast<Map>())
        if ((t['modes'] as List? ?? const []).contains(_mode)) '${t['to']}',
    ];
    if (_to != null && !to.contains(_to)) _to = null;
    final ready =
        !_busy &&
        _from != null &&
        _to != null &&
        modes.contains(_mode) &&
        (_mode != 'threshold' ||
            (num.tryParse(_limit.text) != null &&
                (_setTo != 'number' ||
                    num.tryParse(_set.text.trim()) != null)));
    return SheetTemplate(
      title: 'Quick link',
      subtitle: 'When this changes, drive that.',
      primaryLabel: 'Create link',
      primaryKey: const ValueKey('link-create'),
      onPrimary: ready ? _create : null,
      missing: _busy || all.isEmpty
          ? null
          : _to == null
          ? 'Pick what to drive first.'
          : _mode == 'threshold'
          ? 'Enter the numbers first.'
          : null,
      children: (context) => [
        if (all.isEmpty)
          const OmniEmptyState(
            icon: OmniIcons.devices,
            title: 'Nothing to link yet',
            message: 'Add a device that reports something, like a button.',
            compact: true,
          ),
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
        OmniListRow(
          key: const ValueKey('link-more'),
          title: 'Show every state key',
          subtitle: 'raw values the driver reports',
          divider: false,
          onTap: () => setState(() => _more = !_more),
          trailing: Switch(
            value: _more,
            onChanged: (v) => setState(() => _more = v),
          ),
        ),
        if (options?.failure case final f?)
          OmniBanner.error(f.message, key: const ValueKey('link-error')),
        const SizedBox(height: OmniSpace.sm),
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
        const SizedBox(height: OmniSpace.md),
        if (modes.isNotEmpty && _mode != null) ...[
          OmniSegmented<String>(
            key: const ValueKey('link-mode'),
            segments: [for (final m in modes) OmniSegment(m, modeLabels[m]!)],
            selected: _mode!,
            onChanged: (m) => setState(() => _mode = m),
          ),
          Text(modeHelp[_mode] ?? '', style: OmniText.caption),
        ],
        if (_mode == 'threshold') ...[
          const SizedBox(height: OmniSpace.sm),
          OmniSegmented<String>(
            segments: const [
              OmniSegment('above', 'Goes above'),
              OmniSegment('below', 'Goes below'),
            ],
            selected: _direction,
            onChanged: (v) => setState(() => _direction = v),
          ),
          TextField(
            key: const ValueKey('link-limit'),
            controller: _limit,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(labelText: 'Number'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: OmniSpace.sm),
          const Text('Then', style: OmniText.caption),
          OmniSegmented<String>(
            key: const ValueKey('link-set-to'),
            segments: const [
              OmniSegment('on', 'Turn it on'),
              OmniSegment('off', 'Turn it off'),
              OmniSegment('number', 'Set a number'),
            ],
            selected: _setTo,
            onChanged: (v) => setState(() => _setTo = v),
          ),
          if (_setTo == 'number')
            TextField(
              key: const ValueKey('link-set'),
              controller: _set,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Set it to'),
              onChanged: (_) => setState(() {}),
            ),
        ],
      ],
    );
  }
}
