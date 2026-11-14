import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_client_hub.dart';
import '../../service/hub_connection.dart';
import '../../service/hub_engine_client.dart' show versionMismatchText;
import '../../service/hub_key.dart';
import '../../state/hub_mode.dart';
import '../../state/providers.dart';
import '../design/design.dart';

/// The Settings row for where the home runs.
class HomeRunsOnRow extends ConsumerWidget {
  const HomeRunsOnRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(homeModeProvider).value;
    final settings = ref.watch(hubSettingsProvider).value;
    final link = ref.watch(hubLinkProvider);
    final hub = mode == HomeMode.hub;
    return OmniListRow(
      key: const ValueKey('settings-home-runs-on'),
      icon: OmniIcons.server,
      title: 'Home runs on',
      subtitle: switch (mode) {
        null => 'Checking',
        HomeMode.phone => 'This phone',
        HomeMode.hub when link != null && !link.connected =>
          'Mac mini hub · not reachable',
        HomeMode.hub => 'Mac mini hub · ${settings?.host ?? ''}',
      },
      dot: hub && link != null && !link.connected ? StatusKind.warning : null,
      chevron: true,
      onTap: () =>
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const HubPage())),
    );
  }
}

/// Settings, Home runs on: set this phone up as a client of the Mac mini
/// hub, see how the link stands, or move the home back to this phone.
class HubPage extends ConsumerWidget {
  const HubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(homeModeProvider);
    return OmniPage(
      title: 'Home runs on',
      body: switch (mode.value) {
        null => const Center(child: CircularProgressIndicator()),
        HomeMode.phone => const _HubSetup(),
        HomeMode.hub => const _HubStatus(),
      },
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
    return ListView(
      key: const ValueKey('hub-status'),
      children: [
        OmniHeroCard(
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
            const Text('No phone is connected.', style: OmniText.caption),
          ],
          AsyncLoading() => [
            const Text('Asking the hub', style: OmniText.caption),
          ],
          _ => [
            Text(
              connected
                  ? 'This hub does not list its phones.'
                  : 'Shown once the hub is reachable.',
              key: const ValueKey('hub-clients-none'),
              style: OmniText.caption,
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
    final store = ref.read(hubSettingsStoreProvider);
    final saved = settings.withHostKey(offered);
    await store.pinHostKey(saved, offered);
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
              'The Mac mini did not let this phone in. Run the line above '
                  'on it, then check again.',
            _ =>
              'The hub did not answer: ${e.message}. Check the address and '
                  'try again.',
          };
        });
      }
      return;
    }
    await switchToHub(ref, settings, hostKey: offered);
    if (mounted) setState(() => _busy = false);
    showMessage('Switching to the Mac mini hub');
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final key = _key;
    final offered = _offered;
    final fingerprint = offered?.split(' ').last;
    return Owning(
      [_host, _port, _user, _phone],
      child: ListView(
        key: const ValueKey('hub-setup'),
        children: [
          const OmniHeroCard(
            title: 'This phone runs the home',
            subtitle:
                'Or a Mac mini can run it for every phone in the house, with '
                'this phone as its screen and its sensors.',
            tone: HeroTone.plain,
          ),
          const OmniSectionHeader('1. Find the hub'),
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
            const Text(
              'No Mac was found. Type its address below. It is in System '
              'Settings, General, Sharing, Remote Login.',
              key: ValueKey('hub-none-found'),
              style: OmniText.caption,
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
          TextField(
            key: const ValueKey('hub-port'),
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'SSH port'),
          ),
          TextField(
            key: const ValueKey('hub-user'),
            controller: _user,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Your user name on the Mac mini',
            ),
          ),
          TextField(
            key: const ValueKey('hub-phone'),
            controller: _phone,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'A name for this phone',
              helperText: 'Starts with a letter, then letters, digits or _, like jade_pixel',
            ),
          ),
          const OmniSectionHeader('2. Let this phone in'),
          if (key == null)
            OmniButton.ghost(
              key: const ValueKey('hub-make-key'),
              label: 'Make this phone\'s key',
              icon: OmniIcons.permissions,
              onPressed: hubPhoneName(_phone.text).isEmpty ? null : _makeKey,
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
                  ClipboardData(
                    text: hubAllowLine(hubPhoneName(_phone.text), key),
                  ),
                );
                showMessage('Copied');
              },
            ),
          ],
          const OmniSectionHeader('3. Check it is your Mac mini'),
          if (offered == null)
            OmniButton(
              key: const ValueKey('hub-check'),
              label: _busy ? 'Connecting' : 'Connect',
              onPressed: settings == null || key == null || _busy
                  ? null
                  : _check,
            )
          else ...[
            const Text(
              'The Mac mini says its key is:',
              style: OmniText.caption,
            ),
            const SizedBox(height: OmniSpace.sm),
            SelectableText(
              fingerprint ?? offered,
              key: const ValueKey('hub-fingerprint'),
              style: OmniText.mono,
            ),
            const SizedBox(height: OmniSpace.sm),
            const Text(
              'Run omni hub fingerprint on the Mac mini. Does it show the '
              'same?',
              style: OmniText.body,
            ),
            const SizedBox(height: OmniSpace.md),
            OmniButton(
              key: const ValueKey('hub-matches'),
              label: _busy ? 'Connecting' : 'It matches',
              icon: OmniIcons.check,
              onPressed: _busy ? null : _matched,
            ),
            const SizedBox(height: OmniSpace.sm),
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
          if (_problem case final problem?) ...[
            const SizedBox(height: OmniSpace.md),
            OmniBanner.error(problem, key: const ValueKey('hub-problem')),
          ],
        ],
      ),
    );
  }
}
