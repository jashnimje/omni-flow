import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test reads a 24-hour clock unless it says otherwise, so engine
/// words read "19:30" as the fixtures write them. A test of 12-hour words
/// overrides `hour12Provider`.
///
/// Every test also runs on a phone set to dark mode, so the System theme
/// (the default) shows the dark palette the colour checks expect. A light
/// theme test sets `platformBrightnessTestValue` or picks Light.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
    ..alwaysUse24HourFormatTestValue = true
    ..platformBrightnessTestValue = Brightness.dark;
  await testMain();
}
