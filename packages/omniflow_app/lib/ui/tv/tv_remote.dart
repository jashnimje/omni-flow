import 'package:flutter/material.dart';

import '../../api/tv_calls.dart';
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_widgets.dart';

/// One remote button, placed by its Android key code so the layout holds
/// whatever names the engine's catalog gives the keys.
class RemoteKey {
  const RemoteKey(this.keycode, this.label, [this.icon, this.text]);

  final int keycode;

  /// Read out, and shown when the key has no [icon] or carries [text].
  final String label;
  final IconData? icon;

  /// A short word drawn next to the icon ("Back", "Vol −").
  final String? text;
}

/// The remote of the mockup (4.1): the top row, the D-pad, then back, menu,
/// info, volume and media. Scrolling down: numbers, colour keys, channels,
/// inputs, guide and TV settings, sleep and wake, and the text box.
abstract final class RemoteLayout {
  static const power = RemoteKey(26, 'Power', OmniIcons.power);
  static const input = RemoteKey(178, 'Input', null, 'Input');
  static const home = RemoteKey(3, 'Home', OmniIcons.home);
  static const assistant = RemoteKey(219, 'Assistant', TvIcons.mic);
  static const top = [power, input, home, assistant];

  static const up = RemoteKey(19, 'Up', TvIcons.up);
  static const down = RemoteKey(20, 'Down', TvIcons.down);
  static const left = RemoteKey(21, 'Left', TvIcons.left);
  static const right = RemoteKey(22, 'Right', TvIcons.right);
  static const ok = RemoteKey(23, 'OK');

  static const back = RemoteKey(4, 'Back', TvIcons.back, 'Back');
  static const menu = RemoteKey(82, 'Menu', TvIcons.menu, 'Menu');
  static const info = RemoteKey(165, 'Info', TvIcons.info, 'Info');
  static const volumeDown = RemoteKey(25, 'Volume down', null, 'Vol −');
  static const mute = RemoteKey(164, 'Mute', TvIcons.volumeOff);
  static const volumeUp = RemoteKey(24, 'Volume up', null, 'Vol +');
  static const previous = RemoteKey(88, 'Previous', TvIcons.previous);
  static const playPause = RemoteKey(85, 'Play or pause', TvIcons.playPause);
  static const next = RemoteKey(87, 'Next', TvIcons.next);
  static const middle = [
    back,
    menu,
    info,
    volumeDown,
    mute,
    volumeUp,
    previous,
    playPause,
    next,
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
    RemoteKey(67, 'Delete', TvIcons.backspace),
    RemoteKey(7, '0'),
    RemoteKey(66, 'Enter', TvIcons.enter),
  ];
  static const colors = [
    (RemoteKey(183, 'Red'), Color(0xFFEF5350)),
    (RemoteKey(184, 'Green'), Color(0xFF43A047)),
    (RemoteKey(185, 'Yellow'), Color(0xFFFDD835)),
    (RemoteKey(186, 'Blue'), Color(0xFF42A5F5)),
  ];
  static const channels = [
    RemoteKey(167, 'Channel down', TvIcons.down, 'CH'),
    RemoteKey(229, 'Last channel', TvIcons.lastChannel, 'Last'),
    RemoteKey(166, 'Channel up', TvIcons.up, 'CH'),
  ];
  static const inputs = [
    RemoteKey(243, 'HDMI 1'),
    RemoteKey(244, 'HDMI 2'),
    RemoteKey(245, 'HDMI 3'),
    RemoteKey(246, 'HDMI 4'),
  ];
  static const more = [
    RemoteKey(172, 'Guide', TvIcons.guide, 'Guide'),
    RemoteKey(175, 'Captions', TvIcons.captions, 'Captions'),
    RemoteKey(176, 'TV settings', OmniIcons.settings, 'Settings'),
    RemoteKey(84, 'Search', OmniIcons.search, 'Search'),
    RemoteKey(187, 'Recent apps', TvIcons.recents, 'Recents'),
    RemoteKey(223, 'Sleep', TvIcons.sleep, 'Sleep'),
    RemoteKey(224, 'Wake', TvIcons.wake, 'Wake'),
  ];
  static const playback = [
    RemoteKey(89, 'Rewind', TvIcons.rewind),
    RemoteKey(86, 'Stop', TvIcons.stop),
    RemoteKey(90, 'Fast forward', TvIcons.forward),
  ];

