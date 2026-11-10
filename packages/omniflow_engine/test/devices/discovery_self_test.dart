import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/error_of.dart';
import 'package:omniflow_engine/src/manifest/built_in_drivers.g.dart';
import 'package:test/test.dart';

import 'fake_mdns.dart';

void main() {
  final tv = DriverManifest.parseJson(
    builtInDriverSources['android_tv_adb.omni_driver.json']!,
  );
  const phone = 'adb-PHONE0001._adb._tcp.local';
  const lounge = 'adb-TV0002._adb._tcp.local';

  late UdpTransport udp;
  setUp(() async => udp = await UdpTransport.bind());
  tearDown(() => udp.close());

  DeviceDiscovery discovery(Set<String> own) => DeviceDiscovery(
    udp: UdpDiscovery(udp),
    mdns: MdnsDiscovery(
      client: () => FakeMdns([
        ptr('_adb._tcp', phone),
        srv(phone, 'phone.local', 5555),
        a('phone.local', '192.168.7.62'),
        ptr('_adb._tcp', lounge),
        srv(lounge, 'tv.local', 5555),
        a('tv.local', '192.168.7.111'),
      ]),
    ),
    ownAddresses: () async => own,
  );

  test(
    'an ADB find at this phone\'s own address is not offered as a TV',
    () async {
      final found = await discovery({'192.168.7.62'})
          .discover(tv, window: const Duration(milliseconds: 100));
      expect(found.map((f) => f.host), ['192.168.7.111']);
    },
  );

  test('without that address both are found', () async {
    final found = await discovery(const {})
        .discover(tv, window: const Duration(milliseconds: 100));
    expect(
      found.map((f) => f.host),
      unorderedEquals(['192.168.7.62', '192.168.7.111']),
    );
  });

  test('a background failure event carries the type, not the class name', () {
    final fields = errorFields(PairingRequiredException('lounge_tv'));
    expect(fields['errorType'], 'needs_user');
    expect(fields['error'], startsWith('lounge_tv is not paired'));
    expect(errorFields(CommandFailedException('the TV closed the stream')), {
      'error': 'the TV closed the stream',
      'errorType': 'device_error',
    });
  });
}
