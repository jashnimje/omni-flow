import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/startup.dart';

import 'fake_engine.dart';

/// A keystore whose values were encrypted on another phone.
class _RestoredStorage extends Fake implements FlutterSecureStorage {
  final deleted = <String>[];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw PlatformException(code: 'decrypt', message: 'bad key');

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => deleted.add(key);
}

void main() {
  testWidgets(
    'a failed start says so in plain words and Try again starts again',
    (tester) async {
      var attempts = 0;
      final engine = FakeEngine();
      await tester.pumpWidget(
        Launcher(
          start: () async {
            attempts++;
            if (attempts == 1) throw StateError('omniflow.sqlite is in use');
            return (client: engine as EngineClient, hubError: null);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('OmniFlow could not start'), findsOneWidget);
      expect(find.textContaining('omniflow.sqlite'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('start-retry')));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Desk lamp'), findsOneWidget);
    },
  );

  test('a secret the keystore cannot decrypt reads as missing', () async {
    final storage = _RestoredStorage();
    final store = SecureStorageSecretStore(storage);
    expect(await store.read('device.tv.localKey'), isNull);
    expect(storage.deleted, ['device.tv.localKey']);
  });
}
