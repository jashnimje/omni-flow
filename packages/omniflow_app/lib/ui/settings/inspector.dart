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
          decoration: const InputDecoration(
            prefixIcon: Icon(OmniIcons.search, color: OmniColors.muted),
            hintText: 'Filter: udp, mqtt, adb, a device...',
          ),
        ),
        const SizedBox(height: OmniSpace.gap),
        Expanded(
          child: packets.isEmpty
              ? Center(
                  child: Text(
                    query.isEmpty ? 'No packets yet.' : 'No packets match.',
                    style: OmniText.caption,
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('packets-list'),
                  itemCount: packets.length,
                  itemBuilder: (context, i) {
                    final p = packets[i];
                    final out = p['direction'] == 'outgoing';
                    final colour = out ? OmniColors.accent : OmniColors.trigger;
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
                                  color: OmniColors.muted,
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
