import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_client.dart';
import '../../api/plain_error.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'firmware_sheet.dart';

/// A board plugged into this phone with a USB cable, as `device.discover`
/// finds it: its port, name and what it is.
typedef UsbBoard = ({String port, String? node, String? board});

/// The boards on the phone's USB ports.
Future<List<UsbBoard>> findUsbBoards(EngineClient engine) async {
  final reply = await engine.call('device.discover', {
    'driver': 'omniflow_board',
    'windowMs': 1500,
  });
  return [
    for (final f in (reply['found'] as List? ?? const []))
      if (f is Map && '${f['host']}'.startsWith('usb:'))
        (
          port: '${f['host']}',
          node:
              (f['reply'] as Map?)?['node'] as String? ??
              f['stableId'] as String?,
          board: (f['reply'] as Map?)?['board'] as String?,
        ),
  ];
}

/// Sets a board on USB up from the phone: its name and its Wi-Fi, which the
/// board keeps in its flash. The password goes to the board only.
Future<void> showUsbBoardSheet(BuildContext context, {String? node}) =>
    showOmniSheet<void>(context, builder: (_) => _UsbBoardSheet(node: node));

class _UsbBoardSheet extends ConsumerStatefulWidget {
  const _UsbBoardSheet({this.node});

  /// The board to look for, when the sheet opens from its page.
  final String? node;

  @override
  ConsumerState<_UsbBoardSheet> createState() => _UsbBoardSheetState();
}

class _UsbBoardSheetState extends ConsumerState<_UsbBoardSheet> {
  List<UsbBoard>? _boards;
  UsbBoard? _picked;
  final _name = TextEditingController();
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _look();
    _prefillWifi();
  }

  @override
  void dispose() {
    _name.dispose();
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _prefillWifi() async {
    final phone = await ref.read(engineClientProvider).call('device.get', {
      'id': 'phone',
    });
    final ssid = ((phone['device'] as Map?)?['state'] as Map?)?['wifi_ssid'];
    if (ssid is String && mounted && _ssid.text.isEmpty) _ssid.text = ssid;
  }

  Future<void> _look() async {
    setState(() {
      _boards = null;
      _error = null;
    });
    final boards = await findUsbBoards(ref.read(engineClientProvider));
    if (!mounted) return;
    setState(() {
      _boards = boards;
      _picked =
          boards.where((b) => b.node == widget.node).firstOrNull ??
          (boards.length == 1 ? boards.single : null);
      if (_picked?.node case final n? when _name.text.isEmpty) _name.text = n;
    });
  }

  Future<void> _save() async {
    final board = _picked;
    if (board == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    final engine = ref.read(engineClientProvider);
    final reply = await engine.call('board.setup', {
      'port': board.port,
      if (_name.text.trim().isNotEmpty) 'name': _name.text.trim(),
      if (_ssid.text.trim().isNotEmpty) ...{
        'ssid': _ssid.text.trim(),
        'password': _password.text,
      },
    });
    if (!mounted) return;
    if (reply['ok'] != true) {
      setState(() {
        _busy = false;
        _error = errorMessage(reply);
      });
      return;
    }
    final wifi = reply['wifi'] as Map? ?? const {};
    var text = wifi['connected'] == true
        ? 'On ${_ssid.text.trim()} at ${wifi['ip'] ?? 'an address'}.'
        : _ssid.text.trim().isEmpty
        ? 'Saved on the board.'
        : 'Saved, but it has not joined ${_ssid.text.trim()} yet. Check the '
              'password, and that it is a 2.4 GHz network.';
    // thing.add knows the board by its stable id (the name in its flash):
    // set up again, it is found, not added twice. It makes a valid id from
    // whatever the name is.
    final node = reply['node'] as String? ?? board.node;
    final display = _name.text.trim().isEmpty
        ? (node ?? 'Board')
        : _name.text.trim();
    final added = await engine.call('thing.add', {
      'driver': 'omniflow_board',
      // On Wi-Fi it works unplugged; otherwise it stays a USB board.
      'host': wifi['ip'] as String? ?? board.port,
      'stableId': ?node,
      'name': display,
    });
    final error = added['error'] as Map?;
    if (added['ok'] == true) {
      text += ' Added to your devices.';
    } else if (error?['type'] != 'exists') {
      text +=
          ' ${plainError('${error?['type']}', error?['message'] as String?)}';
    }
    if (!mounted) return;
    await ref.read(devicesProvider.notifier).refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final boards = _boards;
    return OmniSheet(
      title: 'Board on USB',
      subtitle: 'Plug the board into this phone with a USB cable.',
      children: [
        if (boards == null)
          const Padding(
            padding: EdgeInsets.all(OmniSpace.lg),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (boards.isEmpty) ...[
          const OmniBanner.info(
            'No board found on USB. Use a data cable (some only charge), '
            'and say yes if the phone asks to let OmniFlow use it.',
            key: ValueKey('usb-none'),
          ),
          OmniButton.ghost(
            key: const ValueKey('usb-look-again'),
            label: 'Look again',
            icon: OmniIcons.retry,
            onPressed: _look,
          ),
          OmniButton.ghost(
            key: const ValueKey('usb-install'),
            label: 'It is new: install OmniFlow on it',
            icon: OmniIcons.board,
            onPressed: () => showFirmwareSheet(context),
          ),
        ] else ...[
          for (final b in boards)
            OmniListRow(
              key: ValueKey('usb-board-${b.port}'),
              icon: OmniIcons.board,
              title: b.node ?? 'A board',
              subtitle: b.board ?? b.port,
              trailing: identical(b, _picked)
                  ? const Icon(OmniIcons.check, color: OmniColors.accent)
                  : null,
              onTap: () => setState(() => _picked = b),
            ),
          const SizedBox(height: OmniSpace.sm),
          TextField(
            key: const ValueKey('usb-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name, like desk_board',
            ),
          ),
          const SizedBox(height: OmniSpace.sm),
          TextField(
            key: const ValueKey('usb-ssid'),
            controller: _ssid,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi network (2.4 GHz)',
              prefixIcon: Icon(OmniIcons.wifi),
            ),
          ),
          const SizedBox(height: OmniSpace.sm),
          TextField(
            key: const ValueKey('usb-password'),
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi password',
              helperText: 'Goes to the board only. OmniFlow does not keep it.',
            ),
          ),
          if (_error case final e?)
            OmniBanner.error(key: const ValueKey('usb-error'), e),
          if (_result case final r?)
            OmniBanner.info(key: const ValueKey('usb-result'), r),
          const SizedBox(height: OmniSpace.md),
          OmniButton(
            key: const ValueKey('usb-save'),
            label: _busy ? 'Setting up…' : 'Set it up',
            onPressed: _busy || _picked == null ? null : _save,
          ),
        ],
      ],
    );
  }
}
