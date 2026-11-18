import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show EngineApi;
import '../../nfc/nfc.dart';
import '../../state/providers.dart';
import '../design/design.dart';

/// Writes the link the engine gives for [tag] onto a physical tag, so a
/// scan opens OmniFlow and names the tag even when the app is closed.
/// True when a tag was written.
Future<bool> writeTag(BuildContext context, WidgetRef ref, Json tag) =>
    writeTagWith(
      context,
      api: ref.read(engineApiProvider),
      adapter: ref.read(nfcAdapterProvider),
      tag: tag,
    );

/// [writeTag] for a caller whose widget may be gone by the time the tag is
/// held to the phone.
Future<bool> writeTagWith(
  BuildContext context, {
  required EngineApi api,
  required NfcAdapter adapter,
  required Json tag,
}) async {
  final reply = await api.tagPayload('${tag['id']}');
  if (!reply.ok || !context.mounted) return false;
  final payload = reply.value;
  if (payload == null) {
    showMessage('OmniFlow sent nothing to write on the tag');
    return false;
  }
  final written = await SheetTemplate.show<NfcScan>(
    context,
    dismissible: false,
    builder: (_) => WriteTagSheet(adapter: adapter, payload: payload),
  );
  if (written != null) {
    showMessage('Wrote ${tag['name']} on tag ${written.uid}');
  }
  return written != null;
}

/// Hold a tag to the phone: waits for the next tag and writes [payload] on
/// it, says why when it cannot, and Cancel gives up. Pops the scan of the
/// written tag.
class WriteTagSheet extends StatefulWidget {
  const WriteTagSheet({
    super.key,
    required this.adapter,
    required this.payload,
  });

  final NfcAdapter adapter;
  final TagPayload payload;

  @override
  State<WriteTagSheet> createState() => _WriteTagSheetState();
}

class _WriteTagSheetState extends State<WriteTagSheet> {
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
            ? 'Writing stopped while OmniFlow was in the background.'
            : e is NfcWriteError
            ? e.message
            : 'The tag could not be written. Hold it still against the '
                  'back of the phone and try again.',
      );
    }
  }

  void _cancel() {
    _cancelled = true;
    widget.adapter.cancelWrite();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => SheetTemplate(
    title: 'Write a tag',
    primaryLabel: _error == null ? null : 'Try again',
    primaryKey: const ValueKey('write-tag-retry'),
    onPrimary: _write,
    secondaryLabel: 'Cancel',
    onSecondary: _cancel,
    children: (context) => [
      OmniHeroCard(
        icon: OmniIcons.tag,
        centered: true,
        tone: _error == null ? HeroTone.accent : HeroTone.problem,
        title: _error == null ? 'Hold a tag to the phone' : 'Not written',
        subtitle:
            _error ?? 'Against the back, near the camera, until it buzzes.',
      ),
      Text(
        _error == null
            ? 'Waiting for a tag'
            : 'Try again with the tag held still, or cancel',
        key: const ValueKey('write-tag-status'),
        style: OmniText.captionOf(context),
        textAlign: TextAlign.center,
      ),
    ],
  );
}
