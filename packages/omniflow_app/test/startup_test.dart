import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/engine_client.dart';
import 'package:omniflow_app/service/hub_settings.dart';
import 'package:omniflow_app/startup.dart';

import 'fake_engine.dart';

/// A keystore whose reads fail: a value encrypted on another phone, or the
/// keystore busy for a moment.
class _RestoredStorage extends Fake implements FlutterSecureStorage {
  final deleted = <String>[];
  final written = <String>[];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => written.add(key);

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

  test('a keystore read error is reported and the entry is kept', () async {
    final storage = _RestoredStorage();
    final store = SecureStorageSecretStore(storage);
    await expectLater(
      store.read('app/hub/settings'),
      throwsA(
        isA<SecretReadException>()
            .having((e) => e.key, 'key', 'app/hub/settings')
            .having((e) => '$e', 'message', contains('It is kept')),
      ),
    );
    expect(storage.deleted, isEmpty);
  });

  test('hub settings survive a passing keystore error', () async {
    final storage = _RestoredStorage();
    final hub = HubSettingsStore(SecureStorageSecretStore(storage));
    await expectLater(hub.settings(), throwsA(isA<SecretReadException>()));
    await expectLater(
      hub.phoneKey('pixel'),
      throwsA(isA<SecretReadException>()),
      reason: 'a failed read must not make and save a new phone key',
    );
    expect(storage.deleted, isEmpty);
    expect(storage.written, isEmpty);
  });
}
