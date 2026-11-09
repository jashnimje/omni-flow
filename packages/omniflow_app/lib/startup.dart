import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:omniflow_engine/omniflow_engine.dart';

import 'api/engine_client.dart';
import 'service/service_engine_client.dart';
import 'state/providers.dart';
import 'ui/home.dart';
import 'ui/theme.dart';

/// The engine the app talks to, and why the hub did not start, if it did not.
typedef Started = ({EngineClient client, String? hubError});

/// Opens the engine in [home] and starts the hub, which is what fires flows
/// on their own, polls devices and hears board hellos. A hub that fails to
/// start leaves the app usable and reports why.
Future<Started> startEngine({
  required Directory home,
  required SecretStore secrets,
  PacketTap? tap,
  int wizListenPort = 38900,
  int boardHelloPort = 38951,
}) async {
  final engine = await OmniEngine.open(home: home, secrets: secrets, tap: tap);
  final client = InProcessEngineClient(engine);
  final result = await client.call('hub.start', {
    'wizPort': wizListenPort,
    'helloPort': boardHelloPort,
  });
  return (
    client: client,
    hubError: result['ok'] == true ? null : errorMessage(result),
  );
}

/// Runs [start] and shows the app on its engine, or the failure with a way
/// to try again instead of leaving the splash screen up. When the engine's
/// service stops (its notification's Stop button), it says so and offers to
/// start it again.
class Launcher extends StatefulWidget {
  const Launcher({super.key, required this.start, this.platform = const []});

  final Future<Started> Function() start;

  /// The phone's own adapters (NFC, permissions), which tests leave out.
  final List<Override> platform;

  @override
  State<Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<Launcher> {
  late Future<Started> _started;
  StreamSubscription<Map<String, Object?>>? _stoppedSub;
  String? _stopped;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _run() {
    _stopped = null;
    _stoppedSub?.cancel();
    _stoppedSub = null;
    final started = _started = widget.start();
    started.then((s) {
      if (!mounted || _started != started) return;
      _stoppedSub = s.client.events
          .where((e) => e['event'] == serviceStoppedEvent)
          .listen((e) => setState(() => _stopped = '${e['reason']}'));
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _stoppedSub?.cancel();
    super.dispose();
  }

  Widget _screen(Widget child) => MaterialApp(
    title: 'OmniFlow',
    theme: omniTheme(),
    home: Scaffold(body: Center(child: child)),
  );

  @override
  Widget build(BuildContext context) {
    if (_stopped case final reason?) {
      return _screen(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('OmniFlow is stopped'),
              const SizedBox(height: 8),
              Text(reason, key: const ValueKey('stopped-reason')),
              const SizedBox(height: 4),
              const Text('Flows do not run until it starts again.'),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('service-start'),
                onPressed: () => setState(_run),
                child: const Text('Start'),
              ),
            ],
          ),
        ),
      );
    }
    return _starting(context);
  }

  Widget _starting(BuildContext context) => FutureBuilder<Started>(
    future: _started,
    builder: (context, snap) {
      if (snap.data case final started?) {
        return ProviderScope(
          overrides: [
            engineClientProvider.overrideWithValue(started.client),
            hubErrorProvider.overrideWithValue(started.hubError),
            ...widget.platform,
          ],
          child: const OmniFlowApp(),
        );
      }
      return _screen(
        snap.hasError
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('OmniFlow could not start'),
                    const SizedBox(height: 8),
                    Text('${snap.error}', key: const ValueKey('start-error')),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const ValueKey('start-retry'),
                      onPressed: () => setState(_run),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            : const CircularProgressIndicator(),
      );
    },
  );
}
