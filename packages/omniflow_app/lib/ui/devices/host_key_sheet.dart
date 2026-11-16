import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../../api/screen_calls.dart';

/// Whether [d] runs commands over SSH, so it has a host key to check.
bool usesSsh(DeviceView d) =>
    d.host != null && d.capabilities.any((c) => c['type'] == 'exec');

/// The host key OmniFlow pinned for [d] next to the one it offers now, so
/// a changed key (the Mac was reinstalled) can be checked and accepted.
Future<void> showHostKeySheet(BuildContext context, DeviceView d) =>
    showOmniSheet<void>(context, builder: (_) => _HostKeySheet(d));

class _HostKeySheet extends ConsumerStatefulWidget {
  const _HostKeySheet(this.device);

  final DeviceView device;

  @override
  ConsumerState<_HostKeySheet> createState() => _HostKeySheetState();
}

class _HostKeySheetState extends ConsumerState<_HostKeySheet> {
  Json? _key;
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _call(String action, [Json extra = const {}]) async {
    setState(() => _busy = true);
    final r = await ref.read(engineClientProvider).call(DeviceCalls.hostKey, {
      'id': widget.device.id,
      'action': action,
      ...extra,
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['ok'] == true) {
        _key = r;
        _error = null;
      } else {
        _error = errorMessage(r);
      }
    });
  }

  Future<void> _look() => _call('show');

  Future<void> _accept(String offered) async {
    final ok = await confirm(
      context,
      title: 'Trust this key?',
      body:
          'Only if you know why it changed, like a reinstall. A key that '
          'changed for no reason can mean another computer is answering '
          'at that address.',
      action: 'Trust it',
    );
    if (!ok || !mounted) return;
    await _call('accept', {'fingerprint': offered});
    if (_error == null && mounted) await _look();
  }

  @override
  Widget build(BuildContext context) {
    final key = _key;
    final pinned = key?['pinned'] as String?;
    final offered = key?['offered'] as String?;
    final matches = key?['matches'] == true;
    final changed = pinned != null && offered != null && !matches;
    final canTrust = offered != null && !matches;
    return SheetTemplate(
      title: 'SSH host key',
      subtitle:
          'How OmniFlow knows it is talking to ${widget.device.name} and '
          'not another computer.',
      state: key != null
          ? OmniLoad.data(error: _error, onRetry: _busy ? null : _look)
          : _error != null
          ? OmniLoad.error(_error!, _busy ? null : _look)
          : const OmniLoad.loading(),
      primaryLabel: canTrust ? 'Trust the key it offers now' : null,
      primaryKey: const ValueKey('hostkey-accept'),
      onPrimary: canTrust && !_busy ? () => _accept(offered) : null,
      secondaryLabel: 'Check again',
      onSecondary: _busy ? null : _look,
      children: (context) => [
        if (changed)
          const OmniBanner.warning(
            'The key changed since OmniFlow first met it, so commands to '
            'it are stopped.',
            key: ValueKey('hostkey-changed'),
          )
        else if (matches)
          const OmniBanner.info(
            'The key is the one OmniFlow trusts.',
            key: ValueKey('hostkey-ok'),
          ),
        if (key!['error'] case final String e)
          OmniBanner.error('It did not answer: $e'),
        OmniListRow(
          key: const ValueKey('hostkey-pinned'),
          title: 'Trusted',
          subtitle: pinned ?? 'None yet: the next connection trusts it',
        ),
        OmniListRow(
          key: const ValueKey('hostkey-offered'),
          title: 'Offered now',
          subtitle: offered ?? 'Unknown',
          divider: false,
        ),
      ],
    );
  }
}
