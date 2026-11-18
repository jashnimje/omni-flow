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

/// The Android device page's views. The ones used every day switch under
/// one segmented control; the rest are tools that open as their own page.
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

  /// The three a TV is used for every day, in the switch. The rest are TV
  /// tools, in a section under the remote.
  static const main = [remote, apps, screen];

  /// A phone is looked at and touched rather than pointed at, so its switch
  /// is Screen, Apps and Files, and its keys are a tool, Remote.
  static const phoneMain = [screen, apps, files];

  /// A phone's tools, in order.
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
/// live header, then Remote, Apps and Screen under one switch. Under the
/// remote, collapsed: More buttons, TV tools (System, Files, TV settings,
/// Console, each its own page), Automations, Activity and More settings.
/// For another phone Screen, Apps and Files, with System, Settings, Remote
/// and Console as tools from the header. A view is built the first time it
/// is opened and kept after, so its list and scroll survive a switch.
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

  @override
  void initState() {
    super.initState();
    // A tool is a page of its own, so opening on one opens it over the
    // remote.
    if (!widget.tab.isMainFor(phone: _phone)) {
      _tab = TvTab.mainFor(phone: _phone).first;
      _opened
        ..clear()
        ..add(_tab);
      final tool = widget.tab;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openTool(tool);
      });
    }
  }

  /// What each tool is for, in a line.
  String _toolLine(TvTab t) => switch (t) {
    TvTab.system => 'How it is doing, what runs on it, restart',
    TvTab.files => 'Files to and from this phone',
    TvTab.settings => 'Change settings on the ${tv.noun}',
    TvTab.remote => 'Back, Home, Recents, volume, notifications and lock',
    _ => 'Commands on the ${tv.noun}, for experts',
  };

  static IconData _toolIcon(TvTab t) => switch (t) {
    TvTab.system => OmniIcons.system,
    TvTab.files => OmniIcons.storage,
    TvTab.settings => OmniIcons.settings,
    TvTab.remote => OmniIcons.phone,
    _ => OmniIcons.terminal,
  };

  String _toolTitle(TvTab t) =>
      t == TvTab.settings && !_phone ? 'TV settings' : t.label;

  /// Opens [tool] as its own page over this one, with the same live
  /// header and power key.
  void _openTool(TvTab tool) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ListenableBuilder(
        listenable: tv,
        builder: (context, _) => DetailPage.custom(
          key: ValueKey('tv-tool-${tool.name}'),
          title: _toolTitle(tool),
          actions: [_powerAction(context)],
          hero: TvHeader(tv: tv),
          body: (_) => _body(tool, active: true),
        ),
      ),
    ),
  );

  /// Sleep and wake, in the header of the page and of every tool.
  Widget _powerAction(BuildContext context) {
    final on = tv.state.isOn;
    final palette = OmniPalette.of(context);
    return OmniIconAction(
      key: const ValueKey('tv-header-power'),
      icon: OmniIcons.power,
      label: _phone
          ? (on ? 'Lock the phone' : 'Wake the phone')
          : (on ? 'Put the TV to sleep' : 'Wake the TV'),
      color: on ? palette.accent : palette.muted,
      onPressed: () => tv.key(on ? Keycodes.sleep : Keycodes.wakeup),
    );
  }

  /// A phone's tools, as a sheet to pick one from.
  Future<void> _phoneTools() async {
    final picked = await showPickerSheet<TvTab>(
      context,
      title: 'Phone tools',
      sections: [
        PickerSection([
          for (final t in TvTab.moreFor(phone: _phone))
            PickerItem(
              key: ValueKey('tv-more-${t.name}'),
              value: t,
              icon: _toolIcon(t),
              title: _toolTitle(t),
              subtitle: _toolLine(t),
            ),
        ]),
      ],
    );
    if (picked != null && mounted) _openTool(picked);
  }

  /// The TV's tools, folded away under the remote.
  OmniDisclosure _tvTools() => OmniDisclosure(
    key: const ValueKey('tv-tools'),
    storageId: 'tv-tools-${widget.id}',
    icon: OmniIcons.handyman,
    title: 'TV tools',
    summary: 'System, files, TV settings',
    children: [
      for (final (i, t) in TvTab.moreFor(phone: _phone).indexed)
        OmniListRow(
          key: ValueKey('tv-more-${t.name}'),
          icon: _toolIcon(t),
          title: _toolTitle(t),
          subtitle: _toolLine(t),
          chevron: true,
          divider: i < TvTab.moreFor(phone: _phone).length - 1,
          onTap: () => _openTool(t),
        ),
    ],
  );

  Widget _body(TvTab tab, {bool active = false}) => switch (tab) {
    TvTab.remote when _phone => PhoneRemoteTab(tv: tv),
    TvTab.remote => Consumer(
      builder: (context, ref, _) => TvRemoteTab(
        tv: tv,
        active: active || _tab == TvTab.remote,
        sections: [
          _tvTools(),
          if (_device case final device?)
            ...deviceSections(ref, DeviceView(device)),
        ],
      ),
    ),
    TvTab.screen => TvScreenTab(tv: tv, active: active || _tab == tab),
    TvTab.apps => TvAppsTab(tv: tv),
    TvTab.system => TvSystemTab(tv: tv, active: active || _tab == tab),
    TvTab.settings => TvSettingsTab(tv: tv),
    TvTab.files => TvFilesTab(tv: tv),
    TvTab.console => TvConsoleTab(tv: tv),
  };

  Json? get _device => ref
      .watch(devicesProvider)
      .value
      ?.where((d) => d['id'] == widget.id)
      .firstOrNull;

  /// The app can pair it again itself (not a code shown on the TV).
  bool get _pairable => switch (_device) {
    final d? => pairsInApp(d) && !TvCalls.pairsWithCode(d),
    null => false,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tv,
    builder: (context, _) {
      return DetailPage.custom(
        title: widget.name,
        actions: [
          _powerAction(context),
          if (_phone)
            OmniIconAction(
              key: const ValueKey('tv-tab-more'),
              icon: OmniIcons.handyman,
              label: 'Phone tools',
              onPressed: _phoneTools,
            ),
          if (_device case final device?)
            OmniIconAction(
              key: const ValueKey('tv-header-device'),
              icon: OmniIcons.more,
              label: 'Room, name and settings',
              onPressed: () => SheetTemplate.show<void>(
                context,
                builder: (_) => SheetTemplate(
                  title: widget.name,
                  children: (_) => [
                    UsedInSection(device: DeviceView(device)),
                    DeviceSection(device: DeviceView(device)),
                  ],
                ),
              ),
            ),
        ],
        banners: [
          // One banner, one action: Pair again when the app can pair it,
          // else Retry.
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
              actionLabel: _pairable ? 'Pair again' : 'Retry',
              onAction: _pairable
                  ? () => showPairDevice(context, _device!)
                  : tv.refresh,
            ),
        ],
        hero: TvHeader(tv: tv),
        tabs: OmniSegmented<TvTab>(
          key: const ValueKey('tv-tabs'),
          segments: [
            for (final t in TvTab.mainFor(phone: _phone))
              OmniSegment(t, t.label),
          ],
          selected: _tab,
          onChanged: _open,
        ),
        body: (context) => IndexedStack(
          index: _tab.index,
          children: [
            for (final t in TvTab.values)
              _opened.contains(t) ? _body(t) : const SizedBox.shrink(),
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
      // The engine records a TV that did not answer as off (deep standby
      // drops it off the network), so a failed last read says that, never
      // "Off" or what it was playing before.
      final silent = tv.offline != null && !tv.needsPairing;
      final max = s.volumeMax <= 0 ? 100 : s.volumeMax;
      final app = s.app;
      final name = tv.appName;
      final playing = playingLabel(s.playing);
      // Large text gets the full height slider and a second line, so
      // nothing in the header is cut.
      final large = MediaQuery.textScalerOf(context).scale(16) / 16 > 1.3;
      return OmniCard(
        // The detail template puts the gap under the hero.
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.fromLTRB(
          OmniSpace.md,
          OmniSpace.md,
          OmniSpace.xs,
          OmniSpace.xs,
        ),
        child: Row(
          children: [
            if (app != null && name != null && s.isOn && !silent)
              AppBadge(package: app, name: name, size: 40)
            else
              OmniIconBox(
                icon: tv.isPhone ? OmniIcons.phone : OmniIcons.tv,
                size: 40,
              ),
            const SizedBox(width: OmniSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.isOn && !silent)
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
                      maxLines: large ? 3 : 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Text(
                      silent
                          ? 'Not answering'
                          : powerLabel(
                              s.power,
                              loaded: tv.loaded,
                              phone: tv.isPhone,
                            ),
                      key: const ValueKey('tv-power-state'),
                      style: OmniText.bodyStrong,
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: OmniLabelledSlider(
                          key: const ValueKey('tv-volume'),
                          label: 'Volume',
                          height: large ? OmniSpace.targetLarge : 28,
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
