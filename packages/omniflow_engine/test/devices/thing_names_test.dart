import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/discovery/thing_finder.dart';
import 'package:test/test.dart';

import 'fake_mdns.dart';

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

  group('old default names', () {
    Device device(
      String driver,
      String name, {
      String? stableId,
      String host = '192.168.1.9',
    }) => Device(
      id: 'thing',
      name: name,
      driverId: driver,
      host: host,
      stableId: stableId,
    );

    String? renamed(Device d) => renamedOldDefaultName(drivers[d.driverId]!, d);

    test('only a name in the old default form gets today\'s name', () {
      expect(
        renamed(
          device(
            'philips_wiz_udp',
            'Philips WiZ Light (local UDP) 000001',
            stableId: 'a8bb50000001',
          ),
        ),
        'Light 0001',
      );
      expect(
        renamed(device('android_tv_adb', 'adb-EMULATOR37X2X13X0-sNodcG')),
        'TV 13X0',
      );
      expect(
        renamed(
          device(
            'android_tv_adb',
            'adb-0000000000000003f',
            stableId: 'adb-0000000000000003f',
          ),
        ),
        'TV 003F',
      );
      for (final typed in [
        'Desk lamp',
        'Philips WiZ Light (local UDP) 000002',
        'Philips WiZ Light (local UDP)',
        'adb TV',
      ]) {
        expect(
          renamed(device('philips_wiz_udp', typed, stableId: 'a8bb50000001')),
          isNull,
          reason: typed,
        );
      }
      expect(renamed(device('philips_wiz_udp', 'adb-X1-y')), isNull);
    });

    test(
      'on open, old defaults are renamed once and typed names stay',
      () async {
        final home = await Directory.systemTemp.createTemp('omni_old_names');
        addTearDown(() => home.delete(recursive: true));
        Future<OmniEngine> open() => OmniEngine.open(
          home: home,
          secrets: InMemorySecretStore(),
          mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
        );
        Future<Map<Object?, Object?>> names(OmniEngine e) async => {
          for (final d
              in (await e.handle('device.list', {}))['devices'] as List)
            (d as Map)['id']: d['name'],
        };

        var engine = await open();
        for (final (id, driver, name, stableId) in [
          (
            'bulb',
            'philips_wiz_udp',
            'Philips WiZ Light (local UDP) 000001',
            'a8bb50000001',
          ),
          ('desk', 'philips_wiz_udp', 'Desk lamp', 'a8bb50000002'),
          ('tv', 'android_tv_adb', 'adb-EMULATOR37X2X13X0-sNodcG', null),
        ]) {
          final r = await engine.handle('device.add', {
            'id': id,
            'driver': driver,
            'host': '10.0.2.2',
            'name': name,
            'stableId': ?stableId,
          });
          expect(r['ok'], isTrue, reason: '$r');
        }
        await engine.close();

        engine = await open();
        final first = await names(engine);
        expect(first, {
          'bulb': 'Light 0001',
          'desk': 'Desk lamp',
          'tv': 'TV 13X0',
        });
        await engine.close();

        engine = await open();
        expect(await names(engine), first);
        await engine.close();
      },
    );
  });
}
