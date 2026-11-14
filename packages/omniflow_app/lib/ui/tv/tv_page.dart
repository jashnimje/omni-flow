import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart' show DeviceView;
import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../add/pair_sheet.dart';
import '../design/design.dart';
import '../devices/device_sections.dart';
import 'phone_remote.dart';
import 'tv_apps.dart';
import 'tv_console.dart';
import 'tv_controller.dart';
import 'tv_files.dart';
import 'tv_remote.dart';
import 'tv_screen.dart';
import 'tv_system.dart';
import 'tv_settings.dart';
import 'tv_widgets.dart';

Future<void> openTv(BuildContext context, Json device) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvPage(
          id: '${device['id']}',
          name: '${device['name'] ?? device['id']}',
          phone: TvCalls.isPhone(device),
        ),
      ),
    );

/// The Android device page's tabs. A TV and a phone show different ones
/// as chips, and the rest under More.
enum TvTab {
  remote('Remote'),
  screen('Screen'),
  apps('Apps'),
  system('System'),
  files('Files'),
  settings('Settings'),
  console('Console');

  const TvTab(this.label);

  final String label;

  /// The three a TV is used for every day, as chips. The rest sit under
  /// More.
  static const main = [remote, screen, apps];

  /// A phone is looked at and touched rather than pointed at, so its chips
  /// are Screen, Apps and Files, and its keys sit under More, Remote.
  static const phoneMain = [screen, apps, files];

  /// What a phone shows under More, in order.
  static const phoneMore = [system, settings, remote, console];

  bool get isMain => main.contains(this);

  bool isMainFor({required bool phone}) =>
      phone ? phoneMain.contains(this) : isMain;

  static List<TvTab> mainFor({required bool phone}) => phone ? phoneMain : main;

  static List<TvTab> moreFor({required bool phone}) => phone
      ? phoneMore
      : [
          for (final t in values)
            if (!t.isMain) t,
        ];
}

/// The Android device page, picked by driver. For a TV (4.1 to 4.5) the
/// live header on every tab, then Remote, Screen and Apps as tabs, with
/// System, Files, Settings and Console under More. For another phone
/// Screen, Apps and Files, with System, Settings, Remote and Console under
/// More. A tab is built the first time it is opened and kept after, so its
/// list and scroll survive a switch.
class TvPage extends ConsumerStatefulWidget {
  const TvPage({
    super.key,
    required this.id,
    required this.name,
    this.phone = false,
    this.openOn,
  });

  final String id;
  final String name;

  /// Another Android phone rather than a TV.
  final bool phone;

  /// The tab to open on, when not the usual one.
  final TvTab? openOn;

  /// The tab it opens on: Remote on a TV, Screen on a phone.
  TvTab get tab => openOn ?? (phone ? TvTab.screen : TvTab.remote);

  @override
  ConsumerState<TvPage> createState() => _TvPageState();
}

class _TvPageState extends ConsumerState<TvPage> {
  late final TvController tv = TvController(
    client: ref.read(engineClientProvider),
    id: widget.id,
    poll: ref.read(tvPollProvider),
    isPhone: widget.phone,
  )..start();

  bool get _phone => widget.phone;

  late var _tab = widget.tab;
  late final _opened = {widget.tab};

  @override
  void dispose() {
    tv.dispose();
    super.dispose();
  }

  void _open(TvTab tab) => setState(() {
    _tab = tab;
    _opened.add(tab);
  });

