/// One remote key: its catalog name, a label for a button, and the Android
/// key code `input keyevent` sends.
typedef TvKey = ({String key, String label, int keycode});

/// The Android key codes useful on a TV, grouped as a remote lays them out.
/// Codes are `android.view.KeyEvent.KEYCODE_*`.
const List<({String group, List<TvKey> keys})> tvKeyGroups = [
  (
    group: 'power',
    keys: [
      (key: 'power', label: 'Power', keycode: 26),
      (key: 'tv_power', label: 'TV power', keycode: 177),
      (key: 'sleep', label: 'Sleep', keycode: 223),
      (key: 'wakeup', label: 'Wake up', keycode: 224),
    ],
  ),
  (
    group: 'navigation',
    keys: [
      (key: 'up', label: 'Up', keycode: 19),
      (key: 'down', label: 'Down', keycode: 20),
      (key: 'left', label: 'Left', keycode: 21),
      (key: 'right', label: 'Right', keycode: 22),
      (key: 'ok', label: 'OK', keycode: 23),
      (key: 'back', label: 'Back', keycode: 4),
      (key: 'home', label: 'Home', keycode: 3),
      (key: 'menu', label: 'Menu', keycode: 82),
      (key: 'enter', label: 'Enter', keycode: 66),
      (key: 'page_up', label: 'Page up', keycode: 92),
      (key: 'page_down', label: 'Page down', keycode: 93),
      (key: 'tab', label: 'Tab', keycode: 61),
      (key: 'escape', label: 'Escape', keycode: 111),
      (key: 'delete', label: 'Delete', keycode: 67),
    ],
  ),
  (
    group: 'volume',
    keys: [
      (key: 'volume_up', label: 'Volume up', keycode: 24),
      (key: 'volume_down', label: 'Volume down', keycode: 25),
      (key: 'mute', label: 'Mute', keycode: 164),
    ],
  ),
  (
    group: 'channel',
    keys: [
      (key: 'channel_up', label: 'Channel up', keycode: 166),
      (key: 'channel_down', label: 'Channel down', keycode: 167),
      (key: 'last_channel', label: 'Last channel', keycode: 229),
      (key: 'tv', label: 'Live TV', keycode: 170),
      (key: 'dvr', label: 'Recordings', keycode: 173),
      (key: 'teletext', label: 'Teletext', keycode: 233),
      (key: 'zoom', label: 'Zoom mode', keycode: 255),
    ],
  ),
  (
    group: 'media',
    keys: [
      (key: 'play_pause', label: 'Play or pause', keycode: 85),
      (key: 'play', label: 'Play', keycode: 126),
      (key: 'pause', label: 'Pause', keycode: 127),
      (key: 'stop', label: 'Stop', keycode: 86),
      (key: 'next', label: 'Next', keycode: 87),
      (key: 'previous', label: 'Previous', keycode: 88),
      (key: 'rewind', label: 'Rewind', keycode: 89),
      (key: 'fast_forward', label: 'Fast forward', keycode: 90),
      (key: 'skip_forward', label: 'Skip forward', keycode: 272),
      (key: 'skip_backward', label: 'Skip back', keycode: 273),
      (key: 'step_forward', label: 'Step forward', keycode: 274),
      (key: 'step_backward', label: 'Step back', keycode: 275),
      (key: 'record', label: 'Record', keycode: 130),
      (key: 'audio_track', label: 'Audio track', keycode: 222),
    ],
  ),
  (
    group: 'numbers',
    keys: [
      (key: '0', label: '0', keycode: 7),
      (key: '1', label: '1', keycode: 8),
      (key: '2', label: '2', keycode: 9),
      (key: '3', label: '3', keycode: 10),
      (key: '4', label: '4', keycode: 11),
      (key: '5', label: '5', keycode: 12),
      (key: '6', label: '6', keycode: 13),
      (key: '7', label: '7', keycode: 14),
      (key: '8', label: '8', keycode: 15),
      (key: '9', label: '9', keycode: 16),
      (key: 'star', label: '*', keycode: 17),
      (key: 'pound', label: '#', keycode: 18),
    ],
  ),
  (
    group: 'colors',
    keys: [
      (key: 'red', label: 'Red', keycode: 183),
      (key: 'green', label: 'Green', keycode: 184),
      (key: 'yellow', label: 'Yellow', keycode: 185),
      (key: 'blue', label: 'Blue', keycode: 186),
    ],
  ),
  (
    group: 'inputs',
    keys: [
      (key: 'tv_input', label: 'Input', keycode: 178),
      (key: 'hdmi1', label: 'HDMI 1', keycode: 243),
      (key: 'hdmi2', label: 'HDMI 2', keycode: 244),
      (key: 'hdmi3', label: 'HDMI 3', keycode: 245),
      (key: 'hdmi4', label: 'HDMI 4', keycode: 246),
      (key: 'antenna_cable', label: 'Antenna or cable', keycode: 242),
      (key: 'composite1', label: 'Composite 1', keycode: 247),
      (key: 'component1', label: 'Component 1', keycode: 249),
    ],
  ),
  (
    group: 'system',
    keys: [
      (key: 'settings', label: 'Settings', keycode: 176),
      (key: 'guide', label: 'Guide', keycode: 172),
      (key: 'info', label: 'Info', keycode: 165),
      (key: 'captions', label: 'Captions', keycode: 175),
      (key: 'search', label: 'Search', keycode: 84),
      (key: 'assistant', label: 'Assistant', keycode: 219),
      (key: 'voice_assist', label: 'Voice', keycode: 231),
      (key: 'all_apps', label: 'All apps', keycode: 284),
      (key: 'app_switch', label: 'Recent apps', keycode: 187),
      (key: 'notification', label: 'Notifications', keycode: 83),
      (key: 'bookmark', label: 'Bookmark', keycode: 174),
      (key: 'pip', label: 'Picture in picture', keycode: 171),
      (key: 'brightness_up', label: 'Brightness up', keycode: 221),
      (key: 'brightness_down', label: 'Brightness down', keycode: 220),
      (key: 'help', label: 'Help', keycode: 259),
    ],
  ),
];

/// Names the key op also takes, kept for drivers and flows written before
/// the catalog.
const _aliases = {'center': 23};

/// Every key name to its key code.
final Map<String, int> tvKeyCodes = {
  for (final g in tvKeyGroups)
    for (final k in g.keys) k.key: k.keycode,
  ..._aliases,
};

/// The catalog as `tv.keys` returns it.
List<Map<String, Object?>> tvKeyCatalogJson() => [
  for (final g in tvKeyGroups)
    {
      'group': g.group,
      'keys': [
        for (final k in g.keys)
          {'key': k.key, 'label': k.label, 'keycode': k.keycode},
      ],
    },
];
