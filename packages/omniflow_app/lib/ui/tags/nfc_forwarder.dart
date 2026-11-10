import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/engine_client.dart';
import '../../nfc/nfc.dart';
import '../../state/providers.dart';
import '../add/guided_steps_page.dart';
import '../add/name_sheet.dart';

/// Sends every tag the phone reads to the engine as `nfc.scanned`: tags
/// held to the phone while the app is open, the tag that opened the app,
/// and tags Android delivers while it runs. Matching a scan to a tag thing
/// is the engine's.
class NfcForwarder {
  NfcForwarder(this._engine, this._adapter, this._intents);

  final EngineClient _engine;
  final NfcAdapter _adapter;
  final NfcIntents _intents;
  StreamSubscription<NfcScan>? _sub;
  var _closed = false;

  Future<void> start() async {
    _sub = _intents.scans.listen(forward);
    final launch = await _intents.takeLaunchScan();
    if (launch != null && !_closed) await forward(launch);
    await resume();
  }

  Future<void> resume() async {
    if (!_closed) await _adapter.startReading(forward);
  }

  Future<void> pause() => _adapter.stop();

  Future<void> forward(NfcScan scan) async {
    if (_closed) return;
    final Json result;
    try {
      result = await _engine.call(
        EngineCalls.nfcScanned,
        EngineCalls.nfcScannedArgs(uid: scan.uid, ndef: scan.ndef),
      );
    } on Object {
      showMessage(
        'The tag scan did not reach OmniFlow. Hold it to the phone again.',
      );
      return;
    }
    if (result['ok'] != true) showMessage(errorMessage(result));
  }

  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    await _adapter.stop();
  }
}

/// Offers to name a tag the engine does not know, once per tag.
void offerToNameTag(
  BuildContext context,
  WidgetRef ref,
  Json event,
  Set<String> offered,
) {
  final uid = '${event['uid'] ?? event['writtenId'] ?? ''}';
  if (uid.isEmpty || !offered.add(uid)) return;
  messengerKey.currentState?.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 20),
      content: const Text('New NFC tag. Name it to use it in rules.'),
      action: SnackBarAction(
        label: 'Name it',
        onPressed: () => nameTag(context, ref, event),
      ),
    ),
  );
}

Future<void> nameTag(BuildContext context, WidgetRef ref, Json event) async {
  final named = await askName(context, title: 'Name this tag', withRoom: false);
  if (named == null || !context.mounted) return;
  await addAndFollow(
    context,
    ref,
    EngineCalls.tagCandidateOf(event),
    name: named.name,
  );
}
