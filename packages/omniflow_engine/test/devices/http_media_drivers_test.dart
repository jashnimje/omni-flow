import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/devices/xml_reply.dart';
import 'package:test/test.dart';

/// One request a fake device saw.
class Seen {
  Seen(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;
}

/// A loopback HTTP device. [answer] gives the status and body for each
/// request, so one fake serves Hue, Shelly, Roku and Sonos.
class FakeHttpDevice {
  FakeHttpDevice._(this._server, this.answer) {
    _server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final seen = Seen(req.method, req.uri, req.headers, body);
      this.seen.add(seen);
      final (status, reply, type) = answer(seen);
      req.response
        ..statusCode = status
        ..headers.contentType = type
        ..write(reply);
      await req.response.close();
    });
  }

  static Future<FakeHttpDevice> start(
    (int, String, ContentType) Function(Seen) answer,
  ) async => FakeHttpDevice._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    answer,
  );

  final HttpServer _server;
  final (int, String, ContentType) Function(Seen) answer;
  final seen = <Seen>[];

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

final xml = ContentType('text', 'xml', charset: 'utf-8');

/// Bodies in the shapes the Roku ECP documentation shows.
const rokuDeviceInfo =
    '<?xml version="1.0" encoding="UTF-8" ?>\n<device-info>\n'
    '<udn>015e5108-9000-1046-8035-b0a737964dfb</udn>\n'
    '<serial-number>1GU48T017973</serial-number>\n'
    '<vendor-name>Roku</vendor-name>\n<model-name>Roku TV</model-name>\n'
    '<friendly-device-name>Living Room Roku</friendly-device-name>\n'
    '<is-tv>true</is-tv>\n<power-mode>POWER</power-mode>\n</device-info>';
const rokuActiveApp =
    '<?xml version="1.0" encoding="UTF-8" ?>\n<active-app>\n'
    '<app id="12" type="appl" version="4.1.218">Netflix</app>\n</active-app>';

String soapReply(String action, String service, String inner) =>
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
    '<u:${action}Response xmlns:u="$service">$inner</u:${action}Response>'
    '</s:Body></s:Envelope>';

const upnpFault =
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
    '<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError'
    '</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
    '<errorCode>701</errorCode></UPnPError></detail></s:Fault></s:Body>'
    '</s:Envelope>';

