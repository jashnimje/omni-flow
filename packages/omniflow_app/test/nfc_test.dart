import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:omniflow_app/nfc/nfc.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_engine/omniflow_engine.dart'
    show omniflowApplicationId, tagRecords;

import 'fake_engine.dart';

/// The phone's reader, driven by the test: [reader] is what the app
/// listens with, and [write] completes the write it is waiting on.
class FakeNfc implements NfcAdapter {
  void Function(NfcScan scan)? reader;
  var stops = 0;
  TagPayload? writing;
  Completer<NfcScan>? write;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> startReading(void Function(NfcScan scan) onScan) async =>
      reader = onScan;

  @override
  Future<NfcScan> writeNext(TagPayload payload) {
    writing = payload;
    return (write = Completer<NfcScan>()).future;
  }

  @override
  void cancelWrite() {
    if (write case final w? when !w.isCompleted) {
      w.completeError(const NfcWriteError('Cancelled'));
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    reader = null;
  }
}

class FakeIntents implements NfcIntents {
  NfcScan? launch;
  final delivered = StreamController<NfcScan>.broadcast();

  @override
  Future<NfcScan?> takeLaunchScan() async {
    final scan = launch;
    launch = null;
    return scan;
  }

  @override
  Stream<NfcScan> get scans => delivered.stream;
}

/// A URI record for https://example.com, abbreviated as the NFC Forum
/// prefix 0x04.
final exampleRecord = recordJson(
  1,
  const [0x55],
  [0x04, ...utf8.encode('example.com')],
);

void main() {
  late FakeEngine engine;
  late FakeNfc nfc;
  late FakeIntents intents;

  setUp(() {
    engine = FakeEngine();
    nfc = FakeNfc();
    intents = FakeIntents();
  });

  Future<void> pump(WidgetTester tester) => pumpApp(
    tester,
    engine,
    overrides: [
      nfcAdapterProvider.overrideWithValue(nfc),
      nfcIntentsProvider.overrideWithValue(intents),
    ],
  );

  testWidgets('a tag held to the phone while the app is open goes to the '
      'engine as nfc.scanned from the phone', (tester) async {
    await pump(tester);
    expect(nfc.reader, isNotNull);

    nfc.reader!(NfcScan('04A22B1C', [exampleRecord]));
    await tester.pumpAndSettle();

    expect(engine.callsOf('nfc.scanned').single.$2, {
      'uid': '04A22B1C',
      'ndef': [
        {'tnf': 1, 'type': '55', 'payload': '046578616D706C652E636F6D'},
      ],
      'source': 'phone',
    });
  });

  testWidgets('the tag that opened the app and tags Android delivers later '
      'are forwarded too', (tester) async {
    intents.launch = const NfcScan('04AA', []);
    await pump(tester);
    intents.delivered.add(const NfcScan('04BB', []));
    await tester.pumpAndSettle();

    expect(engine.callsOf('nfc.scanned').map((c) => c.$2['uid']), [
      '04AA',
      '04BB',
    ]);
  });

  testWidgets('reading stops while the app is in the background', (
    tester,
  ) async {
    await pump(tester);
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
    expect(nfc.reader, isNull);
    expect(nfc.stops, 1);

    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
    expect(nfc.reader, isNotNull);
  });

  testWidgets('an unknown tag is offered once, and naming it adds it', (
    tester,
  ) async {
    engine.answers['thing.add'] = {
      'ok': true,
      'id': 'front_door',
      'next': {'step': 'done'},
    };
    await pump(tester);
    for (var i = 0; i < 2; i++) {
      engine.eventsOut.add({'event': 'tag.unknown', 'uid': '04A22B1C'});
      await tester.pumpAndSettle();
    }
    expect(find.text('Name it'), findsOneWidget);

    await tester.tap(find.text('Name it'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-room')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('add-name')),
      'Front door',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-confirm')));
    await tester.pumpAndSettle();

    expect(engine.callsOf('thing.add').single.$2, {
      'candidate': {
        'driver': 'nfc_tag',
        'settings': {'uid': '04A22B1C'},
      },
      'name': 'Front door',
    });
    expect(find.text('Added Front door'), findsOneWidget);
  });

  testWidgets('an unknown tag the engine offers as a candidate is added as '
      'offered', (tester) async {
    await pump(tester);
    final candidate = {
      'driver': 'nfc_tag',
      'id': 'desk_drawer',
      'settings': {'uid': '04A22B1C'},
    };
    engine.eventsOut.add({
      'event': 'tag.unknown',
      'uid': '04A22B1C',
      'ndefId': 'desk_drawer',
      'source': 'phone',
      'add': candidate,
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name it'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('add-name')), 'Desk');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-confirm')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('thing.add').single.$2['candidate'], candidate);
  });

  group('NDEF', () {
    test('a tag message is the records tag.write_payload gives, byte for '
        'byte', () {
      final records = tagRecords('front_door');
      final message = tagMessage((
        uri: 'omniflow://tag/front_door',
        records: records,
      ));
      final [uri, app] = message.records;
      expect(uri.typeNameFormat, TypeNameFormat.wellKnown);
      expect(uri.payload, [0x00, ...utf8.encode('omniflow://tag/front_door')]);
      expect(app.typeNameFormat, TypeNameFormat.external);
      expect(utf8.decode(app.type), 'android.com:pkg');
      expect(utf8.decode(app.payload), omniflowApplicationId);
      expect([
        for (final r in recordsJson(message.records))
          {
            ...r,
            'type': '${r['type']}'.toLowerCase(),
            'payload': '${r['payload']}'.toLowerCase(),
          },
      ], records);
    });

    test('a record the app cannot write is refused before the tag is '
        'touched', () {
      for (final records in [
        <Map<String, Object?>>[],
        [
          {'tnf': 1, 'type': 'zz', 'payload': '00'},
        ],
        [
          {'tnf': 9, 'type': '55', 'payload': '00'},
        ],
      ]) {
        expect(
          () => tagMessage((uri: 'omniflow://tag/x', records: records)),
          throwsA(isA<NfcWriteError>()),
        );
      }
    });

    test('a record goes as the engine takes it: the tnf number, the type '
        'and payload in hex, and nothing decoded', () {
      final json = recordJson(1, utf8.encode('T'), [
        0x02,
        ...utf8.encode('en'),
        ...utf8.encode('hi'),
      ]);
      expect(json, {'tnf': 1, 'type': '54', 'payload': '02656E6869'});
    });

    test('an intent scan reads the UID and the records Android sent', () {
      final scan = scanFromPlatform({
        'uid': [0x04, 0xa2, 0x2b],
        'live': true,
        'records': [
          {
            'tnf': 4,
            'type': utf8.encode('android.com:pkg'),
            'payload': utf8.encode(omniflowApplicationId),
          },
        ],
      });
      expect(scan?.uid, '04A22B');
      expect(scan?.ndef.single, {
        'tnf': 4,
        'type': hexOf(utf8.encode('android.com:pkg')),
        'payload': hexOf(utf8.encode(omniflowApplicationId)),
      });
      expect(scanFromPlatform({'uid': <int>[], 'live': true}), isNull);
      expect(scanFromPlatform('nonsense'), isNull);
    });

    test('an intent scan MainActivity did not read again from the tag is '
        'dropped, so another app cannot make one up', () {
      final forged = {
        'uid': [1, 2, 3, 4],
        'records': [
          {
            'tnf': 1,
            'type': [0x55],
            'payload': [0x00, ...utf8.encode('omniflow://tag/front_door')],
          },
        ],
      };
      expect(scanFromPlatform(forged), isNull);
      expect(scanFromPlatform({...forged, 'live': 'true'}), isNull);
      expect(scanFromPlatform({...forged, 'live': true})?.uid, '01020304');
    });

    testWidgets('a made-up scan on the intent channel never reaches the '
        'engine', (tester) async {
      final channel = PlatformNfcIntents();
      final seen = <NfcScan>[];
      final sub = channel.scans.listen(seen.add);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<void> deliver(Map<String, Object?> scan) =>
          messenger.handlePlatformMessage(
            PlatformNfcIntents.channelName,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('scanned', scan),
            ),
            (_) {},
          );
      await tester.runAsync(() async {
        await deliver({
          'uid': Uint8List.fromList([1, 2, 3, 4]),
          'records': <Object?>[],
        });
        await deliver({
          'uid': Uint8List.fromList([5, 6, 7, 8]),
          'live': true,
          'records': <Object?>[],
        });
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
      });
      expect(seen.map((s) => s.uid), ['05060708']);
    });
  });
}
