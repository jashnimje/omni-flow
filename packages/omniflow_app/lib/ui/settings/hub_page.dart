import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_client_hub.dart';
import '../../api/plain_error.dart' show asSentence;
import '../../service/hub_connection.dart';
import '../../service/hub_engine_client.dart' show versionMismatchText;
import '../../service/hub_key.dart';
import '../../state/hub_mode.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'settings_screen.dart' show engineStatusProvider;

/// The Settings row for where the home runs.
class HomeRunsOnRow extends ConsumerWidget {
  const HomeRunsOnRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(homeModeProvider).value;
    final settings = ref.watch(hubSettingsProvider).value;
    final link = ref.watch(hubLinkProvider);
    final hub = mode == HomeMode.hub;
    final hubError = ref.watch(hubErrorProvider);
    final stopped =
        !hub &&
        (hubError != null ||
            ref.watch(engineStatusProvider).value?['hubRunning'] == false);
    return OmniListRow(
      key: const ValueKey('settings-home-runs-on'),
      icon: OmniIcons.server,
      title: 'Home runs on',
      subtitle: switch (mode) {
        null => 'Checking',
        HomeMode.phone when hubError != null =>
          'This phone · the hub did not start',
        HomeMode.phone when stopped => 'This phone · the hub is stopped',
        HomeMode.phone => 'This phone',
        HomeMode.hub when link != null && !link.connected =>
          'Mac mini hub · not reachable',
        HomeMode.hub => 'Mac mini hub · ${settings?.host ?? ''}',
      },
      dot: stopped || (hub && link != null && !link.connected)
          ? StatusKind.warning
          : null,
      chevron: true,
      onTap: () =>
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const HubPage())),
    );
  }
}

/// Settings, Home runs on: the one place for what runs the home. On this
/// phone, whether its hub runs, with Start and Stop, and the way to move
/// the home to a Mac mini. On a Mac mini, how the link stands, or move the
/// home back to this phone.
class HubPage extends ConsumerWidget {
  const HubPage({super.key});

  static const title = 'Home runs on';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(homeModeProvider);
    return switch (mode.value) {
      null => DetailPage(
        title: HubPage.title,
        state: OmniLoad.of(
          mode,
          onRetry: () => ref.invalidate(homeModeProvider),
        ),
        children: (_) => const [],
      ),
      HomeMode.phone => const _PhoneHub(),
      HomeMode.hub => const _HubStatus(),
    };
  }
}

/// The steps that move the home to a Mac mini hub, a task opened from
/// Home runs on or from an empty home, left with the cross.
class HubSetupPage extends StatelessWidget {
  const HubSetupPage({super.key});

  static const title = 'Connect to a hub';

  @override
  Widget build(BuildContext context) => const _HubSetup();
}

/// This phone runs the home: its hub, which runs each automation when its
/// trigger happens, can be stopped and started again.
class _PhoneHub extends ConsumerWidget {
  const _PhoneHub();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider).value;
    final hubError = ref.watch(hubErrorProvider);
    final running = status?['hubRunning'] == true;
    final loaded = (status?['flows'] as List?)?.length;
    final api = ref.read(engineApiProvider);
    return DetailPage(
      key: const ValueKey('hub-phone'),
      title: HubPage.title,
      banners: [
        if (hubError != null)
          OmniBanner.error(
            'The hub did not start, so automations only run when you run '
            'them. Try starting it again below.',
            key: const ValueKey('hubs-error'),
          ),
      ],
      hero: OmniHeroCard(
        key: const ValueKey('hub-hero'),
        title: status == null
            ? 'Checking the hub'
            : running
            ? 'This phone runs the hub'
            : 'The hub is stopped',
        subtitle: loaded == null
            ? null
            : '$loaded automation${loaded == 1 ? '' : 's'} loaded',
        tone: running ? HeroTone.accent : HeroTone.plain,
      ),
      children: (context) => [
        const Text(
          'The hub listens for your devices, keeps time and runs each '
          'automation when its trigger happens, with the screen off too.',
          style: OmniText.caption,
        ),
        const SizedBox(height: OmniSpace.lg),
        if (status != null && !running)
          OmniButton(
            key: const ValueKey('hub-start'),
            label: 'Start the hub',
            onPressed: () async {
              if ((await api.startHub()).ok) {
                ref.invalidate(engineStatusProvider);
              }
            },
          ),
        if (running)
          OmniButton.danger(
            key: const ValueKey('hub-stop'),
            label: 'Stop the hub',
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Stop the hub?',
                body:
                    'Automations stop running on their own until you start '
                    'it again. You can still run them by hand.',
                action: 'Stop',
                destructive: true,
              );
              if (!ok) return;
              if ((await api.stopHub()).ok) {
                ref.invalidate(engineStatusProvider);
              }
            },
          ),
        const OmniSectionHeader('A Mac mini instead'),
        OmniListRow(
          key: const ValueKey('hub-connect'),
          icon: OmniIcons.computer,
          title: 'Connect to a hub',
          subtitle:
              'A Mac mini runs the home for every phone, with this one as '
              'its screen and sensors',
          subtitleLines: 2,
          chevron: true,
          divider: false,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => const HubSetupPage(),
            ),
          ),
        ),
      ],
    );
  }
}