  static final placed = <int>{
    for (final k in [
      ...top,
      up,
      down,
      left,
      right,
      ok,
      ...middle,
      ...numbers,
      for (final c in colors) c.$1,
      ...channels,
      ...inputs,
      ...more,
      ...playback,
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

class _TvRemoteTabState extends State<TvRemoteTab> {
  final _text = TextEditingController();

  TvController get tv => widget.tv;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _press(RemoteKey k, {bool long = false}) =>
      tv.key(k.keycode, longPress: long);

  Widget _key(RemoteKey k, {Color? background, Color? foreground}) =>
      TvKeyButton(
        key: ValueKey('key-${k.keycode}'),
        label: k.label,
        icon: k.icon,
        showLabel: k.icon == null || k.text != null,
        text: k.text,
        background: background ?? OmniColors.card,
        foreground: foreground ?? OmniColors.text,
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tv,
    builder: (context, _) => ListView(
      key: const ValueKey('tv-remote'),
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
      children: [
        TvKeyGrid(
          columns: 4,
          children: [for (final k in RemoteLayout.top) _key(k)],
        ),
        _DPad(press: _press),
        TvKeyGrid(
          columns: 3,
          children: [for (final k in RemoteLayout.middle) _key(k)],
        ),
        const Padding(
          padding: EdgeInsets.only(top: OmniSpace.sm),
          child: Text(
            'Swipe up for numbers, colours, channels, inputs and text',
            textAlign: TextAlign.center,
            style: OmniText.caption,
          ),
        ),
        const OmniSectionHeader('Numbers'),
        TvKeyGrid(
          columns: 3,
          children: [for (final k in RemoteLayout.numbers) _key(k)],
        ),
        const OmniSectionHeader('Colour keys'),
        TvKeyGrid(
          columns: 4,
          children: [
            for (final (k, color) in RemoteLayout.colors)
              _key(k, background: color, foreground: const Color(0xFF14171C)),
          ],
        ),
        const OmniSectionHeader('Channels'),
        TvKeyGrid(
          columns: 3,
          children: [for (final k in RemoteLayout.channels) _key(k)],
        ),
        const OmniSectionHeader('Inputs'),
        TvKeyGrid(
          columns: 4,
          children: [for (final k in RemoteLayout.inputs) _key(k)],
        ),
        const OmniSectionHeader('Guide, settings and sleep'),
        TvKeyGrid(
          columns: 3,
          children: [
            for (final k in RemoteLayout.more) _key(k),
            for (final k in RemoteLayout.playback) _key(k),
          ],
        ),
        const OmniSectionHeader('Type on the TV'),
        TextField(
          key: const ValueKey('tv-text'),
          controller: _text,
          maxLength: TvCalls.maxText,
          textInputAction: TextInputAction.send,
          decoration: InputDecoration(
            labelText: 'Text for the box in focus on the TV',
            counterText: '',
            suffixIcon: OmniIconAction(
              key: const ValueKey('tv-text-send'),
              icon: TvIcons.send,
              label: 'Type it on the TV',
              color: OmniColors.accent,
              onPressed: _sendText,
            ),
          ),
          onSubmitted: (_) => _sendText(),
        ),
        for (final g in tv.keyGroups)
          if (g.keys.where((k) => !_isPlaced(k)).toList() case final extra
              when extra.isNotEmpty) ...[
            OmniSectionHeader('More ${g.group} keys'),
            Wrap(
              spacing: OmniSpace.xs,
              children: [
                for (final k in extra)
                  OmniFilterChip(
                    key: ValueKey('catalog-${k.key}'),
                    label: k.label,
                    onTap: () => tv.sendKey(name: k.key),
                  ),
              ],
            ),
          ],
        const SizedBox(height: OmniSpace.sm),
        const Text(
          'Hold a key to send a long press.',
          textAlign: TextAlign.center,
          style: OmniText.caption,
        ),
      ],
    ),
  );

  static bool _isPlaced(TvKey k) =>
      k.keycode != null && RemoteLayout.placed.contains(k.keycode);
}

/// Up, down, left and right around OK, in the mockup's 168 dp ring.
class _DPad extends StatelessWidget {
  const _DPad({required this.press});

  final void Function(RemoteKey k, {bool long}) press;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: OmniSpace.sm),
    child: Center(
      child: Container(
        width: 168,
        height: 168,
        decoration: BoxDecoration(
          color: OmniColors.card,
          shape: BoxShape.circle,
          border: Border.all(color: OmniColors.line),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: _ringKey(RemoteLayout.up),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _ringKey(RemoteLayout.down),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: _ringKey(RemoteLayout.left),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _ringKey(RemoteLayout.right),
            ),
            _ringKey(RemoteLayout.ok, ok: true),
          ],
        ),
      ),
    ),
  );

  Widget _ringKey(RemoteKey k, {bool ok = false}) => SizedBox.square(
    dimension: ok ? 60 : OmniSpace.target + 4,
    child: Semantics(
      button: true,
      label: k.label,
      excludeSemantics: true,
      onTap: () => press(k),
      onLongPress: () => press(k, long: true),
      child: Tooltip(
        message: k.label,
        excludeFromSemantics: true,
        child: Material(
          key: ValueKey('key-${k.keycode}'),
          color: ok ? OmniColors.raised : Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => press(k),
            onLongPress: () => press(k, long: true),
            child: Center(
              child: ok
                  ? const Text(
                      'OK',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: OmniColors.text,
                      ),
                    )
                  : Icon(k.icon, color: OmniColors.muted, size: 26),
            ),
          ),
        ),
      ),
    ),
  );
}
