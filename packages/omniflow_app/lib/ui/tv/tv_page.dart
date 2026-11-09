import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import 'tv_apps.dart';
import 'tv_console.dart';
import 'tv_controller.dart';
import 'tv_files.dart';
import 'tv_remote.dart';
import 'tv_settings.dart';

Future<void> openTv(BuildContext context, Json device) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvPage(
          id: '${device['id']}',
          name: '${device['name'] ?? device['id']}',
        ),
      ),
    );

/// Full control of one Android TV: a live header and a tab per area.
class TvPage extends ConsumerStatefulWidget {
  const TvPage({super.key, required this.id, required this.name});

  final String id;
  final String name;

  @override
  ConsumerState<TvPage> createState() => _TvPageState();
}

class _TvPageState extends ConsumerState<TvPage> {
  late final TvController tv = TvController(
    client: ref.read(engineClientProvider),
    id: widget.id,
    poll: ref.read(tvPollProvider),
  )..start();

  @override
  void dispose() {
    tv.dispose();
    super.dispose();
  }

  static const _tabs = [
    Tab(icon: Icon(Icons.settings_remote), text: 'Remote'),
    Tab(icon: Icon(Icons.apps), text: 'Apps'),
    Tab(icon: Icon(Icons.tune), text: 'Settings'),
    Tab(icon: Icon(Icons.folder_open), text: 'Files'),
    Tab(icon: Icon(Icons.terminal), text: 'Console'),
  ];

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: _tabs.length,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          IconButton(
            key: const ValueKey('tv-refresh'),
            tooltip: 'Read the TV again',
            onPressed: tv.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: const TabBar(
          key: ValueKey('tv-tabs'),
          labelPadding: EdgeInsets.zero,
          tabs: _tabs,
        ),
      ),
      body: Column(
        children: [
          TvHeader(tv: tv),
          Expanded(
            child: TabBarView(
              // Swiping would fight the D-pad, sliders and file lists.
              physics: const NeverScrollableScrollPhysics(),
              children: [
                TvRemoteTab(tv: tv),
                TvAppsTab(tv: tv),
                TvSettingsTab(tv: tv),
                TvFilesTab(tv: tv),
                TvConsoleTab(tv: tv),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Power, the app in front, playback and volume, read every few seconds.
class TvHeader extends StatefulWidget {
  const TvHeader({super.key, required this.tv});

  final TvController tv;

  @override
  State<TvHeader> createState() => _TvHeaderState();
}

class _TvHeaderState extends State<TvHeader> {
  double? _dragging;

  TvController get tv => widget.tv;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tv,
    builder: (context, _) {
      final s = tv.state;
      final theme = Theme.of(context);
      final max = s.volumeMax <= 0 ? 100 : s.volumeMax;
      final volume = _dragging ?? (s.volume ?? 0).clamp(0, max).toDouble();
      return Material(
        color: theme.colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 12, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (tv.offline != null)
                Container(
                  key: const ValueKey('tv-offline'),
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_off,
                        size: 18,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'TV not reachable: ${tv.offline}',
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: tv.refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  IconButton.filledTonal(
                    key: const ValueKey('tv-header-power'),
                    tooltip: s.isOn ? 'Put the TV to sleep' : 'Wake the TV',
                    onPressed: () =>
                        tv.key(s.isOn ? Keycodes.sleep : Keycodes.wakeup),
                    icon: Icon(
                      Icons.power_settings_new,
                      color: s.isOn ? Colors.greenAccent : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          powerLabel(s.power, loaded: tv.loaded),
                          key: const ValueKey('tv-power-state'),
                          style: theme.textTheme.labelMedium,
                        ),
                        Text(
                          s.app == null
                              ? 'No app in front'
                              : tv.appLabels[s.app] ?? s.app!,
                          key: const ValueKey('tv-app'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                  ),
                  if (s.playing != null)
                    Chip(
                      key: const ValueKey('tv-playing'),
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(playingIcon(s.playing), size: 16),
                      label: Text(playingLabel(s.playing)),
                    ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('tv-mute'),
                    tooltip: s.muted == true ? 'Unmute' : 'Mute',
                    onPressed: () => tv.key(Keycodes.mute),
                    icon: Icon(
                      s.muted == true ? Icons.volume_off : Icons.volume_up,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('tv-volume'),
                      min: 0,
                      max: max.toDouble(),
                      divisions: max.clamp(1, 100),
                      value: volume.clamp(0, max.toDouble()),
                      label: '${volume.round()}',
                      semanticFormatterCallback: (v) => 'Volume ${v.round()}',
                      onChanged: (v) => setState(() => _dragging = v),
                      onChangeEnd: (v) async {
                        await tv.setVolume(v.round());
                        if (mounted) setState(() => _dragging = null);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      s.volume == null && _dragging == null
                          ? '-'
                          : '${volume.round()}',
                      key: const ValueKey('tv-volume-value'),
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

String powerLabel(String? power, {bool loaded = true}) => switch (power) {
  'on' => 'On',
  'asleep' => 'Asleep',
  'off' => 'Off',
  _ => loaded ? 'Power unknown' : 'Reading the TV...',
};

String playingLabel(String? playing) => switch (playing) {
  'playing' => 'Playing',
  'paused' => 'Paused',
  'stopped' => 'Stopped',
  _ => '',
};

IconData playingIcon(String? playing) => switch (playing) {
  'playing' => Icons.play_arrow,
  'paused' => Icons.pause,
  _ => Icons.stop,
};

/// Android key codes the app itself uses outside the remote layout.
abstract final class Keycodes {
  static const power = 26;
  static const sleep = 223;
  static const wakeup = 224;
  static const mute = 164;
}

/// Whether [device] gets the TV card and control centre.
bool isTvDevice(Json device) => TvCalls.isTv(device);
