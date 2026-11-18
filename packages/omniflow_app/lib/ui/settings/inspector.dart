import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/device_text.dart';

/// Every packet the engine sends and receives, newest first, filtered by
/// transport, address or text. Developer's Packets tab.
class Inspector extends ConsumerStatefulWidget {
  const Inspector({super.key, this.filter});

  /// Starts filtered (a device's address, from its "See what was sent").
  final String? filter;

  @override
  ConsumerState<Inspector> createState() => _InspectorState();
}

class _InspectorState extends ConsumerState<Inspector> {
  late final _filter = TextEditingController(text: widget.filter ?? '');

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  static bool _matches(Json p, String query) {
    if (query.isEmpty) return true;
    return [
      p['transport'],
      p['remote'],
      p['text'],
      p['device'],
    ].any((v) => '${v ?? ''}'.toLowerCase().contains(query));
  }

  static String _time(Object? at) {
    final t = DateTime.tryParse('$at')?.toLocal();
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.text.trim().toLowerCase();
    final packets = [
      for (final p in ref.watch(packetsProvider))
        if (_matches(p, query)) p,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('packets-filter'),
          controller: _filter,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: Icon(
              OmniIcons.search,
              color: OmniPalette.of(context).muted,
            ),
            hintText: 'Filter by udp, mqtt, adb or a device',
          ),
        ),
        const SizedBox(height: OmniSpace.md),
        Expanded(
          child: packets.isEmpty
              ? ListView(
                  children: [
                    if (query.isEmpty)
                      const OmniEmptyState(
                        key: ValueKey('packets-empty'),
                        icon: OmniIcons.developer,
                        title: 'No packets yet',
                        message:
                            'What OmniFlow sends to your devices and hears '
                            'back shows here as it happens.',
                      )
                    else
                      OmniEmptyState(
                        key: const ValueKey('packets-empty'),
                        icon: OmniIcons.search,
                        title: 'No packet matches "${_filter.text.trim()}"',
                        compact: true,
                      ),
                  ],
                )
              : ListView.builder(
                  key: const ValueKey('packets-list'),
                  itemCount: packets.length,
                  itemBuilder: (context, i) {
                    final p = packets[i];
                    final out = p['direction'] == 'outgoing';
                    final colour = out
                        ? OmniPalette.of(context).accent
                        : OmniPalette.of(context).trigger;
                    return OmniCard(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      margin: const EdgeInsets.only(bottom: OmniSpace.sm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                out ? AreaIcons.sent : AreaIcons.received,
                                size: 14,
                                color: colour,
                                semanticLabel: out ? 'Sent' : 'Received',
                              ),
                              Text(
                                ' ${p['transport']} ',
                                style: OmniText.mono.copyWith(color: colour),
                              ),
                              Expanded(
                                child: Text(
                                  '${p['remote'] ?? ''}',
                                  overflow: TextOverflow.ellipsis,
                                  style: OmniText.mono,
                                ),
                              ),
                              Text(
                                _time(p['at']),
                                style: OmniText.mono.copyWith(
                                  color: OmniPalette.of(context).muted,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${p['text']}',
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: OmniText.mono,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
