import 'dart:io';

import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/manifest/built_in_drivers.g.dart';

/// The protocol v1 board drivers, kept as fixtures so the UDP and serial
/// channel tests still cover a plain line protocol.
final v1DriverSources = {
  for (final name in [
    'v1_board_udp.omni_driver.json',
    'v1_board_serial.omni_driver.json',
  ])
    name: File('test/fixtures/$name').readAsStringSync(),
};

DriverRegistry v1Registry() => DriverRegistry.withBuiltIns(
  sources: {...builtInDriverSources, ...v1DriverSources},
);
