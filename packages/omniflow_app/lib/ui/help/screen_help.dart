import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart' show Json;
import '../design/design.dart';
import '../home/home_data.dart' show driversProvider;
import 'help_sheet.dart';
import 'setting_help.dart';

/// The four main screens, each with a short help sheet.
enum HelpScreen { home, automations, devices, settings }

/// What each main screen is for, in plain words.
const screenHelp = <HelpScreen, ({String title, List<HelpSection> sections})>{
  HelpScreen.home: (
    title: 'About Home',
    sections: [
      (
        heading: 'What you see',
        body:
            'Your devices, room by room. Tap a tile to open it, tap its icon '
            'to switch it, and hold it for quick controls. The line under the '
            'greeting says whether you are home and the mode the house is in.',
      ),
      (
        heading: 'Modes',
        body:
            'A mode such as Home, Away or Night says what the house is doing. '
            'Automations can run only in some modes, and you can change the '
            'mode yourself from the mode chip.',
      ),
      (
        heading: 'Scenes and run buttons',
        body:
            'A scene sets several things at once, like Movie: lamp at 20 '
            'percent and the TV on. Automations you run by hand show here as '
            'buttons too.',
      ),
      (
        heading: 'Where it runs',
        body:
            'Everything runs on this phone, on your Wi-Fi, without a cloud. '
            'A small notification shows it is running.',
      ),
    ],
  ),
  HelpScreen.automations: (
    title: 'About automations',
    sections: [
      (
        heading: 'Automations',
        body:
            'An automation does something by itself when something happens: '
            'when I get home, turn on the lamp. It reads as a sentence: when, '
            'only if, then.',
      ),
      (
        heading: 'When, only if, then',
        body:
            'When is what starts it: a time, sunset, arriving home, a button '
            'or a sensor. Only if is a check that must be true, like only '
            'after dark. Then is what it does, step by step.',
      ),
      (
        heading: 'Quick links',
        body:
            'A link ties one thing to another with no conditions, like this '
            'button toggles that light.',
      ),
      (
        heading: 'Keep',
        body:
            'A keep step holds a device a certain way while something is '
            'true, like keep the fan on while it is above 28 degrees, and '
            'lets go when it stops being true.',
      ),
      (
        heading: 'High risk and approval',
        body:
            'Some steps are high risk, such as a web request or a command on '
            'a computer. An automation with one that an agent made waits for '
            'your review before it can run.',
      ),
      (
        heading: 'Next and last run',
        body:
            'Each card shows when it last ran, and for a time or sun '
            'automation, when it runs next. Removed automations stay in '
            'Recently removed for a while, so you can put them back.',
      ),
    ],
  ),
  HelpScreen.devices: (
    title: 'About devices',
    sections: [
      (
        heading: 'Devices',
        body:
            'Everything OmniFlow can control or read: lights, plugs, TVs, '
            'speakers, sensors, boards and other computers. Each sits in a '
            'room.',
      ),
      (
        heading: 'Adding one',
        body:
            'Tap Add. OmniFlow looks on your Wi-Fi first. If your device is '
            'not found, add it by hand with its address.',
      ),
      (
        heading: 'Keys and pairing',
        body:
            'Some devices need a key or a pairing step before OmniFlow can '
            'talk to them: a TV asks you to press Allow, a Hue bridge wants '
            'its button pressed, and a Tuya or Wipro plug needs its local '
            'key. Keys stay on this phone only.',
      ),
      (
        heading: 'Offline',
        body:
            'A device that stops answering shows as offline. Check it has '
            'power and is on the same Wi-Fi as the phone.',
      ),
    ],
  ),
  HelpScreen.settings: (
    title: 'About settings',
    sections: [
      (
        heading: 'Your home',
        body:
            'Places and people say where home is and who lives there. A '
            'place knows you are there from its Wi-Fi or a Bluetooth beacon. '
            'Rooms group your devices. Things you change less often sit '
            'in More settings at the end.',
      ),
      (
        heading: 'Setting up',
        body:
            'Set up your home walks through who you are, where home is and '
            'how the phone knows you are home. You can stop and come back to '
            'it here.',
      ),
      (
        heading: 'Hub',
        body:
            'A hub is a computer at home, such as a Raspberry Pi, that runs '
            'your home all the time. With one, automations keep running when '
            'your phone is away. Find it in More settings, Home runs on.',
      ),
      (
        heading: 'Backup',
        body:
            'A backup holds your devices, rooms, places and automations. '
            'Keys stay on the phone, so after a restore each device that had '
            'one asks for it again.',
      ),
      (
        heading: 'Agents',
        body:
            'An agent such as an AI assistant can read your home, and with '
            'your say-so set things up. It can never store a key, pair or '
            'remove a device. Choose what it can do in More settings, For '
            'developers.',
      ),
    ],
  ),
};

/// Opens the help sheet of [screen].
Future<void> showScreenHelp(BuildContext context, HelpScreen screen) {
  final help = screenHelp[screen]!;
  return showHelpSheet(
    context,
    key: ValueKey('help-sheet-${screen.name}'),
    title: help.title,
    sections: help.sections,
    extra: [if (screen == HelpScreen.devices) const _KeyGuides()],
  );
}

/// The "?" in a main screen's header.
class ScreenHelpButton extends StatelessWidget {
  const ScreenHelpButton(this.screen, {super.key});

  final HelpScreen screen;

  @override
  Widget build(BuildContext context) => OmniIconAction(
    key: ValueKey('help-${screen.name}'),
    icon: Symbols.help_rounded,
    label: 'Help',
    onPressed: () => showScreenHelp(context, screen),
  );
}

/// Each driver's keys that have help: where to find a Tuya local key, a
/// Home Assistant token, an SSH key. Read from the driver manifests.
class _KeyGuides extends ConsumerWidget {
  const _KeyGuides();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(driversProvider).value ?? const <String, Json>{};
    final guides = [
      for (final d in drivers.values)
        for (final s in (d['settings'] as List? ?? const []).whereType<Map>())
          if (s['secret'] == true && s['help'] is String)
            (driver: d, setting: s),
    ];
    if (guides.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: OmniSpace.sm),
          child: OmniSectionHeader('Where to find a key'),
        ),
        for (final g in guides)
          OmniListRow(
            key: ValueKey('key-guide-${g.driver['id']}-${g.setting['key']}'),
            icon: OmniIcons.permissions,
            title: '${g.setting['label'] ?? g.setting['key']}',
            subtitle: '${g.driver['name'] ?? g.driver['id']}',
            chevron: true,
            onTap: () => showSettingHelp(
              context,
              label: '${g.setting['label'] ?? g.setting['key']}',
              help: g.setting['help'] as String,
            ),
          ),
      ],
    );
  }
}
