/// A person, as device.list lists the virtual thing.
final jade = <String, Object?>{
  'id': 'jade',
  'name': 'Jade',
  'driver': 'person',
  'host': 'virtual',
  'settings': const <String, Object?>{},
  'state': const {'home': false, 'place': null},
  'capabilities': [
    {
      'id': 'home',
      'type': 'sensor',
      'label': 'At home',
      'stateKey': 'home',
      'params': {},
    },
    {
      'id': 'place',
      'type': 'sensor',
      'label': 'Place',
      'stateKey': 'place',
      'params': {},
    },
  ],
};

/// An NFC tag thing, with the event a scan raises.
final frontDoorTag = <String, Object?>{
  'id': 'front_door',
  'name': 'Front door tag',
  'driver': 'nfc_tag',
  'host': 'virtual',
  'settings': const {'uid': '04A22B1C'},
  'state': const <String, Object?>{},
  'capabilities': [
    {
      'id': 'last_scanned',
      'type': 'sensor',
      'label': 'Last scanned',
      'stateKey': 'last_scanned',
      'params': {},
    },
    {'id': 'scanned', 'type': 'event', 'label': 'Scanned', 'params': {}},
  ],
};
