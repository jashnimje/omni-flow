import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../devices/fake_mdns.dart';

/// Waits until [done] holds, failing after five seconds.
Future<void> until(FutureOr<bool> Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Map<String, Object?> edge(String from, String port, String to) => {
  'id': '$from-$to',
  'from': {'node': from, 'port': port},
  'to': {'node': to, 'port': 'in'},
};

Map<String, Object?> flowJson(
  String id,
  List<Map<String, Object?>> nodes,
  List<Map<String, Object?>> edges, {
  String? mode,
  int? cooldown,
}) => {
  'schemaVersion': 1,
  'id': id,
  'name': id,
  'mode': ?mode,
  'cooldownSeconds': ?cooldown,
  'nodes': nodes,
  'edges': edges,
};

Map<String, Object?> node(
  String id,
  String type, [
  Map<String, Object?> config = const {},
]) => {'id': id, 'type': type, 'config': config};

/// A loopback WiZ bulb that records every command.
Future<(UdpTransport, List<Map>)> fakeBulb() async {
  final received = <Map>[];
  final bulb = await UdpTransport.bind();
  bulb.incoming.listen((d) {
    final m = jsonDecode(d.text) as Map;
    received.add(m);
    bulb.send(
      d.address,
      d.port,
      utf8.encode(
        jsonEncode({
          'method': m['method'],
          'result': {'success': true},
        }),
      ),
    );
  });
  return (bulb, received);
}

const _tuyaKey = '0123456789abcdef';
const _tuyaDevId = 'bf0000000000000000test';

/// A loopback Tuya plug that acknowledges control frames and can push a
/// status by itself, the way a press of its own button does.
class FakePlug {
  FakePlug._(this._server) {
    _server.listen((socket) {
      _sockets.add(socket);
      final splitter = TuyaFrameSplitter();
      socket.listen((Uint8List chunk) {
        for (final raw in splitter.add(chunk)) {
          final frame = _codec.decode(raw, fromDevice: false);
          if (frame.command == TuyaCommand.control) {
            socket.add(
              _codec.encode(
                seq: frame.seq,
                command: TuyaCommand.control,
                body: null,
                retcode: 0,
              ),
            );
          }
        }
      });
    });
  }

  static Future<FakePlug> start() async =>
      FakePlug._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final _codec = TuyaCodec(_tuyaKey);
  final _sockets = <Socket>[];

  int get port => _server.port;

  void push(Map<String, Object?> dps) {
    for (final s in _sockets) {
      s.add(
        _codec.encode(
          seq: 0,
          command: TuyaCommand.status,
          body: {'devId': _tuyaDevId, 'dps': dps},
          retcode: 0,
        ),
      );
    }
  }

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

void main() {
  late Directory home;
  late InMemorySecretStore secrets;
  late OmniEngine engine;

  Future<OmniEngine> open() => OmniEngine.open(
    home: home,
    secrets: secrets,
    mdns: MdnsDiscovery(client: () => FakeMdns(const [])),
  );

  setUp(() async {
    home = await Directory.systemTemp.createTemp('omni_core');
    secrets = InMemorySecretStore();
    engine = await open();
  });

  tearDown(() async {
    await engine.close();
    await home.delete(recursive: true);
  });

  Future<Map<String, Object?>> ok(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isTrue, reason: '$command: $result');
    return result;
  }

  Future<Map<String, Object?>> err(
    String command,
    Map<String, Object?> args,
  ) async {
    final result = await engine.handle(command, args);
    expect(result['ok'], isFalse, reason: '$command: $result');
    return result['error'] as Map<String, Object?>;
  }

  Future<void> addExecDevice() => ok('device.add', {
    'id': 'mac_mini',
    'driver': 'macos_host',
    // TEST-NET: a broken guard fails to connect instead of running here.
    'host': '192.0.2.1',
  });

  Map<String, Object?> wakeFlow(String id) => flowJson(
    id,
    [
      node('go', 'manual'),
      node('wake', 'device_capability', {
        'deviceId': 'mac_mini',
        'capabilityId': 'display_wake',
      }),
    ],
    [edge('go', 'out', 'wake')],
  );

  group('hub', () {
    test('hub.start twice listens once, and hub.stop stops it', () async {
      final helloPort = await _freeUdpPort();
      final started = await ok('hub.start', {
        'wizPort': 0,
        'helloPort': helloPort,
      });
      expect(started['running'], isTrue);
      await ok('hub.start', {'wizPort': 0, 'helloPort': helloPort});
      expect((await ok('engine.status', {}))['hubRunning'], isTrue);

      final found = <Map>[];
      final sub = engine.events
          .where((e) => e['event'] == 'board.found')
          .listen(found.add);
      addTearDown(sub.cancel);
      final board = await UdpTransport.bind();
      addTearDown(board.close);
      board.send(
        InternetAddress.loopbackIPv4,
        helloPort,
        utf8.encode(
          jsonEncode({'node': 'hall-board', 'event': 'hello', 'port': 4210}),
        ),
      );
      await until(() => found.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(found, hasLength(1));
      expect(found.single['add'], {
        'id': 'hall_board',
        'name': 'hall-board',
        'driver': 'omniflow_board',
        'host': '127.0.0.1',
        'port': 4210,
        'stableId': 'hall-board',
      });

      await ok('hub.stop', {});
      expect((await ok('engine.status', {}))['hubRunning'], isFalse);
      // The hello port is free again.
      final rebound = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        helloPort,
        reuseAddress: false,
      );
      rebound.close();
    });

    test('hub.stop stops interval flows', () async {
      await ok('flow.save', {
        'flow': flowJson(
          'tick',
          [
            node('every', 'interval', {'seconds': 1}),
            node('note', 'notify', {'title': 'tick'}),
          ],
          [edge('every', 'out', 'note')],
          mode: 'parallel',
        ),
      });
      final ticks = <Map>[];
      final sub = engine.events
          .where((e) => e['event'] == 'run.finished')
          .listen(ticks.add);
      addTearDown(sub.cancel);
      await ok('hub.start', {'wizPort': 0, 'helloPort': 0});
      await until(() => ticks.isNotEmpty);
      await ok('hub.stop', {});
      final seen = ticks.length;
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(ticks, hasLength(seen));
    });

    test('a port in use is an unavailable error, not a crash', () async {
      final taken = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: false,
      );
      addTearDown(taken.close);
      final error = await err('hub.start', {
        'wizPort': 0,
        'helloPort': taken.port,
      });
      expect(error['type'], 'unavailable');
      expect((await ok('engine.status', {}))['hubRunning'], isFalse);
    });

    test(
      'a device added while the hub runs is polled, until it is removed',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var polls = 0;
        server.listen((r) {
          polls++;
          r.response
            ..write('{"on": true}')
            ..close();
        });
        await ok('driver.register', {
          'manifest': {
            'schemaVersion': 1,
            'id': 'polled_gadget',
            'name': 'Polled gadget',
            'category': 'misc',
            'transport': {'type': 'http'},
            'statePoll': {
              'intervalSeconds': 1,
              'command': {'path': '/state'},
            },
            'capabilities': [
              {
                'id': 'ping',
                'type': 'action',
                'command': {'path': '/ping'},
              },
            ],
          },
        });
        await ok('hub.start', {'wizPort': 0, 'helloPort': 0});
        await ok('device.add', {
          'id': 'gadget',
          'driver': 'polled_gadget',
          'host': '127.0.0.1',
          'port': server.port,
        });
        await until(() => polls > 0);
        await ok('device.remove', {'id': 'gadget'});
        final seen = polls;
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        expect(polls, seen);
      },
    );
  });

  group('opening', () {
    Future<void> seed(Future<void> Function(OmniDatabase db) write) async {
      await engine.close();
      final db = OmniDatabase.file(File('${home.path}/omniflow.sqlite'));
      await write(db);
      await db.close();
    }

    test('a bad stored driver and flow are reported, not fatal', () async {
      await seed((db) async {
        await DriftManifestStore(db).put(
          'philips_wiz_udp',
          jsonEncode({'schemaVersion': 1, 'id': 'philips_wiz_udp'}),
          DateTime.now(),
        );
        await DriftFlowStore(db).put(
          'teleport',
          flowJson(
            'teleport',
            [node('go', 'manual'), node('beam', 'teleport')],
            [edge('go', 'out', 'beam')],
          ),
          enabled: true,
          approved: true,
          at: DateTime.now(),
        );
      });
      engine = await open();
      final status = await ok('engine.status', {});
      final issues = (status['loadIssues'] as List).cast<Map>();
      expect(
        {for (final i in issues) i['kind']: i['id']},
        {'driver': 'philips_wiz_udp', 'flow': 'teleport'},
      );
      expect((await ok('flow.list', {}))['loadIssues'], hasLength(2));
      expect((await ok('driver.list', {}))['loadIssues'], hasLength(2));
      await ok('flow.save', {
        'flow': flowJson(
          'fine',
          [
            node('go', 'manual'),
            node('note', 'notify', {'title': 'hi'}),
          ],
          [edge('go', 'out', 'note')],
        ),
      });
      expect(engine.flows.loadedFlows, ['fine']);
    });

    test('a failed open releases the lock', () async {
      await engine.close();
      File('${home.path}/omniflow.sqlite')
          .writeAsStringSync('not sqlite' * 100);
      Object? first;
      try {
        engine = await open();
      } catch (e) {
        first = e;
      }
      expect(first, isNotNull);
      expect(first, isNot(isA<DatabaseInUseException>()));
      await expectLater(open(), throwsA(isNot(isA<DatabaseInUseException>())));
      File('${home.path}/omniflow.sqlite').deleteSync();
      engine = await open();
    });
  });

  group('reloading', () {
    test(
      'saving flow B leaves flow A running, with its delay and cooldown',
      () async {
        final (bulb, received) = await fakeBulb();
        addTearDown(bulb.close);
        await ok('device.add', {
          'id': 'lamp',
          'driver': 'philips_wiz_udp',
          'host': '127.0.0.1',
          'port': bulb.localPort,
        });
        await ok('flow.save', {
          'flow': flowJson(
            'slow',
            [
              node('go', 'manual'),
              node('wait', 'delay', {'ms': 400}),
              node('on', 'device_capability', {
                'deviceId': 'lamp',
                'capabilityId': 'power',
                'params': {'value': true},
              }),
            ],
            [edge('go', 'out', 'wait'), edge('wait', 'out', 'on')],
            cooldown: 3600,
          ),
        });
        final run = engine.handle('flow.run', {'id': 'slow'});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await ok('flow.save', {
          'flow': flowJson(
            'other',
            [
              node('go', 'manual'),
              node('note', 'notify', {'title': 'hi'}),
            ],
            [edge('go', 'out', 'note')],
          ),
        });
        final runs = (await run)['runs'] as List;
        expect((runs.single as Map)['outcome'], 'completed');
        expect(received.map((m) => m['method']), ['setState']);
        final again = await ok('flow.run', {'id': 'slow'});
        expect(((again['runs'] as List).single as Map)['reason'], 'cooldown');
      },
    );

    test('a dropped run is counted, not logged', () async {
      await ok('flow.save', {
        'flow': flowJson(
          'once',
          [
            node('go', 'manual'),
            node('note', 'notify', {'title': 'hi'}),
          ],
          [edge('go', 'out', 'note')],
          cooldown: 3600,
        ),
      });
      final first = await ok('flow.run', {'id': 'once'});
      final second = await ok('flow.run', {'id': 'once'});
      final ids = {
        for (final r in [first, second])
          ((r['runs'] as List).single as Map)['run'],
      };
      expect(ids, hasLength(2));
      await until(() async {
        final log = (await ok('flow.log', {'id': 'once'}))['runs'] as List;
        return log.isNotEmpty;
      });
      final log = (await ok('flow.log', {'id': 'once'}))['runs'] as List;
      expect(log.map((r) => (r as Map)['outcome']), ['completed']);
      final listed = ((await ok('flow.list', {}))['flows'] as List).single;
      expect((listed as Map)['dropped'], 1);
    });

    test(
      'a key-less device trigger ignores a save with nothing changed',
      () async {
        await ok('device.add', {
          'id': 'lamp',
          'driver': 'philips_wiz_udp',
          'host': '127.0.0.1',
        });
        await ok('flow.save', {
          'flow': flowJson(
            'any_change',
            [
              node('changed', 'device_state', {'deviceId': 'lamp'}),
              node('note', 'notify', {'title': 'changed'}),
            ],
            [edge('changed', 'out', 'note')],
            mode: 'parallel',
          ),
        });
        final runs = <Map>[];
        final sub = engine.events
            .where((e) => e['event'] == 'run.finished')
            .listen(runs.add);
        addTearDown(sub.cancel);
        await engine.devices.mergeState('lamp', {'dimming': 10});
        await until(() => runs.length == 1);
        await engine.devices.mergeState('lamp', const {});
        await engine.devices.mergeState('lamp', {'dimming': 20});
        await until(() => runs.length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(runs, hasLength(2));
      },
    );

    test('saving another zone keeps a zone inside', () async {
      await ok('zone.save', {
        'zone': {
          'id': 'home',
          'wifi': {
            'ssids': ['HomeNet'],
          },
        },
      });
      await ok('sensor.wifi', {'ssid': 'HomeNet'});
      final changes = <Map>[];
      final sub = engine.events
          .where((e) => e['event'] == 'zone.changed')
          .listen(changes.add);
      addTearDown(sub.cancel);
      await ok('zone.save', {
        'zone': {
          'id': 'office',
          'wifi': {
            'ssids': ['Work'],
          },
        },
      });
      final zones = (await ok('zone.list', {}))['zones'] as List;
      expect(
        zones.cast<Map>().firstWhere((z) => z['id'] == 'home')['inside'],
        isTrue,
      );
      await ok('sensor.wifi', {'ssid': 'HomeNet'});
      // The control: leaving home does emit, and is the only change.
      await ok('sensor.wifi', {'ssid': 'Cafe'});
      await until(() => changes.isNotEmpty);
      expect(changes.single, containsPair('transition', 'exited'));
    });
  });

  group('approval', () {
    test('a missing trusted flag counts as untrusted', () async {
      await addExecDevice();
      final saved = await ok('flow.save', {'flow': wakeFlow('wake')});
      expect((saved['highRisk'], saved['approved']), (true, false));
      expect(saved['revision'], isA<String>());
    });

    test('run_flow into a high-risk flow is high risk too', () async {
      await addExecDevice();
      await ok('flow.save', {'flow': wakeFlow('user_exec'), 'trusted': true});
      final caller = flowJson(
        'agent_caller',
        [
          node('go', 'manual'),
          node('call', 'run_flow', {'flowId': 'user_exec'}),
        ],
        [edge('go', 'out', 'call')],
      );
      final checked = await ok('flow.validate', {'flow': caller});
      expect(checked['highRisk'], isTrue);
      final saved = await ok('flow.save', {'flow': caller, 'trusted': false});
      expect((saved['highRisk'], saved['approved']), (true, false));
    });

    test('setting a global a high-risk flow reads is high risk', () async {
      await addExecDevice();
      final reader = flowJson(
        'exec_on_mode',
        [
          node('go', 'manual'),
          node('mode', 'var_equals', {'name': r'$Mode', 'value': 'wake'}),
          node('wake', 'device_capability', {
            'deviceId': 'mac_mini',
            'capabilityId': 'display_wake',
          }),
        ],
        [edge('go', 'out', 'mode'), edge('mode', 'true', 'wake')],
      );
      await ok('flow.save', {'flow': reader, 'trusted': true});
      Map<String, Object?> setter(String name) => flowJson(
        'set_${name.toLowerCase()}',
        [
          node('go', 'manual'),
          node('set', 'set_variable', {'name': '\$$name', 'value': 'wake'}),
        ],
        [edge('go', 'out', 'set')],
      );
      final risky = await ok('flow.save', {'flow': setter('Mode')});
      expect((risky['highRisk'], risky['approved']), (true, false));
      final harmless = await ok('flow.save', {'flow': setter('Other')});
      expect((harmless['highRisk'], harmless['approved']), (false, true));
    });

    test(
      'approval is revoked when a device under the flow becomes high risk',
      () async {
        await ok('device.add', {
          'id': 'box',
          'driver': 'philips_wiz_udp',
          'host': '127.0.0.1',
        });
        final flow = flowJson(
          'box_on',
          [
            node('go', 'manual'),
            node('on', 'device_capability', {
              'deviceId': 'box',
              'capabilityId': 'power',
              'params': {'value': true},
            }),
          ],
          [edge('go', 'out', 'on')],
        );
        final saved = await ok('flow.save', {'flow': flow, 'trusted': false});
        expect(saved['approved'], isTrue);
        expect(engine.flows.loadedFlows, ['box_on']);
        // Replaced by an exec device under the same id.
        await ok('device.add', {
          'id': 'box',
          'driver': 'macos_host',
          'host': '192.0.2.1',
          'replace': true,
        });
        final listed = ((await ok('flow.list', {}))['flows'] as List).single;
        expect((listed as Map)['approved'], isFalse);
        expect(listed['highRisk'], isTrue);
        expect(engine.flows.loadedFlows, isEmpty);
      },
    );

    test('an untrusted save over a trusted flow is not approved', () async {
      final mine = flowJson(
        'mine',
        [
          node('go', 'manual'),
          node('note', 'notify', {'title': 'mine'}),
        ],
        [edge('go', 'out', 'note')],
      );
      await ok('flow.save', {'flow': mine, 'trusted': true});
      final theirs = flowJson(
        'mine',
        [
          node('go', 'manual'),
          node('note', 'notify', {'title': 'changed by an agent'}),
        ],
        [edge('go', 'out', 'note')],
      );
      final saved = await ok('flow.save', {'flow': theirs, 'trusted': false});
      expect((saved['highRisk'], saved['approved']), (false, false));
      expect(engine.flows.loadedFlows, isEmpty);
    });

    test('a link from an untrusted caller is untrusted', () async {
      for (final id in ['lamp', 'hall']) {
        await ok('device.add', {
          'id': id,
          'driver': 'philips_wiz_udp',
          'host': '127.0.0.1',
        });
      }
      await engine.devices.mergeState('lamp', {'state': true});
      final link = {'from': 'lamp.state', 'to': 'hall.power', 'mode': 'follow'};
      final mine = await ok('link.create', {...link, 'trusted': true});
      expect(mine['approved'], isTrue);
      final again = await ok('link.create', {...link, 'replace': true});
      expect(again['approved'], isFalse);
      final record = await ok('flow.get', {'id': mine['id']});
      expect(record['flow'], isNot(contains('_trusted')));
    });
  });

  group('run_flow cycles', () {
    Map<String, Object?> caller(String id, String target) => flowJson(
      id,
      [
        node('go', 'manual'),
        node('call', 'run_flow', {'flowId': target}),
      ],
      [edge('go', 'out', 'call')],
      mode: 'queued',
    );

    test('a flow that runs itself is refused', () async {
      final error = await err('flow.save', {'flow': caller('loop', 'loop')});
      expect('${error['issues']}', contains('cannot run itself'));
    });

    test('A -> B -> A is refused when the cycle closes', () async {
      await ok('flow.save', {
        'flow': flowJson(
          'b',
          [
            node('go', 'manual'),
            node('note', 'notify', {'title': 'b'}),
          ],
          [edge('go', 'out', 'note')],
        ),
      });
      await ok('flow.save', {'flow': caller('a', 'b')});
      final error = await err('flow.save', {'flow': caller('b', 'a')});
      expect('${error['issues']}', contains('leads back to b'));
    });
  });

  group('devices', () {
    test('adding an existing id is refused unless replacing', () async {
      final args = {
        'id': 'lamp',
        'driver': 'philips_wiz_udp',
        'host': '127.0.0.1',
      };
      await ok('device.add', args);
      expect((await err('device.add', args))['type'], 'exists');
      await ok('device.add', {...args, 'host': '127.0.0.2', 'replace': true});
      final got = await ok('device.get', {'id': 'lamp'});
      expect((got['device'] as Map)['host'], '127.0.0.2');
    });

    test(
      'removing a device deletes its secrets and disables its flows',
      () async {
        await ok('device.add', {
          'id': 'plug',
          'driver': 'tuya_plug',
          'host': '127.0.0.1',
          'settings': {'devId': 'bf00'},
        });
        await ok('secret.set', {
          'deviceId': 'plug',
          'key': 'localKey',
          'value': 'k' * 16,
        });
        await ok('flow.save', {
          'flow': flowJson(
            'plug_watch',
            [
              node('changed', 'device_state', {'deviceId': 'plug'}),
              node('note', 'notify', {'title': 'plug changed'}),
            ],
            [edge('changed', 'out', 'note')],
          ),
        });
        final removed = await ok('device.remove', {'id': 'plug'});
        expect(removed['removed'], isTrue);
        expect(removed['flows'], ['plug_watch']);
        expect(await secrets.read('device/plug/localKey'), isNull);
        expect(engine.flows.loadedFlows, isEmpty);
      },
    );

    test('a device removed during an invoke stays removed', () async {
      final bulb = await UdpTransport.bind();
      addTearDown(bulb.close);
      final reply = Completer<UdpDatagram>();
      bulb.incoming.listen((d) {
        if (!reply.isCompleted) reply.complete(d);
      });
      await ok('device.add', {
        'id': 'lamp',
        'driver': 'philips_wiz_udp',
        'host': '127.0.0.1',
        'port': bulb.localPort,
      });
      final invoke = engine.handle('device.invoke', {
        'id': 'lamp',
        'capability': 'power',
        'params': {'value': true},
      });
      final request = await reply.future;
      await ok('device.remove', {'id': 'lamp'});
      bulb.send(
        request.address,
        request.port,
        utf8.encode('{"method":"setState","result":{"success":true}}'),
      );
      await invoke;
      expect((await err('device.get', {'id': 'lamp'}))['type'], 'not_found');
    });

    test('a Tuya plug pressed by hand updates its state', () async {
      final plug = await FakePlug.start();
      addTearDown(plug.close);
      await ok('device.add', {
        'id': 'plug',
        'driver': 'tuya_plug',
        'host': '127.0.0.1',
        'port': plug.port,
        'settings': {'devId': _tuyaDevId},
      });
      await secrets.write(deviceSecretKey('plug', 'localKey'), _tuyaKey);
      await ok('device.invoke', {
        'id': 'plug',
        'capability': 'power',
        'params': {'value': true},
      });
      final changed = engine.events.firstWhere(
        (e) =>
            e['event'] == 'device.stateChanged' &&
            ((e['device'] as Map)['state'] as Map)['1'] == false,
      );
      plug.push({'1': false});
      await changed.timeout(const Duration(seconds: 5));
    });

    test('device JSON says whether it is a board and online', () async {
      await ok('device.add', {
        'id': 'plug',
        'driver': 'tuya_plug',
        'host': '127.0.0.1',
        'settings': {'devId': 'bf00'},
      });
      await ok('device.add', {
        'id': 'mac',
        'driver': 'macos_host',
        'host': '192.0.2.1',
      });
      await ok('device.add', {
        'id': 'desk',
        'driver': 'omniflow_board',
        'host': '127.0.0.1',
        'provision': false,
      });
      final devices = {
        for (final d
            in ((await ok('device.list', {}))['devices'] as List).cast<Map>())
          d['id']: d,
      };
      expect(devices['desk']!['board'], isTrue);
      expect(devices['plug']!['board'], isFalse);
      expect(devices['plug']!['online'], isFalse);
      expect(devices['mac']!.containsKey('online'), isFalse);
      await engine.devices.mergeState('plug', const {});
      final plug = await ok('device.get', {'id': 'plug'});
      expect((plug['device'] as Map)['online'], isTrue);
    });
  });

  group('arguments', () {
    test('wrong types and bad times are invalid, not internal', () async {
      await ok('flow.save', {
        'flow': flowJson(
          'f',
          [
            node('go', 'manual'),
            node('note', 'notify', {'title': 'hi'}),
          ],
          [edge('go', 'out', 'note')],
        ),
      });
      expect(
        (await err('flow.dryRun', {'id': 'f', 'at': 'tomorrow'}))['type'],
        'invalid',
      );
      expect(
        (await err('device.discover', {
          'driver': 'philips_wiz_udp',
          'port': 'eighty',
        }))['type'],
        'invalid',
      );
      expect(
        (await err('sensor.ble', {'name': 'x', 'rssi': -50, 'at': 7}))['type'],
        'invalid',
      );
    });

    test(
      'a board name that is not snake case is refused before the port opens',
      () async {
        final error = await err('board.setup', {
          'port': '/dev/omni-does-not-exist',
          'name': 'Desk Board!',
        });
        expect(error['type'], 'invalid');
        expect(error['message'], contains('lower snake case'));
      },
    );
  });

  test('a failing trace write during close still releases the lock', () async {
    await ok('flow.save', {
      'flow': flowJson(
        'f',
        [
          node('go', 'manual'),
          node('note', 'notify', {'title': 'hi'}),
        ],
        [edge('go', 'out', 'note')],
      ),
    });
    final raw = sqlite3.open('${home.path}/omniflow.sqlite');
    raw.execute('DROP TABLE execution_log');
    raw.close();
    await ok('flow.run', {'id': 'f'});
    await engine.close();
    engine = await open();
  });
}

Future<int> _freeUdpPort() async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  s.close();
  return port;
}
