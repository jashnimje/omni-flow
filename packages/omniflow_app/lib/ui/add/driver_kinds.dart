import 'package:flutter/widgets.dart';

import '../../api/engine_calls.dart';
import '../design/design.dart';

/// A kind of thing people add by hand, in plain words, and the drivers
/// that make one. The driver list in full, with its protocol words, sits
/// under More kinds.
class AddKind {
  const AddKind(this.id, this.title, this.subtitle, this.icon, this.has);

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;

  /// Whether a `driver.list` row makes this kind.
  final bool Function(Json driver) has;
}

String? _category(Json d) => d['category'] as String?;

String? _icon(Json d) => d['icon'] as String?;

/// Drivers that reach many things through one box on the network.
const _hubDrivers = {
  'home_assistant_entity',
  'home_assistant_sensor',
  'zigbee2mqtt_device',
  'philips_hue_light',
};

/// The kinds, most common first.
final addKinds = <AddKind>[
  AddKind(
    'lights',
    'Lights',
    'Bulbs and lamps',
    OmniIcons.light,
    (d) => _category(d) == 'lighting',
  ),
  AddKind(
    'plugs',
    'Plugs',
    'Smart plugs, relays and switches',
    OmniIcons.plug,
    (d) => _category(d) == 'power',
  ),
  AddKind(
    'tvs',
    'TVs',
    'Smart TVs and streaming sticks',
    OmniIcons.tv,
    (d) => _category(d) == 'media' && _icon(d) != 'speaker',
  ),
  AddKind(
    'phones',
    'Phones',
    'Another Android phone',
    OmniIcons.phone,
    (d) => _category(d) == 'phone' && d['transport'] != 'virtual',
  ),
  AddKind(
    'speakers',
    'Speakers',
    'Speakers on your Wi-Fi',
    OmniIcons.speaker,
    (d) => _category(d) == 'media' && _icon(d) == 'speaker',
  ),
  AddKind(
    'boards',
    'Boards',
    'ESP32, ESP8266, Pico W or Uno on Wi-Fi',
    OmniIcons.board,
    (d) => _category(d) == 'microcontroller',
  ),
  AddKind(
    'computers',
    'Computers',
    'A Mac or a Linux computer',
    OmniIcons.computer,
    (d) => _category(d) == 'computer',
  ),
  AddKind(
    'sensors',
    'Sensors',
    'Readings such as temperature or a door',
    OmniIcons.sensor,
    (d) => _category(d) == 'sensor',
  ),
  AddKind(
    'hubs',
    'Hubs',
    'Things behind Home Assistant, a Hue bridge or Zigbee',
    OmniIcons.zigbee,
    (d) => _hubDrivers.contains(d['id']) || _category(d) == 'zigbee',
  ),
];

/// A driver's name without its protocol note: "LG webOS TV (local SSAP
/// over WebSocket)" reads "LG webOS TV".
String plainDriverName(String name) {
  final cut = name.indexOf(' (');
  return cut > 0 ? name.substring(0, cut) : name;
}