  /// The tabs that are not chips, as a sheet to pick one from.
  Future<void> _more() async {
    final picked = await showOmniSheet<TvTab>(
      context,
      builder: (sheet) => OmniSheet(
        title: 'More',
        children: [
          for (final t in TvTab.moreFor(phone: _phone))
            OmniListRow(
              key: ValueKey('tv-more-${t.name}'),
              icon: switch (t) {
                TvTab.system => OmniIcons.system,
                TvTab.files => OmniIcons.storage,
                TvTab.settings => OmniIcons.settings,
                TvTab.remote => OmniIcons.phone,
                _ => OmniIcons.terminal,
              },
              title: t.label,
              subtitle: switch (t) {
                TvTab.system => 'how it is doing, what runs on it, restart',
                TvTab.files =>
                  'the files on the ${tv.noun}, to and from this phone',
                TvTab.settings => 'change settings on the ${tv.noun}',
                TvTab.remote =>
                  'Back, Home, Recents, volume, notifications and lock',
                _ => 'run commands on the ${tv.noun}, for experts',
              },
              trailing: _tab == t
                  ? const Icon(OmniIcons.check, color: OmniColors.accent)
                  : null,
              chevron: _tab != t,
              onTap: () => Navigator.of(sheet).pop(t),
            ),
        ],
      ),
    );
    if (picked != null && mounted) _open(picked);
  }

  Widget _body(TvTab tab) => switch (tab) {
    TvTab.remote when _phone => PhoneRemoteTab(tv: tv),
    TvTab.remote => TvRemoteTab(tv: tv, active: _tab == TvTab.remote),
    TvTab.screen => TvScreenTab(tv: tv, active: _tab == TvTab.screen),
    TvTab.apps => TvAppsTab(tv: tv),
    TvTab.system => TvSystemTab(tv: tv, active: _tab == TvTab.system),
    TvTab.settings => TvSettingsTab(tv: tv),
    TvTab.files => TvFilesTab(tv: tv),
    TvTab.console => TvConsoleTab(tv: tv),
  };

