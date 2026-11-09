import '../discovery.dart';

/// The discovery method name for a board the hub heard say hello.
const helloMethod = 'hello';

/// The boards the hub heard say hello that are not devices yet, kept from
/// its `board.found` events so `thing.add` can offer them. A hello is not
/// authenticated, so what is kept is only ever a suggestion the user picks.
class RecentHellos {
  RecentHellos({
    this.ttl = const Duration(minutes: 3),
    this.cap = 64,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// A board says hello every 30 seconds, so one not heard for this long
  /// has gone or been added.
  final Duration ttl;

  /// So a noisy network cannot grow the list without bound.
  final int cap;

  final DateTime Function() _clock;

  final _seen =
      <String, ({DateTime at, String driver, DiscoveredDevice found})>{};

  /// Takes a `board.found` event; every other event is ignored.
  void observe(Map<String, Object?> event) {
    if (event['event'] != 'board.found') return;
    final add = event['add'];
    if (add is! Map) return;
    final host = add['host'];
    final node = add['stableId'] ?? event['node'];
    final driver = add['driver'];
    if (host is! String || node is! String || driver is! String) return;
    final key = node.toLowerCase();
    _seen.remove(key);
    _seen[key] = (
      at: _clock(),
      driver: driver,
      found: DiscoveredDevice(
        host: host,
        stableId: node,
        port: add['port'] is int ? add['port'] as int : null,
        name: add['name'] is String ? add['name'] as String : node,
        reply: {'node': node, 'board': ?event['board']},
        method: helloMethod,
      ),
    );
    while (_seen.length > cap) {
      _seen.remove(_seen.keys.first);
    }
  }

  /// The boards heard within [ttl], with the driver each hello named.
  List<(String driver, DiscoveredDevice found)> get recent {
    final now = _clock();
    _seen.removeWhere((_, s) => now.difference(s.at) > ttl);
    return [for (final s in _seen.values) (s.driver, s.found)];
  }
}
