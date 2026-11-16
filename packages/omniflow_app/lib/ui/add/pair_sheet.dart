import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show ApiFailure;
import '../../state/providers.dart';
import '../design/design.dart';

/// Whether the pair sheet can finish pairing [device]. A `secret` pairing
/// ends with the user storing a token, which the guided steps take, so it
/// is not offered as a pairing that cannot complete.
bool pairsInApp(Map device) => switch (device['pairing']) {
  {'method': 'secret'} => false,
  Map() => true,
  _ => false,
};

/// Pairs a device again the way its driver needs (a TV prompt, a Hue link
/// button). The engine says what the user does: the prompt comes from the
/// device's `pairing`, the outcome from device.pair.
Future<void> showPairDevice(BuildContext context, Json device) =>
    SheetTemplate.show<void>(
      context,
      builder: (_) => PairDeviceSheet(device: device),
    );

class PairDeviceSheet extends ConsumerStatefulWidget {
  const PairDeviceSheet({super.key, required this.device});

  final Json device;

  @override
  ConsumerState<PairDeviceSheet> createState() => _PairDeviceSheetState();
}

class _PairDeviceSheetState extends ConsumerState<PairDeviceSheet> {
  var _pairing = false;
  var _paired = false;
  String? _outcome;
  var _failed = false;

  Future<void> _pair() async {
    final devices = ref.read(devicesProvider.notifier);
    setState(() {
      _pairing = true;
      _outcome = null;
    });
    final reply = await ref
        .read(engineApiProvider)
        .pairDevice('${widget.device['id']}');
    if (reply.ok) await devices.refresh();
    if (!mounted) return;
    setState(() {
      _pairing = false;
      _paired = reply.value?.paired == true;
      _failed = !reply.ok;
      _outcome =
          reply.value?.message ??
          switch (reply.failure) {
            final f? => pairFailureText(f),
            null => null,
          };
    });
  }

  @override
  Widget build(BuildContext context) {
    final pairing = widget.device['pairing'] as Map? ?? const {};
    return SheetTemplate(
      title: 'Pair ${widget.device['name']}',
      primaryLabel: _paired
          ? 'Done'
          : _outcome == null
          ? 'Start pairing'
          : 'Try again',
      primaryKey: ValueKey(_paired ? 'pair-done' : 'pair-start'),
      onPrimary: _paired
          ? () => Navigator.of(context).pop()
          : _pairing
          ? null
          : _pair,
      children: (context) => [
        Text(
          '${pairing['prompt'] ?? ''}',
          key: const ValueKey('pair-prompt'),
          style: OmniText.body,
        ),
        if (_pairing)
          const Padding(
            padding: EdgeInsets.only(top: OmniSpace.md),
            child: OmniProgressBar(semanticLabel: 'Pairing'),
          ),
        if (_outcome case final outcome?)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpace.md),
            child: _failed
                ? OmniBanner.error(outcome, key: const ValueKey('pair-outcome'))
                : OmniBanner.info(outcome, key: const ValueKey('pair-outcome')),
          ),
      ],
    );
  }
}

/// What a failed pairing says. A TV that refused the key answers needs_user
/// with CLI wording ("omni device pair"), so the app says it in plain words.
String pairFailureText(ApiFailure f) => f.type == 'needs_user'
    ? 'The TV did not let OmniFlow in. Look at the TV, choose Allow and tick '
          'Always allow, then try again.'
    : f.message;
