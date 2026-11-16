import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'guided_steps_page.dart';

Future<void> openAddPhone(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const AddPhonePage()));

/// How the other phone is reached.
enum PhoneRoute {
  /// Android 11 and later: Wireless debugging, paired with a six-digit
  /// code.
  wireless,

  /// Any phone a computer has opened port 5555 on over USB.
  classic,
}

/// What the other phone's owner does to turn Wireless debugging on, in
/// order.
const phoneSetupSteps = [
  'On the other phone, open Settings, then System or About phone.',
  'Tap Build number 7 times, until it says you are now a developer.',
  'Go back to Settings, open System, then Developer options.',
  'Turn on Wireless debugging, and allow it on this Wi-Fi.',
  'Tap Pair device with pairing code. Keep that screen open: it shows a '
      'six-digit code and an address with a port.',
];

/// Add, Another phone: the steps on the other phone, the phones found on
/// mDNS, then the six-digit code, which goes to `android.pair` and is
/// cleared the moment it is sent. Once paired the phone is added on the
/// port it connects on. The classic route takes an address on port 5555.
class AddPhonePage extends ConsumerStatefulWidget {
  const AddPhonePage({super.key});

  @override
  ConsumerState<AddPhonePage> createState() => _AddPhonePageState();
}

class _AddPhonePageState extends ConsumerState<AddPhonePage> {
  var _route = PhoneRoute.wireless;
  var _step = 1;
  List<FoundPhone>? _found;
  var _looking = false;
  var _findMissing = false;
  FoundPhone? _picked;

  final _host = TextEditingController();
  final _pairPort = TextEditingController();
  final _code = TextEditingController();
  final _connectPort = TextEditingController();
  final _classicHost = TextEditingController();
  final _classicPort = TextEditingController(text: '5555');

  var _busy = false;
  String? _error;
  var _needsUpdate = false;

  /// Paired, and waiting for the port the phone connects on, which mDNS
  /// did not give.
  ({String host, String? guid})? _paired;

  @override
  void initState() {
    super.initState();
    unawaited(_look());
  }

