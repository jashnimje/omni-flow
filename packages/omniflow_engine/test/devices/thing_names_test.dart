import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/discovery/thing_finder.dart';
import 'package:test/test.dart';

void main() {
  final drivers = DriverRegistry.withBuiltIns();
  String named(
    String driver, {
    String? name,
    String? stableId,
    String host = '192.168.1.9',
  }) => suggestThingName(
    drivers[driver]!,
    DiscoveredDevice(
      host: host,
      stableId: stableId,
      name: name,
      reply: const {},
    ),
  );

  test('a find is named by what it is, not by its driver or serial', () {
    expect(named('philips_wiz_udp', stableId: 'a8bb50000001'), 'Light 0001');
    expect(
      named(
        'android_tv_adb',
        name: 'adb-0000000000000003f',
        stableId: 'adb-0000000000000003f',
      ),
      'TV 003F',
    );
    expect(named('omniflow_board', name: 'desk_board'), 'Desk board');
    expect(named('android_tv_adb', name: 'Living Room TV'), 'Living Room TV');
  });
}