  Json? get _device => ref
      .watch(devicesProvider)
      .value
      ?.where((d) => d['id'] == widget.id)
      .firstOrNull;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tv,
    builder: (context, _) {
      final on = tv.state.isOn;
      return OmniPage(
        title: widget.name,
        padded: false,
        actions: [
          OmniIconAction(
            key: const ValueKey('tv-header-power'),
            icon: OmniIcons.power,
            label: _phone
                ? (on ? 'Lock the phone' : 'Wake the phone')
                : (on ? 'Put the TV to sleep' : 'Wake the TV'),
            color: on ? OmniColors.accent : OmniColors.muted,
            onPressed: () => tv.key(on ? Keycodes.sleep : Keycodes.wakeup),
          ),
          if (_device case final device?)
            OmniIconAction(
              key: const ValueKey('tv-header-device'),
              icon: OmniIcons.more,
              label: 'Room, name and settings',
              onPressed: () => showOmniSheet<void>(
                context,
                builder: (_) => OmniSheet(
                  title: widget.name,
                  children: [
                    UsedInSection(device: DeviceView(device)),
                    DeviceSection(device: DeviceView(device)),
                  ],
                ),
              ),
            ),
        ],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: OmniSpace.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (tv.offline case final reason?)
                    OmniBanner.error(
                      key: const ValueKey('tv-offline'),
                      tv.needsPairing
                          ? reason
                          : _phone
                          ? '$reason Wireless debugging turns off when the '
                                'phone restarts or changes Wi-Fi, so turn it '
                                'on again on that phone.'
                          : '$reason It may be asleep, switched off at the '
                                'wall, or on another Wi-Fi.',
                      actionLabel: 'Retry',
                      onAction: tv.refresh,
                    ),
                  if (_device case final device?
                      when tv.offline != null &&
                          pairsInApp(device) &&
                          !TvCalls.pairsWithCode(device))
                    Padding(
                      padding: const EdgeInsets.only(bottom: OmniSpace.sm),
                      child: OmniButton.ghost(
                        key: const ValueKey('tv-pair'),
                        label: 'Pair again',
                        icon: OmniIcons.retry,
                        onPressed: () => showPairDevice(context, device),
                      ),
                    ),
                  TvHeader(tv: tv),
                  SingleChildScrollView(
                    key: const ValueKey('tv-tabs'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in TvTab.mainFor(phone: _phone)) ...[
                          OmniFilterChip(
                            key: ValueKey('tv-tab-${t.name}'),
                            label: t.label,
                            selected: _tab == t,
                            onTap: () => _open(t),
                          ),
                          const SizedBox(width: 6),
                        ],
                        // Names the tab it is showing, so it is clear
                        // where you are.
                        OmniFilterChip(
                          key: const ValueKey('tv-tab-more'),
                          label: _tab.isMainFor(phone: _phone)
                              ? 'More'
                              : 'More: ${_tab.label}',
                          icon: OmniIcons.more,
                          selected: !_tab.isMainFor(phone: _phone),
                          onTap: _more,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: [
                  for (final t in TvTab.values)
                    _opened.contains(t) ? _body(t) : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// The app in front with its playing state, the volume and mute, read
/// every few seconds and on every state event.
class TvHeader extends StatelessWidget {
  const TvHeader({super.key, required this.tv});

  final TvController tv;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tv,
    builder: (context, _) {
      final s = tv.state;
      final max = s.volumeMax <= 0 ? 100 : s.volumeMax;
      final app = s.app;
      final name = tv.appName;
      final playing = playingLabel(s.playing);
      return OmniCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
        child: Row(
          children: [
            if (app != null && name != null && s.isOn)
              AppBadge(package: app, name: name, size: 40)
            else
              OmniIconBox(
                icon: tv.isPhone ? OmniIcons.phone : OmniIcons.tv,
                size: 40,
              ),
            const SizedBox(width: OmniSpace.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.isOn)
                    Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: Text(
                              name ?? 'No app in front',
                              key: const ValueKey('tv-app'),
                              style: OmniText.bodyStrong,
                            ),
                          ),
                          if (playing.isNotEmpty)
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: Text(
                                ' · ${playing.toLowerCase()}',
                                key: const ValueKey('tv-playing'),
                                style: OmniText.body,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Text(
                      powerLabel(s.power, loaded: tv.loaded, phone: tv.isPhone),
                      key: const ValueKey('tv-power-state'),
                      style: OmniText.bodyStrong,
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: OmniLabelledSlider(
                          key: const ValueKey('tv-volume'),
                          label: 'Volume',
                          height: 28,
                          min: 0,
                          max: max.toDouble(),
                          step: 1,
                          value: (s.volume ?? 0).clamp(0, max).toDouble(),
                          format: (v) =>
                              s.volume == null ? '-' : '${v.round()}',
                          onChangeEnd: (v) {
                            if (v.round() != s.volume) {
                              tv.setVolume(v.round());
                            }
                          },
                        ),
                      ),
                      OmniIconAction(
                        key: const ValueKey('tv-mute'),
                        icon: s.muted == true
                            ? TvIcons.volumeOff
                            : TvIcons.volumeUp,
                        label: s.muted == true ? 'Unmute' : 'Mute',
                        onPressed: () => tv.key(Keycodes.mute),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

String powerLabel(String? power, {bool loaded = true, bool phone = false}) =>
    switch (power) {
      'on' when phone => 'Screen on',
      'asleep' when phone => 'Screen off',
      'on' => 'On',
      'asleep' => 'Asleep',
      'off' => 'Off',
      _ when phone => loaded ? 'Not answering' : 'Reading the phone...',
      _ => loaded ? 'Power unknown' : 'Reading the TV...',
    };

String playingLabel(String? playing) => switch (playing) {
  'playing' => 'Playing',
  'paused' => 'Paused',
  'stopped' => 'Stopped',
  _ => '',
};

/// Android key codes the app itself uses outside the remote layout.
abstract final class Keycodes {
  static const home = 3;
  static const back = 4;
  static const power = 26;
  static const sleep = 223;
  static const wakeup = 224;
  static const mute = 164;
}

/// Whether [device] gets the TV card and control centre.
bool isTvDevice(Json device) => TvCalls.isTv(device);
