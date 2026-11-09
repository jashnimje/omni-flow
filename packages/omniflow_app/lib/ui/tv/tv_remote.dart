import 'package:flutter/material.dart';

import '../../api/tv_calls.dart';
import 'tv_controller.dart';

/// One remote button, placed by its Android key code so the layout holds
/// whatever names the engine's catalog gives the keys.
class RemoteKey {
  const RemoteKey(this.keycode, this.label, [this.icon]);

  final int keycode;
  final String label;
  final IconData? icon;
}

abstract final class RemoteLayout {
  static const power = RemoteKey(26, 'Power', Icons.power_settings_new);
  static const sleep = RemoteKey(223, 'Sleep', Icons.bedtime_outlined);
  static const wakeup = RemoteKey(224, 'Wake', Icons.wb_sunny_outlined);
  static const inputs = [
    RemoteKey(178, 'TV input', Icons.input),
    RemoteKey(243, 'HDMI 1'),
    RemoteKey(244, 'HDMI 2'),
    RemoteKey(245, 'HDMI 3'),
    RemoteKey(246, 'HDMI 4'),
  ];
  static const back = RemoteKey(4, 'Back', Icons.arrow_back);
  static const home = RemoteKey(3, 'Home', Icons.home_outlined);
  static const menu = RemoteKey(82, 'Menu', Icons.menu);
  static const up = RemoteKey(19, 'Up', Icons.keyboard_arrow_up);
  static const down = RemoteKey(20, 'Down', Icons.keyboard_arrow_down);
  static const left = RemoteKey(21, 'Left', Icons.keyboard_arrow_left);
  static const right = RemoteKey(22, 'Right', Icons.keyboard_arrow_right);
  static const ok = RemoteKey(23, 'OK');
  static const system = [
    RemoteKey(176, 'Settings', Icons.settings_outlined),
    RemoteKey(84, 'Search', Icons.search),
    RemoteKey(219, 'Assistant', Icons.mic_none),
    RemoteKey(187, 'Recent apps', Icons.view_carousel_outlined),
  ];
  static const volumeUp = RemoteKey(24, 'Volume up', Icons.add);
  static const volumeDown = RemoteKey(25, 'Volume down', Icons.remove);
  static const mute = RemoteKey(164, 'Mute', Icons.volume_off_outlined);
  static const channelUp = RemoteKey(
    166,
    'Channel up',
    Icons.keyboard_arrow_up,
  );
  static const channelDown = RemoteKey(
    167,
    'Channel down',
    Icons.keyboard_arrow_down,
  );
  static const info = [
    RemoteKey(172, 'Guide', Icons.calendar_view_week_outlined),
    RemoteKey(165, 'Info', Icons.info_outline),
    RemoteKey(175, 'Captions', Icons.closed_caption_outlined),
    RemoteKey(229, 'Last channel', Icons.history),
  ];
  static const media = [
    RemoteKey(88, 'Previous', Icons.skip_previous),
    RemoteKey(89, 'Rewind', Icons.fast_rewind),
    RemoteKey(85, 'Play or pause', Icons.play_arrow),
    RemoteKey(86, 'Stop', Icons.stop),
    RemoteKey(90, 'Fast forward', Icons.fast_forward),
    RemoteKey(87, 'Next', Icons.skip_next),
  ];
  static const numbers = [
    RemoteKey(8, '1'),
    RemoteKey(9, '2'),
    RemoteKey(10, '3'),
    RemoteKey(11, '4'),
    RemoteKey(12, '5'),
    RemoteKey(13, '6'),
    RemoteKey(14, '7'),
    RemoteKey(15, '8'),
    RemoteKey(16, '9'),
    RemoteKey(67, 'Delete', Icons.backspace_outlined),
    RemoteKey(7, '0'),
    RemoteKey(66, 'Enter', Icons.keyboard_return),
  ];
  static const colors = [
    (RemoteKey(183, 'Red'), Color(0xFFE53935)),
    (RemoteKey(184, 'Green'), Color(0xFF43A047)),
    (RemoteKey(185, 'Yellow'), Color(0xFFFDD835)),
    (RemoteKey(186, 'Blue'), Color(0xFF1E88E5)),
  ];

