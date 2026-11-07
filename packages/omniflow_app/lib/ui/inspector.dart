import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Every packet the engine sends and receives, newest first.
class Inspector extends ConsumerWidget {
  const Inspector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packets = ref.watch(packetsProvider);
    if (packets.isEmpty) return const Center(child: Text('No packets yet.'));
    return ListView.builder(
      itemCount: packets.length,
      itemBuilder: (context, i) {
        final p = packets[i];
        final outgoing = p['direction'] == 'outgoing';
        return ListTile(
          dense: true,
          leading: Icon(
            outgoing ? Icons.north_east : Icons.south_west,
            size: 18,
          ),
          title: Text(
            '${p['text']}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          subtitle: Text('${p['transport']}  ${p['remote']}  ${p['at']}'),
        );
      },
    );
  }
}
