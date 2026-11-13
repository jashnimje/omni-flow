import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

class _Host implements FlowHost {
  final traces = <Map<String, Object?>>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<String?> webSecret(String name) async =>
      name == 'ha_token' ? 'fixture-value' : null;

  @override
  Future<bool> ranAt(String flowId, String scheduled) async => false;

  @override
  Future<void> markScheduled(String flowId, String scheduled) async {}

  @override
  Future<void> saveTrace(Map<String, Object?> trace) async => traces.add(trace);

  @override
  Future<void> saveGlobal(String name, Object? value) async {}

  @override
  void emit(Map<String, Object?> event) {}

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<Map<String, Object?>?> deviceState(String deviceId) async => null;

  @override
  Future<List<String>> roomDevices(String room) async => const [];

  @override
  Future<Map<String, Object?>?> invokeDevice(
    String deviceId,
    String capabilityId,
    Map<String, Object?> params, {
    String? flowId,
  }) async => null;

  @override
  Future<Map<String, Object?>?> toggleDevice(
    String deviceId,
    String capabilityId, {
    String? flowId,
  }) async => null;
}

class _FakeWeb implements WebRequester {
  final sent = <Map<String, String>>[];

  @override
  Future<WebReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    sent.add(headers);
    return (status: 200, body: 'fine', bytes: 4);
  }
}

Map<String, Object?> _flow(Map<String, Object?> config) => {
  'schemaVersion': 1,
  'id': 'tell',
  'name': 'Tell',
  'nodes': [
    {'id': 'go', 'type': 'manual'},
    {'id': 'send', 'type': 'http_request', 'config': config},
  ],
  'edges': [
    {
      'id': 'e',
      'from': {'node': 'go', 'port': 'out'},
      'to': {'node': 'send', 'port': 'in'},
    },
  ],
};

void main() {
  test('the flow engine reads secret headers from its host', () async {
    final host = _Host();
    final web = _FakeWeb();
    final engine = FlowEngine(host, web: web)
      ..load([
        FlowSpec.parse(
          _flow({
            'url': 'https://hub.test/api',
            'headers': {
              'Authorization': {'secret': 'ha_token'},
            },
          }),
        ),
      ]);
    final traces = await engine.run('tell');
    await engine.close();
    expect(traces.single.outcome, RunOutcome.completed);
    expect(web.sent.single, {'Authorization': 'fixture-value'});
    expect(jsonEncode(host.traces), isNot(contains('fixture-value')));
  });

  test('a saved flow names its secrets and keeps its host as written', () {
    List<String> issues(Map<String, Object?> config) => [
      for (final i in validateFlow(FlowSpec.parse(_flow(config)))) i.path,
    ];
    expect(issues({'url': r'http://{{$Host}}/x'}), [r'$.nodes[1].config.url']);
    expect(
      issues({
        'url': 'https://hub.test/',
        'headers': {'X-Api-Key': 'abc'},
      }),
      [r'$.nodes[1].config.headers.X-Api-Key'],
    );
    expect(
      issues({
        'url': 'https://hub.test/',
        'headers': {
          'X-Api-Key': {'secret': 'ha_token'},
          'Accept': 'application/json',
        },
      }),
      isEmpty,
    );
  });

  group('the addresses a request may reach', () {
    test('never this machine or link-local, the LAN yes', () {
      for (final refused in [
        '127.0.0.1',
        '127.8.0.1',
        '0.0.0.0',
        '::1',
        '::',
        '::ffff:127.0.0.1',
        '169.254.169.254',
        'fe80::1',
        'febf::1',
      ]) {
        expect(
          webAddressRefusal(InternetAddress(refused)),
          isNotNull,
          reason: refused,
        );
      }
      for (final allowed in [
        '192.168.1.20',
        '10.0.0.2',
        '172.16.4.1',
        '8.8.8.8',
        'fd00::1',
        'fec0::1',
      ]) {
        expect(
          webAddressRefusal(InternetAddress(allowed)),
          isNull,
          reason: allowed,
        );
      }
    });

    late HttpServer server;
    late List<String> seen;

    setUp(() async {
      seen = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add(request.uri.path);
        if (request.uri.path == '/go') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/elsewhere');
        } else {
          request.response.write('{"ok":true}');
        }
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('a request to this machine is refused before it connects', () async {
      for (final host in ['127.0.0.1', 'localhost']) {
        await expectLater(
          const IoWebRequester().send(
            'GET',
            Uri.parse('http://$host:${server.port}/'),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('this machine'),
            ),
          ),
          reason: host,
        );
      }
      expect(seen, isEmpty);
    });

    test('a redirect is the answer, not followed', () async {
      final reply = await IoWebRequester(refusal: (_) => null)
          .send('GET', Uri.parse('http://127.0.0.1:${server.port}/go'));
      expect(reply.status, HttpStatus.found);
      expect(seen, ['/go']);
    });

    test('a reply reports its size', () async {
      final reply = await IoWebRequester(refusal: (_) => null)
          .send('GET', Uri.parse('http://127.0.0.1:${server.port}/'));
      expect((reply.status, reply.bytes), (200, 11));
      expect(reply.body, {'ok': true});
    });
  });
}