  @override
  void dispose() {
    for (final c in [
      _host,
      _pairPort,
      _code,
      _connectPort,
      _classicHost,
      _classicPort,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<Json> _call(String command, Json args) =>
      ref.read(engineClientProvider).call(command, args);

  Future<List<FoundPhone>> _phones() async {
    final r = await _call(TvCalls.find, TvCalls.findArgs());
    if (r['ok'] == true) return TvCalls.phonesOf(r);
    if (TvCalls.isMissingCommand(r)) _findMissing = true;
    return const [];
  }

  Future<void> _look() async {
    setState(() => _looking = true);
    final found = await _phones();
    if (!mounted) return;
    setState(() {
      _looking = false;
      _found = found;
    });
  }

  void _pick(FoundPhone phone) => setState(() {
    _picked = phone;
    _host.text = phone.host;
    _pairPort.text = '${phone.pairingPort ?? ''}';
    _error = null;
  });

  static int? _port(String text) {
    final port = int.tryParse(text.trim());
    return port != null && port > 0 && port < 65536 ? port : null;
  }

  static final _codePattern = RegExp(r'^\d{6}$');

  Future<void> _pair() async {
    final host = _host.text.trim();
    final port = _port(_pairPort.text);
    final code = _code.text.trim();
    if (host.isEmpty || port == null) {
      setState(
        () => _error =
            'Type the address and port from Pair device with pairing code, '
            'such as 192.168.1.20 and 37123.',
      );
      return;
    }
    if (!_codePattern.hasMatch(code)) {
      setState(() => _error = 'The pairing code is six digits.');
      return;
    }
    // The code is used once, so it leaves the screen as it is sent.
    _code.clear();
    setState(() {
      _busy = true;
      _error = null;
      _needsUpdate = false;
    });
    final r = await _call(TvCalls.pair, TvCalls.pairArgs(host, port, code));
    if (!mounted) return;
    if (r['ok'] != true) {
      setState(() {
        _busy = false;
        if (TvCalls.isMissingCommand(r)) {
          _needsUpdate = true;
        } else {
          _error = errorMessage(r);
        }
      });
      return;
    }
    final guid = r['guid'] as String? ?? _picked?.guid;
    final connectPort = await _connectPortFor(host, guid);
    if (!mounted) return;
    if (connectPort == null) {
      setState(() {
        _busy = false;
        _paired = (host: host, guid: guid);
      });
      return;
    }
    await _add(host: host, port: connectPort, guid: guid, paired: true);
  }

  /// The port the phone takes connections on, from mDNS: the find it was
  /// picked from, or a fresh look by its name or address.
  Future<int?> _connectPortFor(String host, String? guid) async {
    if (_picked case final p? when p.host == host && p.connectPort != null) {
      return p.connectPort;
    }
    for (final p in await _phones()) {
      if (p.connectPort == null) continue;
      if ((guid != null && p.guid == guid) || p.host == host) {
        return p.connectPort;
      }
    }
    return null;
  }

  Future<void> _addPaired() async {
    final paired = _paired;
    final port = _port(_connectPort.text);
    if (paired == null) return;
    if (port == null) {
      setState(
        () => _error =
            'Type the port under Wireless debugging, IP address and port, '
            'the number after the colon.',
      );
      return;
    }
    await _add(host: paired.host, port: port, guid: paired.guid, paired: true);
  }

  Future<void> _addClassic() async {
    final host = _classicHost.text.trim();
    final port = _port(_classicPort.text);
    if (host.isEmpty || port == null) {
      setState(() => _error = 'Type the phone\'s address, and port 5555.');
      return;
    }
    await _add(host: host, port: port, paired: false);
  }

  Future<void> _add({
    required String host,
    required int port,
    required bool paired,
    String? guid,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final api = ref.read(engineApiProvider);
    final found = _picked?.name;
    final name = found != null && found != _picked?.guid
        ? found
        : 'Phone ${host.split('.').last}';
    final reply = await api.addCandidate(
      TvCalls.addPhoneArgs(host: host, port: port, guid: guid),
      name: name,
    );
    var added = reply.value;
    if (!mounted) return;
    if (added == null) {
      setState(() {
        _busy = false;
        _error = reply.failure?.message ?? 'The phone could not be added.';
      });
      return;
    }
    // A paired phone has already said yes to this engine's key.
    if (paired && added.id != null && added.next.kind == NextKind.pair) {
      final next = await api.nextStep(added.id!, paired: true);
      added = Added(id: added.id, next: next.value ?? added.next);
    }
    await ref.read(devicesProvider.notifier).refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    // Always on to the steps page, so the phone gets its name and room.
    await followAdded(
      navigator,
      added,
      name: name,
      replaceRoute: true,
      always: true,
    );
  }

  /// 1 the other phone, 2 pair (or the classic address), 3 the port it
  /// connects on, only when mDNS did not give it.
  int get _current => _step == 1 ? 1 : (_paired == null ? 2 : 3);

  void _go(int step) => setState(() {
    _step = step;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final wireless = _route == PhoneRoute.wireless;
    final current = _current;
    return StepFlow(
      key: const ValueKey('add-phone'),
      title: 'Another phone',
      close: false,
      count: wireless ? 3 : 2,
      current: current,
      heading: switch (current) {
        1 => wireless ? 'On the other phone' : 'Port 5555',
        2 => wireless ? 'Pair with the code' : 'Its address',
        _ => 'Paired',
      },
      banners: [
        if (current == 2 && _needsUpdate)
          const OmniBanner.warning(
            key: ValueKey('phone-needs-update'),
            'Pairing with a code needs an update of OmniFlow. For now, use '
            'Port 5555 if a computer can turn it on over USB.',
          ),
        if (_error case final error?)
          OmniBanner.error(error, key: const ValueKey('phone-error')),
      ],
      onBack: switch (current) {
        1 => null,
        2 => () => _go(1),
        _ => () => setState(() {
          _paired = null;
          _error = null;
        }),
      },
      primaryKey: switch (current) {
        1 => const ValueKey('phone-next'),
        2 when wireless => const ValueKey('phone-pair'),
        2 => const ValueKey('phone-classic-add'),
        _ => const ValueKey('phone-connect-add'),
      },
      primaryLabel: switch (current) {
        1 => 'Next',
        2 when wireless => _busy ? 'Pairing' : 'Pair',
        _ => 'Add the phone',
      },
      onPrimary: switch (current) {
        1 => () => _go(2),
        _ when _busy => null,
        2 when wireless => _pair,
        2 => _addClassic,
        _ => _addPaired,
      },
      children: (context) => switch (current) {
        1 => [
          OmniSegmented<PhoneRoute>(
            key: const ValueKey('phone-route'),
            segments: const [
              OmniSegment(PhoneRoute.wireless, 'Wireless debugging'),
              OmniSegment(PhoneRoute.classic, 'Port 5555'),
            ],
            selected: _route,
            onChanged: (r) => setState(() {
              _route = r;
              _error = null;
            }),
          ),
          const SizedBox(height: OmniSpace.lg),
          if (wireless) ..._wireless() else ..._classicWhy(),
        ],
        2 when wireless => _pairing(),
        2 => _classic(),
        _ => _connect(),
      },
    );
  }

  List<Widget> _wireless() => [
    for (final (i, step) in phoneSetupSteps.indexed)
      Padding(
        key: ValueKey('phone-step-$i'),
        padding: const EdgeInsets.only(bottom: OmniSpace.xs),
        child: Text('${i + 1}. $step', style: OmniText.body),
      ),
    const SizedBox(height: OmniSpace.sm),
    const Text(
      'Wireless debugging turns off when that phone restarts, so its owner '
      'turns it on again, and can turn it off there at any time.',
      style: OmniText.caption,
    ),
  ];

  List<Widget> _pairing() => [
    OmniSectionHeader(
      'Phones found',
      trailingText: _found == null ? null : '${_found!.length}',
    ),
    if (_looking)
      const OmniBanner.info(
        key: ValueKey('phone-looking'),
        'Looking for phones with Wireless debugging on…',
      )
    else if (_found case final found? when found.isNotEmpty)
      for (final (i, p) in found.indexed)
        OmniListRow(
          key: ValueKey('phone-found-$i'),
          icon: OmniIcons.phone,
          title: p.name,
          subtitle: [
            p.host,
            if (p.knownAs != null)
              'added already'
            else if (p.pairingPort == null)
              'open Pair device with pairing code on it'
            else
              'ready to pair',
          ].join(' · '),
          selected: _picked == p,
          trailing: _picked == p
              ? Icon(OmniIcons.check, color: OmniPalette.of(context).accent)
              : null,
          onTap: p.pairingPort == null ? null : () => _pick(p),
        )
    else
      OmniEmptyState(
        key: const ValueKey('phone-none'),
        icon: OmniIcons.phone,
        title: _findMissing
            ? 'This OmniFlow cannot look for phones yet'
            : 'No phone found',
        message: _findMissing
            ? 'Type the address and port below.'
            : 'Check both phones are on the same Wi-Fi, or type the address '
                  'and port below.',
        compact: true,
      ),
    OmniButton.ghost(
      key: const ValueKey('phone-look-again'),
      label: 'Look again',
      icon: OmniIcons.retry,
      onPressed: _looking ? null : _look,
    ),
    const OmniSectionHeader('From Pair device with pairing code'),
    TextField(
      key: const ValueKey('phone-host'),
      controller: _host,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'Address, such as 192.168.1.20',
      ),
    ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('phone-pair-port'),
      controller: _pairPort,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(
        labelText: 'Port, the number after the colon',
      ),
    ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('phone-code'),
      controller: _code,
      keyboardType: TextInputType.number,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      maxLength: 6,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(
        labelText: 'Six-digit pairing code',
        counterText: '',
      ),
      onSubmitted: (_) => _busy ? null : _pair(),
    ),
  ];

  List<Widget> _connect() => [
    const Text(
      'The phone said yes. Now type the port under Wireless debugging, IP '
      'address and port. It is not the pairing port.',
      style: OmniText.body,
    ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('phone-connect-port'),
      controller: _connectPort,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(labelText: 'Port'),
    ),
  ];

  List<Widget> _classicWhy() => [
    const Text(
      'For a phone a computer has set up: connect it by USB and run adb tcpip '
      '5555 once. The phone asks "Allow USB debugging?" the first time, and '
      'its owner chooses Allow. It turns off again when the phone restarts.',
      style: OmniText.body,
    ),
  ];

  List<Widget> _classic() => [
    TextField(
      key: const ValueKey('phone-classic-host'),
      controller: _classicHost,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'Address, such as 192.168.1.20',
      ),
    ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('phone-classic-port'),
      controller: _classicPort,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(labelText: 'Port'),
    ),
  ];
}
