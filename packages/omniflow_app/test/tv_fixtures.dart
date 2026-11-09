import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart';

import 'fake_engine.dart';

const tvId = 'lounge_tv';

Map<String, Object?> tvDevice({Map<String, Object?>? state}) => {
  'id': tvId,
  'name': 'Lounge TV',
  'driver': 'android_tv_adb',
  'host': '192.168.1.60',
  'room': 'Lounge',
  'settings': const <String, Object?>{},
  'state':
      state ??
      const {
        'power': 'on',
        'app': 'com.netflix.ninja',
        'playing': 'playing',
        'volume': 20,
      },
  'capabilities': [
    {'id': 'wake', 'type': 'action', 'label': 'Wake', 'params': {}},
    {
      'id': 'remote',
      'type': 'dpad_remote',
      'label': 'Remote',
      'params': {
        'value': {
          'values': ['up', 'down'],
        },
      },
    },
  ],
};

/// Records picks and hands back [files], like the phone's file picker.
class FakePhoneFiles implements PhoneFiles {
  FakePhoneFiles({this.files = const [], this.downloads = '/phone/Download'});

  List<PickedFile> files;
  String? downloads;
  final picks = <List<String>?>[];
  var cleanups = 0;

  @override
  Future<List<PickedFile>> pick({List<String>? extensions}) async {
    picks.add(extensions);
    return files;
  }

  @override
  Future<String?> downloadsDir() async => downloads;

  @override
  Future<void> cleanup() async => cleanups++;
}

/// A FakeEngine with one TV and answers for every tv.* read.
FakeEngine tvEngine() {
  final engine = FakeEngine()..devices = [tvDevice(), FakeEngine.lamp()];
  engine.answers.addAll({
    'tv.state': {
      'ok': true,
      'power': 'on',
      'app': 'com.netflix.ninja',
      'activity': 'com.netflix.ninja/.MainActivity',
      'playing': 'paused',
      'volume': 30,
      'volumeMax': 100,
      'muted': false,
    },
    'tv.keys': {
      'ok': true,
      'groups': [
        {
          'group': 'navigation',
          'keys': [
            {'key': 'up', 'label': 'Up', 'keycode': 19},
            {'key': 'ok', 'label': 'OK', 'keycode': 23},
            {'key': 'home', 'label': 'Home', 'keycode': 3},
          ],
        },
        {
          'group': 'volume',
          'keys': [
            {'key': 'mute', 'label': 'Mute', 'keycode': 164},
          ],
        },
        {
          'group': 'inputs',
          'keys': [
            {'key': 'hdmi_2', 'label': 'HDMI 2', 'keycode': 244},
          ],
        },
        {
          'group': 'system',
          'keys': [
            {'key': 'zoom', 'label': 'Zoom', 'keycode': 168},
          ],
        },
      ],
    },
    'tv.apps': {
      'ok': true,
      'apps': [
        {
          'package': 'com.netflix.ninja',
          'label': 'Netflix',
          'versionName': '9.1',
          'versionCode': 91,
          'system': false,
          'enabled': true,
          'launchable': true,
        },
        {
          'package': 'com.sonyliv',
          'label': 'SonyLIV',
          'versionName': '6.0',
          'system': false,
          'enabled': false,
          'launchable': true,
        },
      ],
    },
    'tv.settings.catalog': {
      'ok': true,
      'categories': [
        {
          'category': 'Display and sound',
          'settings': [
            {
              'namespace': 'system',
              'key': 'screen_brightness',
              'label': 'Brightness',
              'type': 'int',
              'min': 0,
              'max': 255,
              'step': 1,
              'description': 'Backlight level',
              'value': '128',
            },
          ],
        },
        {
          'category': 'Network',
          'settings': [
            {
              'namespace': 'global',
              'key': 'private_dns_mode',
              'label': 'Private DNS',
              'type': 'enum',
              'options': [
                {'value': 'off', 'label': 'Off'},
                {'value': 'opportunistic', 'label': 'Automatic'},
                {'value': 'hostname', 'label': 'Hostname'},
              ],
              'description': 'Encrypted DNS for the TV',
              'value': 'hostname',
            },
            {
              'namespace': 'global',
              'key': 'private_dns_specifier',
              'label': 'Private DNS hostname',
              'type': 'string',
              'value': 'dns.example',
            },
          ],
        },
        {
          'category': 'Developer',
          'settings': [
            {
              'namespace': 'global',
              'key': 'stay_on_while_plugged_in',
              'label': 'Stay awake',
              'type': 'bool',
              'description': 'Keep the screen on while plugged in',
              'value': '0',
            },
          ],
        },
      ],
    },
    'tv.settings.list': {
      'ok': true,
      'settings': [
        {'namespace': 'system', 'key': 'screen_off_timeout', 'value': '600000'},
        {'namespace': 'system', 'key': 'volume_music', 'value': '30'},
      ],
    },
  });
  engine.answerers['tv.files.list'] = (args) => switch (args['path']) {
    '/sdcard' => {
      'ok': true,
      'path': '/sdcard',
      'entries': [
        {
          'name': 'notes.txt',
          'type': 'file',
          'size': 2048,
          'mode': '644',
          'modified': 1762560000,
        },
        {'name': 'Download', 'type': 'dir', 'size': 4096, 'mode': '755'},
        {'name': 'Movies', 'type': 'dir', 'size': 4096, 'mode': '755'},
      ],
    },
    '/sdcard/Download' => {
      'ok': true,
      'path': '/sdcard/Download',
      'entries': [
        {'name': 'show.mkv', 'type': 'file', 'size': 3 * 1024 * 1024},
      ],
    },
    final path => {'ok': true, 'path': path, 'entries': const []},
  };
  return engine;
}

/// Opens the TV control centre from the TV's card, on [tab].
Future<void> openTvTab(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(const ValueKey('tv-open-$tvId')));
  await tester.pumpAndSettle();
  if (tab != 'Remote') {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('tv-tabs')),
        matching: find.text(tab),
      ),
    );
    await tester.pumpAndSettle();
  }
}

/// The args of every call of [command].
List<Map<String, Object?>> argsOf(FakeEngine engine, String command) => [
  for (final c in engine.callsOf(command)) c.$2,
];

Future<FakePhoneFiles> pumpTv(
  WidgetTester tester,
  FakeEngine engine, {
  FakePhoneFiles? files,
}) async {
  final phone = files ?? FakePhoneFiles();
  await pumpApp(
    tester,
    engine,
    overrides: [
      phoneFilesProvider.overrideWithValue(phone),
      tvPollProvider.overrideWithValue(const Duration(hours: 1)),
    ],
  );
  return phone;
}
