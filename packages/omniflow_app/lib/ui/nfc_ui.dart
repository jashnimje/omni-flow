import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_calls.dart';
import '../api/engine_client.dart';
import '../nfc/nfc.dart';
import '../state/providers.dart';
import 'add_thing.dart';

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
    } on Object catch (e) {
      showMessage('The tag scan did not reach OmniFlow: $e');
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

/// Writes the link the engine gives for [tag] onto a physical tag, so a
/// scan opens OmniFlow and names the tag even when the app is closed.
Future<void> writeTag(BuildContext context, WidgetRef ref, Json tag) async {
  final adapter = ref.read(nfcAdapterProvider);
  final result = await callEngine(
    ref,
    EngineCalls.tagWritePayload,
    EngineCalls.tagWritePayloadArgs('${tag['id']}'),
  );
  if (result['ok'] != true || !context.mounted) return;
  final payload = EngineCalls.tagPayloadOf(result);
  if (payload == null) {
    showMessage('OmniFlow sent nothing to write on the tag');
    return;
  }
  final written = await showDialog<NfcScan>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WriteTagDialog(adapter: adapter, payload: payload),
  );
  if (written != null) {
    showMessage('Wrote ${tag['name']} on tag ${written.uid}');
  }
}

class _WriteTagDialog extends StatefulWidget {
  const _WriteTagDialog({required this.adapter, required this.payload});

  final NfcAdapter adapter;
  final TagPayload payload;

  @override
  State<_WriteTagDialog> createState() => _WriteTagDialogState();
}

class _WriteTagDialogState extends State<_WriteTagDialog> {
  String? _error;
  var _cancelled = false;

  @override
  void initState() {
    super.initState();
    _write();
  }

  Future<void> _write() async {
    setState(() => _error = null);
    try {
      final scan = await widget.adapter.writeNext(widget.payload);
      if (mounted) Navigator.of(context).pop(scan);
    } on Object catch (e) {
      // A cancel the user did not ask for came from the app going to the
      // background, which stops the reader.
      if (!mounted || _cancelled) return;
      setState(
        () => _error = '$e' == 'Cancelled'
            ? 'Writing stopped while OmniFlow was in the background'
            : '$e',
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Write a tag'),
    content: Text(
      _error ?? 'Hold a tag to the back of the phone.',
      key: const ValueKey('write-tag-status'),
    ),
    actions: [
      if (_error != null)
        TextButton(
          key: const ValueKey('write-tag-retry'),
          onPressed: _write,
          child: const Text('Try again'),
        ),
      TextButton(
        key: const ValueKey('write-tag-cancel'),
        onPressed: () {
          _cancelled = true;
          widget.adapter.cancelWrite();
          Navigator.of(context).pop();
        },
        child: const Text('Cancel'),
      ),
    ],
  );
}