class _HubStatus extends ConsumerWidget {
  const _HubStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(hubLinkProvider);
    final settings = ref.watch(hubSettingsProvider).value;
    final clients = ref.watch(hubClientsProvider);
    final connected = link?.connected == true;
    final since = link?.connectedSince?.toLocal();
    return DetailPage(
      key: const ValueKey('hub-status'),
      title: HubPage.title,
      hero: OmniHeroCard(
        key: const ValueKey('hub-status-hero'),
        title: switch (link?.state) {
          HubLinkState.connected => 'Connected to the Mac mini hub',
          HubLinkState.versionMismatch => 'The hub and app versions differ',
          HubLinkState.unreachable => 'Hub not reachable',
          _ => 'Connecting to the hub',
        },
        subtitle: link?.reason,
        tone: connected ? HeroTone.accent : HeroTone.problem,
      ),
      children: (context) => [
        const OmniSectionHeader('Hub'),
        OmniListRow(
          key: const ValueKey('hub-address'),
          icon: OmniIcons.computer,
          title: 'Address',
          value: link?.address ?? settings?.address ?? '',
        ),
        OmniListRow(
          key: const ValueKey('hub-since'),
          icon: OmniIcons.time,
          title: 'Connected since',
          value: since == null || !connected ? 'Not connected' : _time(since),
        ),
        OmniListRow(
          key: const ValueKey('hub-version'),
          icon: OmniIcons.about,
          title: 'Hub version',
          value: link?.hubVersion ?? 'Not known yet',
          subtitle: link?.appVersion == null
              ? null
              : 'This app is ${link!.appVersion}',
        ),
        OmniListRow(
          key: const ValueKey('hub-this-phone'),
          icon: OmniIcons.phone,
          title: 'This phone',
          value: link?.phone ?? settings?.phone ?? '',
          subtitle: link?.person == null
              ? 'No person on the hub yet'
              : 'Asks for ${link!.person} show here',
          divider: false,
        ),
        const OmniSectionHeader('Phones connected'),
        ...switch (clients) {
          AsyncData(value: final list?) when list.isNotEmpty => [
            for (final (i, c) in list.indexed)
              OmniListRow(
                key: ValueKey('hub-client-$i'),
                icon: OmniIcons.phone,
                title: '${c['phone'] ?? c['name'] ?? c['client'] ?? 'Phone'}',
                subtitle: _clientLine(c),
                divider: i < list.length - 1,
              ),
          ],
          AsyncData(value: final list?) when list.isEmpty => [
            const OmniEmptyState(
              icon: OmniIcons.phone,
              title: 'No phone is connected',
              compact: true,
            ),
          ],
          AsyncLoading() => [
            const OmniListSkeleton(rows: 1, label: 'Asking the hub'),
          ],
          _ => [
            OmniEmptyState(
              key: const ValueKey('hub-clients-none'),
              icon: OmniIcons.phone,
              title: connected
                  ? 'This hub does not list its phones'
                  : 'Shown once the hub is reachable',
              compact: true,
            ),
          ],
        },
        const SizedBox(height: OmniSpace.xl),
        OmniButton(
          key: const ValueKey('hub-reconnect'),
          label: 'Reconnect',
          icon: OmniIcons.retry,
          onPressed: () async {
            await ref.read(hubLinkProvider.notifier).reconnect();
            ref.invalidate(hubClientsProvider);
          },
        ),
        const SizedBox(height: OmniSpace.md),
        OmniButton.ghost(
          key: const ValueKey('hub-switch-phone'),
          label: 'Switch back to This phone',
          icon: OmniIcons.phone,
          onPressed: () => _switchBack(context, ref, connected),
        ),
      ],
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _time(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';

  static String? _clientLine(Json c) {
    final parts = [
      if (c['person'] case final String person) person,
      if (c['connectedAt'] ?? c['since'] case final String since)
        if (DateTime.tryParse(since) case final at?)
          'since ${_time(at.toLocal())}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Future<void> _switchBack(
    BuildContext context,
    WidgetRef ref,
    bool connected,
  ) async {
    final ok = await confirm(
      context,
      title: 'Run the home on this phone?',
      body: connected
          ? 'This phone stops using the hub and runs its own home again, '
                'starting from a copy of the hub\'s home. Keys and pairings '
                'stay on the Mac mini, so devices that need them ask again. '
                'The hub keeps running for other phones.'
          : 'The hub is not reachable, so this phone goes back to the home '
                'it had before it used the hub. Changes made on the hub '
                'since then are not on it.',
      action: 'Switch',
    );
    if (!ok) return;
    final brought = await switchToPhone(ref);
    showMessage(
      brought
          ? 'Switching to this phone with the hub\'s home'
          : 'Switching to this phone',
    );
  }
}

/// The steps: find the hub, let this phone in, check the hub's key.
class _HubSetup extends ConsumerStatefulWidget {
  const _HubSetup();

  @override
  ConsumerState<_HubSetup> createState() => _HubSetupState();
}

class _HubSetupState extends ConsumerState<_HubSetup> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _phone = TextEditingController(text: 'phone');

  List<Json>? _found;
  var _looking = false;
  var _lookedWithoutLuck = false;
  HubKey? _key;
  String? _offered;
  var _busy = false;
  String? _problem;
  var _step = 1;

  @override
  void initState() {
    super.initState();
    for (final c in [_host, _port, _user, _phone]) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {
    _offered = null;
    _problem = null;
  });

  HubSettings? get _settings {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final phone = hubPhoneName(_phone.text);
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || user.isEmpty || phone.isEmpty) return null;
    if (port == null || port < 1 || port > 65535) return null;
    return HubSettings(host: host, port: port, user: user, phone: phone);
  }

  Future<void> _look() async {
    setState(() => _looking = true);
    final found = await HubCalls(ref.read(engineClientProvider)).discover();
    if (!mounted) return;
    setState(() {
      _looking = false;
      _found = found ?? const [];
      _lookedWithoutLuck = found == null || found.isEmpty;
    });
  }

  void _pick(Json hub) {
    _host.text = '${hub['host'] ?? hub['address'] ?? ''}';
    final port = hub['port'];
    if (port is int) _port.text = '$port';
  }

  Future<void> _makeKey() async {
    final phone = hubPhoneName(_phone.text);
    if (phone.isEmpty) return;
    final key = await ref.read(hubSettingsStoreProvider).phoneKey(phone);
    if (mounted) setState(() => _key = key);
  }

  Future<void> _check() async {
    final settings = _settings;
    if (settings == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final offered = await ref
          .read(hubSetupToolsProvider)
          .probeHostKey(settings.host, settings.port);
      if (mounted) setState(() => _offered = offered);
    } on Object {
      if (mounted) {
        setState(
          () => _problem =
              'Nothing answered at ${settings.host}:${settings.port}. Check '
              'the address, and that Remote Login is on for the Mac mini.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _matched() async {
    final settings = _settings;
    final offered = _offered;
    if (settings == null || offered == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final saved = settings.withHostKey(offered);
    try {
      await ref.read(hubSetupToolsProvider).tryConnect(saved);
    } on HubConnectException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = switch (e.type) {
            'version_mismatch' => versionMismatchText(
              e.hubVersion,
              e.appVersion ?? '',
            ),
            'not_allowed' =>
              'The Mac mini did not let this phone in. Go back, run the '
                  'allow line on it, then check again.',
            'host_key' =>
              'The Mac mini offered a different host key just now. Check '
                  'the fingerprint again.',
            _ =>
              'The hub did not answer: ${asSentence(e.message)} Check the '
                  'address and try again.',
          };
        });
      }
      return;
    }
    await switchToHub(ref, settings, hostKey: offered);
    showMessage('Switching to the Mac mini hub');
    if (!mounted) return;
    setState(() => _busy = false);
    await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final key = _key;
    final offered = _offered;
    final fingerprint = offered?.split(' ').last;
    final phone = hubPhoneName(_phone.text);
    void go(int step) => setState(() {
      _step = step;
      _problem = null;
    });
    return Owning(
      [_host, _port, _user, _phone],
      child: StepFlow(
        key: const ValueKey('hub-setup'),
        title: HubSetupPage.title,
        close: true,
        count: 3,
        current: _step,
        heading: switch (_step) {
          1 => 'Find the hub',
          2 => 'Let this phone in',
          _ => 'Check it is your Mac mini',
        },
        why: switch (_step) {
          1 =>
            'The phone and the Mac mini need to be on the same Wi-Fi, or '
                'on Tailscale.',
          2 => 'The Mac mini lets in only the phones you allow.',
          _ => 'So this phone talks to your Mac mini and nothing else.',
        },
        banners: [
          if (_problem case final problem?)
            OmniBanner.error(problem, key: const ValueKey('hub-problem')),
        ],
        onBack: _step == 1 ? null : () => go(_step - 1),
        primaryKey: switch (_step) {
          2 when key == null => const ValueKey('hub-make-key'),
          3 when offered == null => const ValueKey('hub-check'),
          3 => const ValueKey('hub-matches'),
          _ => null,
        },
        primaryLabel: switch (_step) {
          2 when key == null => 'Make this phone\'s key',
          3 when offered == null => _busy ? 'Connecting' : 'Connect',
          3 => _busy ? 'Connecting' : 'It matches',
          _ => 'Next',
        },
        onPrimary: switch (_step) {
          1 => settings == null ? null : () => go(2),
          2 when key == null => phone.isEmpty ? null : _makeKey,
          2 => () => go(3),
          3 when offered == null =>
            settings == null || key == null || _busy ? null : _check,
          _ => _busy ? null : _matched,
        },
        missing: switch (_step) {
          1 =>
            'Type the Mac mini address, your user name and a name for this '
                'phone.',
          2 => 'Give this phone a name first.',
          _ => null,
        },
        children: (context) => switch (_step) {
          1 => _findStep(),
          2 => _allowStep(key),
          _ => _checkStep(offered, fingerprint),
        },
      ),
    );
  }

  List<Widget> _findStep() => [
    const OmniHeroCard(
      title: 'This phone runs the home',
      subtitle:
          'Or a Mac mini can run it for every phone in the house, with '
          'this phone as its screen and its sensors.',
      tone: HeroTone.plain,
    ),
    const SizedBox(height: OmniSpace.md),
    OmniButton.ghost(
      key: const ValueKey('hub-look'),
      label: _looking ? 'Looking' : 'Look on this Wi-Fi',
      icon: OmniIcons.search,
      onPressed: _looking ? null : _look,
    ),
    if (_found case final found? when found.isNotEmpty)
      for (final (i, hub) in found.indexed)
        OmniListRow(
          key: ValueKey('hub-found-$i'),
          icon: OmniIcons.computer,
          title: '${hub['name'] ?? hub['host']}',
          subtitle: '${hub['host']}:${hub['port'] ?? 22}',
          onTap: () => _pick(hub),
        ),
    if (_lookedWithoutLuck)
      const OmniEmptyState(
        key: ValueKey('hub-none-found'),
        icon: OmniIcons.computer,
        title: 'No Mac was found',
        message:
            'Type its address below. It is in System Settings, General, '
            'Sharing, Remote Login.',
        compact: true,
      ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('hub-host'),
      controller: _host,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Mac mini address',
        helperText: 'Like mac-mini.local, an IP, or its Tailscale name',
      ),
    ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('hub-port'),
      controller: _port,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'SSH port'),
    ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('hub-user'),
      controller: _user,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Your user name on the Mac mini',
      ),
    ),
    const SizedBox(height: OmniSpace.md),
    TextField(
      key: const ValueKey('hub-phone'),
      controller: _phone,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'A name for this phone',
        helperText:
            'Starts with a letter, then letters, digits or _, like '
            'jade_pixel',
      ),
    ),
  ];

  List<Widget> _allowStep(HubKey? key) => [
    if (key == null)
      const Text(
        'OmniFlow makes a key for this phone. Only its public half leaves '
        'the phone.',
        style: OmniText.body,
      )
    else ...[
      const Text(
        'Run this on the Mac mini, in Terminal:',
        style: OmniText.caption,
      ),
      const SizedBox(height: OmniSpace.sm),
      SelectableText(
        hubAllowLine(hubPhoneName(_phone.text), key),
        key: const ValueKey('hub-allow-line'),
        style: OmniText.mono,
      ),
      const SizedBox(height: OmniSpace.sm),
      OmniButton.ghost(
        key: const ValueKey('hub-copy'),
        label: 'Copy',
        icon: Icons.copy_rounded,
        expand: false,
        onPressed: () async {
          await Clipboard.setData(
            ClipboardData(text: hubAllowLine(hubPhoneName(_phone.text), key)),
          );
          showMessage('Copied');
        },
      ),
    ],
  ];

  List<Widget> _checkStep(String? offered, String? fingerprint) => [
    if (offered == null)
      const Text(
        'Connect asks the Mac mini for its key, so you can check it first.',
        style: OmniText.body,
      )
    else ...[
      const Text('The Mac mini says its key is:', style: OmniText.caption),
      const SizedBox(height: OmniSpace.sm),
      SelectableText(
        fingerprint ?? offered,
        key: const ValueKey('hub-fingerprint'),
        style: OmniText.mono,
      ),
      const SizedBox(height: OmniSpace.sm),
      const Text(
        'Run omni hub fingerprint on the Mac mini. Does it show the same?',
        style: OmniText.body,
      ),
      const SizedBox(height: OmniSpace.md),
      OmniButton.ghost(
        key: const ValueKey('hub-no-match'),
        label: 'It does not match',
        onPressed: _busy
            ? null
            : () => setState(() {
                _offered = null;
                _problem =
                    'Something else answered at that address. Do not '
                    'connect. Check the address is the Mac mini.';
              }),
      ),
    ],
  ];
}