void main() {
  late InMemorySecretStore secrets;
  late InMemoryDeviceStore store;
  late DeviceService service;
  late PacketTap tap;
  FakeHttpDevice? fake;

  setUp(() {
    secrets = InMemorySecretStore();
    store = InMemoryDeviceStore();
    tap = PacketTap();
    service = DeviceService(
      registry: DriverRegistry.withBuiltIns(),
      store: store,
      channels: {TransportType.http: HttpChannel(secrets: secrets, tap: tap)},
    );
  });

  tearDown(() async => fake?.close());

  Future<void> addDevice(
    String driver, {
    Map<String, Object?> settings = const {},
  }) => store.put(
    Device(
      id: 'it',
      name: 'It',
      driverId: driver,
      host: InternetAddress.loopbackIPv4.address,
      port: fake!.port,
      settings: settings,
    ),
  );

  group('philips_hue_light colour', () {
    setUp(() async {
      fake = await FakeHttpDevice.start(
        (s) => (200, '[{"success":{}}]', ContentType.json),
      );
      await secrets.write(deviceSecretKey('it', 'username'), 'bridge-user-1');
    });

    test('rgb is sent as xy inside the default gamut C, brightness kept from '
        'state', () async {
      await addDevice('philips_hue_light', settings: {'lightId': '3'});
      await service.mergeState('it', {'bri': 120});
      await service.invoke('it', 'rgb', {'r': 255, 'g': 0, 'b': 0});
      final sent = fake!.seen.single;
      expect(sent.method, 'PUT');
      expect(sent.uri.path, '/api/bridge-user-1/lights/3/state');
      expect(jsonDecode(sent.body), {
        'on': true,
        'xy': [0.6915, 0.3083],
        'bri': 120,
      });
    });

    test(
      'the gamut setting moves the clamp, and brightness can be given',
      () async {
        await addDevice(
          'philips_hue_light',
          settings: {'lightId': '3', 'gamut': 'A'},
        );
        await service.invoke('it', 'rgb', {
          'r': 0,
          'g': 255,
          'b': 0,
          'brightness': 200,
        });
        expect(jsonDecode(fake!.seen.single.body), {
          'on': true,
          'xy': [0.2151, 0.7106],
          'bri': 200,
        });
      },
    );

    test('colour temperature still goes as mireds', () async {
      await addDevice('philips_hue_light', settings: {'lightId': '3'});
      await service.invoke('it', 'color_temp', {'value': 370});
      expect(jsonDecode(fake!.seen.single.body), {'on': true, 'ct': 370});
      await expectLater(
        service.invoke('it', 'color_temp', {'value': 2700}),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('shelly_gen1_relay', () {
    var on = false;

    setUp(() async {
      on = false;
      fake = await FakeHttpDevice.start((s) {
        if (s.uri.path == '/relay/0') {
          on = s.uri.queryParameters['turn'] == 'on';
          return (
            200,
            jsonEncode({'ison': on, 'has_timer': false}),
            ContentType.json,
          );
        }
        if (s.uri.path == '/status') {
          return (
            200,
            jsonEncode({
              'relays': [
                {'ison': on, 'has_timer': false, 'overpower': false},
              ],
              'meters': [
                {'power': 12.5, 'total': 340, 'overpower': 3500.0},
              ],
            }),
            ContentType.json,
          );
        }
        return (404, 'not found', ContentType.text);
      });
      await addDevice('shelly_gen1_relay');
    });

    test(
      'power on calls /relay/0?turn=on and the poll reads relay 0',
      () async {
        final result = await service.invoke('it', 'power', {'value': true});
        expect(fake!.seen.single.uri.toString(), '/relay/0?turn=on');
        expect(result.device.state['ison'], true);
        await service.invoke('it', 'power', {'value': false});
        expect(fake!.seen.last.uri.queryParameters, {'turn': 'off'});
        final polled = await service.refreshState('it');
        expect(fake!.seen.last.uri.path, '/status');
        expect(polled.state['ison'], false);
      },
    );

    test(
      'the meter read adds power and total but keeps the relay flag',
      () async {
        final polled = await service.refreshState('it');
        expect(polled.state['power'], 12.5);
        expect(polled.state['total'], 340);
        expect(polled.state['overpower'], false);
      },
    );

    test('a toggle reads the state and flips it', () async {
      await service.refreshState('it');
      await service.toggle('it', 'power');
      expect(fake!.seen.last.uri.queryParameters, {'turn': 'on'});
    });
  });

  group('roku_ecp', () {
    var powerMode = 'PowerOn';

    setUp(() async {
      powerMode = 'PowerOn';
      fake = await FakeHttpDevice.start((s) {
        if (s.method == 'GET' && s.uri.path == '/query/device-info') {
          return (200, rokuDeviceInfo.replaceFirst('POWER', powerMode), xml);
        }
        if (s.method == 'GET' && s.uri.path == '/query/active-app') {
          return (200, rokuActiveApp, xml);
        }
        if (s.method == 'POST') return (200, '', ContentType.text);
        return (404, '', ContentType.text);
      });
      await addDevice('roku_ecp');
    });

    test('power, keys and app launch are ECP POSTs', () async {
      await service.invoke('it', 'power', {'value': false});
      await service.invoke('it', 'press_key', {'value': 'Select'});
      await service.invoke('it', 'volume_up', const {});
      await service.invoke('it', 'launch_app', {'value': '12'});
      expect(
        [for (final s in fake!.seen) '${s.method} ${s.uri.path}'],
        [
          'POST /keypress/PowerOff',
          'POST /keypress/Select',
          'POST /keypress/VolumeUp',
          'POST /launch/12',
        ],
      );
    });

    test('the poll merges device-info and the app on screen', () async {
      final device = await service.refreshState('it');
      expect(device.state['power_mode'], true);
      expect(device.state['app'], 'Netflix');
      expect(device.state['app_id'], 12);
      expect(device.state['friendly_device_name'], 'Living Room Roku');
      expect(
        [for (final s in fake!.seen) s.uri.path],
        ['/query/device-info', '/query/active-app'],
      );
    });

    test('a TV in standby reads as off', () async {
      powerMode = 'DisplayOff';
      final device = await service.refreshState('it');
      expect(device.state['power_mode'], false);
    });

    test('an app id cannot leave the launch path', () async {
      for (final bad in ['../keypress/PowerOff', '12/x', '..']) {
        await expectLater(
          service.invoke('it', 'launch_app', {'value': bad}),
          throwsA(anyOf(isA<ValidationException>(), isA<ArgumentError>())),
          reason: bad,
        );
      }
      expect(fake!.seen, isEmpty);
    });

    test('a key outside the ECP list is refused before sending', () async {
      await expectLater(
        service.invoke('it', 'press_key', {'value': 'Reboot'}),
        throwsA(isA<ValidationException>()),
      );
      expect(fake!.seen, isEmpty);
    });
  });

  group('sonos_upnp', () {
    var volume = 25;
    var muted = 0;
    var state = 'PLAYING';
    var faultOnPlay = false;
    const avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
    const rendering = 'urn:schemas-upnp-org:service:RenderingControl:1';

    setUp(() async {
      volume = 25;
      muted = 0;
      state = 'PLAYING';
      faultOnPlay = false;
      fake = await FakeHttpDevice.start((s) {
        final action = (s.headers.value('soapaction') ?? '').replaceAll(
          '"',
          '',
        );
        final args = flattenXml(s.body) ?? const {};
        switch (action) {
          case '$avTransport#Play' when faultOnPlay:
            return (500, upnpFault, xml);
          case '$avTransport#Play':
            state = 'PLAYING';
            return (200, soapReply('Play', avTransport, ''), xml);
          case '$avTransport#Pause':
            state = 'PAUSED_PLAYBACK';
            return (200, soapReply('Pause', avTransport, ''), xml);
          case '$avTransport#Next':
            return (200, soapReply('Next', avTransport, ''), xml);
          case '$avTransport#GetTransportInfo':
            return (
              200,
              soapReply(
                'GetTransportInfo',
                avTransport,
                '<CurrentTransportState>$state</CurrentTransportState>'
                    '<CurrentTransportStatus>OK</CurrentTransportStatus>'
                    '<CurrentSpeed>1</CurrentSpeed>',
              ),
              xml,
            );
          case '$rendering#SetVolume':
            volume = args['DesiredVolume'] as int;
            return (200, soapReply('SetVolume', rendering, ''), xml);
          case '$rendering#GetVolume':
            return (
              200,
              soapReply(
                'GetVolume',
                rendering,
                '<CurrentVolume>$volume</CurrentVolume>',
              ),
              xml,
            );
          case '$rendering#SetMute':
            muted = args['DesiredMute'] as int;
            return (200, soapReply('SetMute', rendering, ''), xml);
          case '$rendering#GetMute':
            return (
              200,
              soapReply(
                'GetMute',
                rendering,
                '<CurrentMute>$muted</CurrentMute>',
              ),
              xml,
            );
        }
        return (500, upnpFault.replaceFirst('701', '401'), xml);
      });
      await addDevice('sonos_upnp');
    });

    test('play, pause and next are SOAP calls with their SOAPACTION', () async {
      await service.invoke('it', 'pause', const {});
      await service.invoke('it', 'play', const {});
      await service.invoke('it', 'next', const {});
      expect(
        [for (final s in fake!.seen) s.headers.value('soapaction')],
        ['"$avTransport#Pause"', '"$avTransport#Play"', '"$avTransport#Next"'],
      );
      final play = fake!.seen[1];
      expect(play.method, 'POST');
      expect(play.uri.path, '/MediaRenderer/AVTransport/Control');
      expect(play.headers.contentType?.mimeType, 'text/xml');
      expect(play.body, contains('<u:Play xmlns:u="$avTransport">'));
      expect(play.body, contains('<InstanceID>0</InstanceID><Speed>1</Speed>'));
    });

    test('volume and mute go to RenderingControl and poll back', () async {
      await service.invoke('it', 'volume', {'value': 40});
      await service.invoke('it', 'mute', {'value': true});
      expect(fake!.seen[0].uri.path, '/MediaRenderer/RenderingControl/Control');
      expect(fake!.seen[0].body, contains('<DesiredVolume>40</DesiredVolume>'));
      expect(fake!.seen[1].body, contains('<DesiredMute>1</DesiredMute>'));
      final device = await service.refreshState('it');
      expect(device.state['CurrentTransportState'], 'PLAYING');
      expect(device.state['CurrentVolume'], 40);
      expect(device.state['CurrentMute'], true);
    });

    test('a paused speaker reports it, and a mute toggle unmutes', () async {
      await service.invoke('it', 'pause', const {});
      await service.invoke('it', 'mute', {'value': true});
      await service.refreshState('it');
      await service.toggle('it', 'mute');
      expect(fake!.seen.last.body, contains('<DesiredMute>0</DesiredMute>'));
      final device = await service.refreshState('it');
      expect(device.state['CurrentTransportState'], 'PAUSED_PLAYBACK');
      expect(device.state['CurrentMute'], false);
    });

    test('a UPnP fault fails the command with its code', () async {
      faultOnPlay = true;
      await expectLater(
        service.invoke('it', 'play', const {}),
        throwsA(
          isA<CommandFailedException>().having(
            (e) => e.message,
            'message',
            contains('UPnP error 701'),
          ),
        ),
      );
    });

    test('volume outside 0 to 100 is refused before sending', () async {
      await expectLater(
        service.invoke('it', 'volume', {'value': 101}),
        throwsA(isA<ValidationException>()),
      );
      expect(fake!.seen, isEmpty);
    });
  });

  group('SOAP and XML helpers', () {
    test('an argument cannot add elements to the envelope', () {
      final (envelope, action) = soapRequest({
        'service': 'urn:schemas-upnp-org:service:AVTransport:1',
        'action': 'SetAVTransportURI',
        'args': {'CurrentURI': '</CurrentURI><Evil>1</Evil>&'},
      });
      expect(
        action,
        'urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI',
      );
      expect(envelope, isNot(contains('<Evil>')));
      expect(
        envelope,
        contains('&lt;/CurrentURI&gt;&lt;Evil&gt;1&lt;/Evil&gt;&amp;'),
      );
    });

    test('a bad service, action or argument name is refused', () {
      for (final soap in [
        {'service': 'http://x', 'action': 'Play'},
        {'service': 'urn:x:1', 'action': 'Play Now'},
        {
          'service': 'urn:x:1',
          'action': 'Play',
          'args': {'a b': 1},
        },
      ]) {
        expect(() => soapRequest(soap), throwsArgumentError, reason: '$soap');
      }
    });

    test('flattenXml reads leaves, attributes, entities and CDATA', () {
      expect(
        flattenXml(
          '<?xml version="1.0"?><r><a-b>1</a-b><c x="y">T &amp; J</c>'
          '<d><![CDATA[<raw>]]></d><e/></r>',
        ),
        {'a_b': 1, 'c_x': 'y', 'c': 'T & J', 'd': '<raw>', 'e': ''},
      );
      expect(flattenXml('not xml'), isNull);
    });
  });
}