  static final placed = <int>{
    for (final k in [
      power,
      sleep,
      wakeup,
      ...inputs,
      back,
      home,
      menu,
      up,
      down,
      left,
      right,
      ok,
      ...system,
      volumeUp,
      volumeDown,
      mute,
      channelUp,
      channelDown,
      ...info,
      ...media,
      ...numbers,
      for (final c in colors) c.$1,
    ])
      k.keycode,
  };
}

class TvRemoteTab extends StatefulWidget {
  const TvRemoteTab({super.key, required this.tv});

  final TvController tv;

  @override
  State<TvRemoteTab> createState() => _TvRemoteTabState();
}

class _TvRemoteTabState extends State<TvRemoteTab>
    with AutomaticKeepAliveClientMixin {
  var _longPress = false;
  final _text = TextEditingController();

  TvController get tv => widget.tv;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _press(RemoteKey k, {bool long = false}) =>
      tv.key(k.keycode, longPress: long || _longPress);

  Widget _key(
    RemoteKey k, {
    double size = 52,
    bool filled = false,
    Color? color,
  }) => _RemoteButton(
    remoteKey: k,
    size: size,
    filled: filled,
    color: color,
    onTap: () => _press(k),
    onLongPress: () => _press(k, long: true),
  );

  Future<void> _sendText() async {
    final text = _text.text;
    if (text.isEmpty) return;
    final result = await tv.call(TvCalls.text, TvCalls.textArgs(tv.id, text));
    if (result['ok'] == true && mounted) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: tv,
      builder: (context, _) => ListView(
        key: const ValueKey('tv-remote'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Row(
            children: [
              _key(RemoteLayout.power, color: Colors.redAccent),
              const SizedBox(width: 8),
              _key(RemoteLayout.sleep),
              const SizedBox(width: 8),
              _key(RemoteLayout.wakeup),
              const Spacer(),
              FilterChip(
                key: const ValueKey('long-press'),
                label: const Text('Long press'),
                tooltip:
                    'Hold every key you tap. A long press on a key '
                    'always holds it.',
                selected: _longPress,
                onSelected: (v) => setState(() => _longPress = v),
              ),
            ],
          ),
          _Section(
            title: 'Inputs',
            // A pill fills the width it gets, so each input takes an even
            // share of one row instead of a row of its own.
            child: Row(
              children: [
                for (final k in RemoteLayout.inputs)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _PillKey(
                        remoteKey: k,
                        onTap: () => _press(k),
                        onLongPress: () => _press(k, long: true),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _Section(
            title: 'Navigate',
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _key(RemoteLayout.back),
                    _key(RemoteLayout.home),
                    _key(RemoteLayout.menu),
                  ],
                ),
                const SizedBox(height: 8),
                _DPad(button: _key),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [for (final k in RemoteLayout.system) _key(k)],
                ),
              ],
            ),
          ),
          _Section(
            title: 'Volume and channels',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Rocker(
                  label: 'VOL',
                  top: _key(RemoteLayout.volumeUp),
                  middle: _key(RemoteLayout.mute, size: 44),
                  bottom: _key(RemoteLayout.volumeDown),
                ),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [for (final k in RemoteLayout.info) _key(k)],
                  ),
                ),
                _Rocker(
                  label: 'CH',
                  top: _key(RemoteLayout.channelUp),
                  bottom: _key(RemoteLayout.channelDown),
                ),
              ],
            ),
          ),
          _Section(
            title: 'Playback',
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final k in RemoteLayout.media)
                  _key(k, size: 46, filled: k.keycode == 85),
              ],
            ),
          ),
          _Section(
            title: 'Numbers',
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.4,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                for (final k in RemoteLayout.numbers)
                  _PillKey(
                    remoteKey: k,
                    onTap: () => _press(k),
                    onLongPress: () => _press(k, long: true),
                  ),
              ],
            ),
          ),
          _Section(
            title: 'Colour keys',
            child: Row(
              children: [
                for (final (k, color) in RemoteLayout.colors)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _PillKey(
                        remoteKey: k,
                        color: color,
                        onTap: () => _press(k),
                        onLongPress: () => _press(k, long: true),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _Section(
            title: 'Type on the TV',
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('tv-text'),
                    controller: _text,
                    maxLength: TvCalls.maxText,
                    decoration: const InputDecoration(
                      hintText: 'Text for the field in focus on the TV',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
                IconButton(
                  key: const ValueKey('tv-text-send'),
                  tooltip: 'Type it on the TV',
                  onPressed: _sendText,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
          for (final g in tv.keyGroups)
            if (g.keys.where((k) => !_isPlaced(k)).toList() case final extra
                when extra.isNotEmpty)
              _Section(
                title: 'More ${g.group} keys',
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final k in extra)
                      ActionChip(
                        key: ValueKey('catalog-${k.key}'),
                        label: Text(k.label),
                        onPressed: () =>
                            tv.sendKey(name: k.key, longPress: _longPress),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  static bool _isPlaced(TvKey k) =>
      k.keycode != null && RemoteLayout.placed.contains(k.keycode);
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
        child,
      ],
    ),
  );
}

class _RemoteButton extends StatelessWidget {
  const _RemoteButton({
    required this.remoteKey,
    required this.size,
    required this.filled,
    required this.onTap,
    required this.onLongPress,
    this.color,
  });

  final RemoteKey remoteKey;
  final double size;
  final bool filled;
  final Color? color;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final k = remoteKey;
    return Tooltip(
      message: k.label,
      child: Material(
        key: ValueKey('key-${k.keycode}'),
        color: filled ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: k.icon == null
                  ? Text(
                      k.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    )
                  : Icon(k.icon, color: color, semanticLabel: k.label),
            ),
          ),
        ),
      ),
    );
  }
}

