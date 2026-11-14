import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart' show Json;

/// Every icon the app shows, from Material Symbols (rounded). Screens take
/// icons from here, so one capability or category always has one icon.
abstract final class OmniIcons {
  static const home = Symbols.home_rounded;
  static const automations = Symbols.bolt_rounded;
  static const devices = Symbols.grid_view_rounded;
  static const settings = Symbols.settings_rounded;

  static const add = Symbols.add_rounded;
  static const search = Symbols.search_rounded;
  static const notifications = Symbols.notifications_rounded;
  static const back = Symbols.arrow_back_ios_new_rounded;
  static const chevron = Symbols.chevron_right_rounded;
  static const close = Symbols.close_rounded;
  static const more = Symbols.more_horiz_rounded;
  static const drag = Symbols.drag_indicator_rounded;
  static const star = Symbols.star_rounded;
  static const edit = Symbols.edit_rounded;
  static const delete = Symbols.delete_rounded;
  static const retry = Symbols.restart_alt_rounded;
  static const check = Symbols.check_rounded;
  static const enter = Symbols.keyboard_return_rounded;
  static const play = Symbols.play_arrow_rounded;
  static const test = Symbols.play_circle_rounded;

  static const info = Symbols.info_rounded;
  static const warning = Symbols.warning_rounded;
  static const error = Symbols.error_rounded;

  static const power = Symbols.power_settings_new_rounded;
  static const level = Symbols.tune_rounded;
  static const colorTemp = Symbols.light_mode_rounded;
  static const color = Symbols.palette_rounded;
  static const remote = Symbols.settings_remote_rounded;
  static const terminal = Symbols.terminal_rounded;
  static const sensor = Symbols.sensors_rounded;
  static const action = Symbols.touch_app_rounded;
  static const event = Symbols.radio_button_checked_rounded;

  static const light = Symbols.lightbulb_rounded;
  static const plug = Symbols.outlet_rounded;
  static const tv = Symbols.tv_rounded;
  static const speaker = Symbols.speaker_rounded;
  static const board = Symbols.developer_board_rounded;
  static const tag = Symbols.nfc_rounded;
  static const person = Symbols.person_rounded;
  static const place = Symbols.location_on_rounded;
  static const phone = Symbols.smartphone_rounded;
  static const computer = Symbols.computer_rounded;
  static const server = Symbols.dns_rounded;
  static const gauge = Symbols.thermostat_rounded;
  static const zigbee = Symbols.hub_rounded;
  static const device = Symbols.devices_other_rounded;

  static const room = Symbols.meeting_room_rounded;
  static const scene = Symbols.movie_rounded;
  static const time = Symbols.schedule_rounded;
  static const sun = Symbols.wb_twilight_rounded;
  static const repeat = Symbols.repeat_rounded;
  static const wait = Symbols.timer_rounded;
  static const branch = Symbols.call_split_rounded;
  static const wifi = Symbols.wifi_rounded;
  static const bluetooth = Symbols.bluetooth_rounded;
  static const hub = Symbols.monitor_rounded;
  static const permissions = Symbols.lock_rounded;
  static const video = Symbols.videocam_rounded;
  static const screen = Symbols.screen_share_rounded;
  static const gamepad = Symbols.sports_esports_rounded;
  static const system = Symbols.memory_rounded;
  static const storage = Symbols.hard_drive_rounded;
  static const network = Symbols.swap_vert_rounded;
  static const temperature = Symbols.device_thermostat_rounded;
  static const cleaning = Symbols.cleaning_services_rounded;
  static const shutdown = Symbols.power_settings_new_rounded;
  static const download = Symbols.download_rounded;
  static const upload = Symbols.upload_rounded;
  static const backup = Symbols.backup_rounded;
  static const agent = Symbols.smart_toy_rounded;
  static const developer = Symbols.swap_vert_rounded;
  static const about = Symbols.info_rounded;
  static const packets = Symbols.swap_vert_rounded;

  /// The icon of a capability type (`toggle`, `level`, ...).
  static IconData forCapability(String? type) => switch (type) {
    'toggle' => power,
    'level' => level,
    'color_temp' => colorTemp,
    'color_rgb' => color,
    'dpad_remote' => remote,
    'text_command' || 'exec' => terminal,
    'sensor' => sensor,
    'event' => event,
    'action' => action,
    _ => device,
  };

  /// The icon of a driver category (`lighting`, `media`, ...).
  static IconData forCategory(String? category) => switch (category) {
    'lighting' => light,
    'power' => plug,
    'media' => tv,
    'microcontroller' => board,
    'tag' => tag,
    'presence' => person,
    'phone' => phone,
    'computer' => computer,
    'sensor' => gauge,
    'zigbee' => zigbee,
    _ => device,
  };

  /// The icon a driver manifest names (its `icon` field).
  static IconData? forManifestIcon(String? name) => switch (name) {
    'lightbulb' => light,
    'plug' || 'power' => plug,
    'tv' => tv,
    'speaker' => speaker,
    'cpu' => board,
    'nfc' => tag,
    'person' => person,
    'place' => place,
    'smartphone' => phone,
    'laptop' => computer,
    'server' => server,
    'gauge' => gauge,
    'zigbee' => zigbee,
    _ => null,
  };

  /// A device row's icon: the manifest icon or category when the row
  /// carries one, else what its capability types make it look like.
  static IconData forDevice(Json row) {
    final named = forManifestIcon(row['icon'] as String?);
    if (named != null) return named;
    if (row['category'] case final String category) {
      return forCategory(category);
    }
    final types = {
      for (final c in (row['capabilities'] as List? ?? const []))
        if (c is Map) c['type'],
    };
    if (types.contains('dpad_remote')) return tv;
    if (types.intersection(const {
      'level',
      'color_temp',
      'color_rgb',
    }).isNotEmpty) {
      return light;
    }
    if (types.contains('toggle')) return plug;
    if (types.contains('exec') || types.contains('text_command')) {
      return computer;
    }
    if (types.contains('sensor')) return gauge;
    if (types.contains('event')) return event;
    return device;
  }
}