/// A wide rounded key with a text label: inputs, numbers and colours.
class _PillKey extends StatelessWidget {
  const _PillKey({
    required this.remoteKey,
    required this.onTap,
    required this.onLongPress,
    this.color,
  });

  final RemoteKey remoteKey;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final k = remoteKey;
    return Material(
      key: ValueKey('key-${k.keycode}'),
      color: color ?? scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (k.icon != null) ...[
                  Icon(k.icon, size: 18),
                  const SizedBox(width: 6),
                ],
                Text(
                  k.label,
                  style: color == null
                      ? null
                      : const TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w600,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Up, down, left and right around OK.
class _DPad extends StatelessWidget {
  const _DPad({required this.button});

  final Widget Function(RemoteKey k, {double size, bool filled, Color? color})
  button;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          shape: BoxShape.circle,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: button(RemoteLayout.up, size: 60),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: button(RemoteLayout.down, size: 60),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: button(RemoteLayout.left, size: 60),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: button(RemoteLayout.right, size: 60),
            ),
            button(RemoteLayout.ok, size: 76, filled: true),
          ],
        ),
      ),
    );
  }
}

/// A vertical rocker: volume or channel.
class _Rocker extends StatelessWidget {
  const _Rocker({
    required this.label,
    required this.top,
    required this.bottom,
    this.middle,
  });

  final String label;
  final Widget top;
  final Widget bottom;
  final Widget? middle;

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    padding: const EdgeInsets.symmetric(vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(32),
    ),
    child: Column(
      children: [
        top,
        const SizedBox(height: 4),
        middle ?? Text(label, style: Theme.of(context).textTheme.labelSmall),
        if (middle != null)
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        bottom,
      ],
    ),
  );
}
