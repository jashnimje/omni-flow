import 'dart:convert';
import 'dart:io';

import '../devices/adb/adb_commands.dart' show adbPhoneAgentKeys;
import 'android_names.dart';
import 'device_history.dart' show changedByAgent;

/// How much an AI agent may do through MCP. The user picks it in the app or
/// with `omni agent access`, and no agent can change it.
enum AgentAccess {
  /// Read everything, try rules out, and save automations that wait for the
  /// user where they are high risk. The default.
  read,

  /// Also set the home up end to end: find and add things, configure them,
  /// name them and put them in rooms, places, tags, scenes, and save,
  /// enable, run and remove automations.
  setup;

  static AgentAccess? parse(Object? name) =>
      values.where((a) => a.name == name).firstOrNull;
}

/// The commands an agent may send at [AgentAccess.read]: they only read or
/// simulate.
const _readCommands = {
  'agent.access',
  'agent.describe',
  'android.find',
  'ask.pending',
  'automation.dry_run',
  'automation.get',
  'automation.list',
  'automation.log',
  'automation.templates',
  // Why an automation did not run, which ones fight over a device, and
  // its earlier versions.
  'automation.conflicts',
  'automation.skips',
  'automation.versions',
  // The recently removed automations, which can be put back for 30 days.
  'automation.removed',
  // An automation as a diagram, with a run's path lit.
  'automation.diagram',
  'board.describe',
  'board.ports',
  'device.discover',
  'device.get',
  'device.history',
  'device.list',
  'driver.list',
  'driver.validate',
  // Energy use per plug and its price.
  'energy.price',
  'energy.summary',
  'engine.status',
  'flow.dryRun',
  'flow.get',
  'flow.list',
  'flow.log',
  'flow.validate',
  'home.stats',
  'hub.clients',
  'hub.discover',
  // The houses a home is split into, with how much each holds.
  'house.list',
  'link.list',
  'link.options',
  'room.list',
  'room.state',
  'rule.tokens',
  // A sentence read into a rule, never saved, and habits offered as rules.
  'rule.parse',
  // An unsaved rule's words and what it still needs, never saved.
  'rule.words',
  'suggest.list',
  'scene.list',
  'tag.list',
  'thing.next',
  'tv.app.permissions',
  'tv.apps',
  'tv.capabilityRisk',
  'tv.files.list',
  'tv.files.stat',
  'tv.helper.status',
  'tv.keys',
  'tv.processes',
  'tv.settings.catalog',
  'tv.settings.get',
  'tv.settings.list',
  'tv.state',
  'tv.system',
  'var.list',
  'zone.list',
};

/// What [AgentAccess.setup] adds: setting the home up. Automations an agent
/// saves are still untrusted, so a high-risk one waits for the user.
const _setupCommands = {
  'automation.enable',
  'automation.remove',
  'automation.run',
  'automation.save',
  'board.pins',
  // config.export shows the whole home and home.location where it is, so
  // neither is open at read.
  'config.export',
  // A high-risk capability (a host command, a TV setting) is still
  // refused: agent.call checks the capability first.
  'device.invoke',
  'device.organize',
  'device.refresh',
  // The sun curve and away plan follow home's location and when people are
  // out, so like home.location they need setup, reads included.
  'awaylight.get',
  'awaylight.preview',
  'awaylight.set',
  'energy.price.set',
  'sunlight.apply',
  'sunlight.get',
  'sunlight.set',
  'weather.add',
  'weather.refresh',
  'flow.save',
  'home.location',
  'home.location.set',
  'link.create',
  'link.remove',
  'room.order',
  'room.remove',
  'room.save',
  'scene.remove',
  'scene.run',
  'scene.save',
  // Hiding a suggestion changes what the person is offered.
  'suggest.dismiss',
  'tag.remove',
  'tag.save',
  'thing.add',
  'thing.configure',
  'tv.input.swipe',
  'tv.input.tap',
  'tv.key',
  'tv.notifications',
  'tv.pointer',
  'tv.pointer.click',
  'tv.record.start',
  'tv.record.status',
  'tv.record.stop',
  // A screenshot shows what is on the TV, which may be private, so it
  // needs the same allowance as pressing its keys.
  'tv.screenshot',
  'tv.text',
  'tv.volume',
  'var.remove',
  'var.set',
  'zone.save',
  // The home helpers: the house mode, named timers, the built-in alerts, a
  // room as one light (high-risk capabilities are never sent to a room)
  // and a scene of how things are now, saved untrusted.
  'alerts.get',
  'alerts.set',
  'home.mode',
  'home.mode.set',
  'room.invoke',
  'scene.capture',
  'timer.cancel',
  'timer.list',
  'timer.pause',
  'timer.resume',
  'timer.start',
  // Putting a removed automation back saves it as it was, and the daily
  // backup's folder and switch, since a backup holds the whole home.
  'automation.unremove',
  'backup.auto.get',
  'backup.auto.set',
  // Adding a house and naming it, as setting the home up does. Removing one
  // is the user's.
  'house.add',
  'house.rename',
};

/// Why each command no agent may send is the user's alone.
const _userOnly = {
  'agent.access.set': 'only the user decides what an agent may do',
  'automation.approve': 'approving a high-risk automation is the user check',
  'automation.restore':
      'going back to an earlier version replaces the automation, and only '
      'you choose to',
  'flow.approve': 'approving a high-risk automation is the user check',
  'device.pair': 'pairing needs someone at the device',
  'android.pair':
      'pairing needs someone at the phone, and the code never passes '
      'through an agent',
  'device.hostkey': 'trusting a host key is a security decision',
  'device.remove': 'removing a thing deletes its secrets and history',
  'secret.set': 'keys and passwords never pass through an agent',
  'web.secret.set': 'keys and passwords never pass through an agent',
  'wiz.import':
      'it stores your WiZ home key, and keys never pass through an agent',
  'driver.register':
      'use register_custom_driver_manifest, which refuses '
      'drivers that run host commands',
  'driver.approve': 'approving a driver an agent added is the user check',
  'tv.shell': 'a shell on the TV is the user\'s',
  'tv.install': 'installing apps is the user\'s',
  'tv.helper.install': 'installing apps is the user\'s',
  'tv.settings.put': 'raw TV setting writes are the user\'s',
  'tv.settings.delete': 'raw TV setting writes are the user\'s',
  'tv.files.delete': 'deleting files is the user\'s',
  'tv.app.permission': 'granting or revoking app permissions is the user\'s',
  'tv.app.backup': 'it writes files on this computer',
  'tv.cache.trim': 'clearing every app cache is the user\'s',
  'tv.power': 'restarting or shutting down the TV is the user\'s',
  'presence.set': 'saying where the user is would fire automations falsely',
  'ask.answer': 'an answer stands for the person, so only they give it',
  'phone.app': 'what the phone reports would fire automations falsely',
  'phone.notification': 'what the phone reports would fire automations falsely',
  'phone.bluetooth': 'what the phone reports would fire automations falsely',
  'phone.screen': 'what the phone reports would fire automations falsely',
  'phone.dnd': 'what the phone reports would fire automations falsely',
  'phone.actionDone': 'only the phone that was asked answers for itself',
  'phone.ready': 'only the phone itself says it is connected',
  'phone.alarm': 'what the phone reports would fire automations falsely',
  'phone.call': 'what the phone reports would fire automations falsely',
  'phone.media': 'what the phone reports would fire automations falsely',
  'phone.calendar': 'what the phone reports would fire automations falsely',
  'phone.shake': 'what the phone reports would fire automations falsely',
  'phone.faceDown': 'what the phone reports would fire automations falsely',
  'phone.headphones': 'what the phone reports would fire automations falsely',
  'phone.boot': 'what the phone reports would fire automations falsely',
  'phone.package': 'what the phone reports would fire automations falsely',
  'zone.remove': 'removing a place deletes it with its history',
  'board.flash': 'writing firmware replaces what a board runs',
  'device.move':
      'pointing a device at a new address decides where its commands go',
  'house.remove':
      'removing a house deletes its rooms and settings, and only you '
      'choose to',
  'config.import':
      'restoring a backup replaces the home, and only you choose to',
};

/// Each `tv.*` command is also an `android.*` one, and both names get the
/// same entry here.
final agentReadCommands = withAndroidCommandNames(_readCommands);
final agentSetupCommands = withAndroidCommandNames(_setupCommands);
final agentUserOnly = withAndroidNames(_userOnly);

/// On another person's phone (an ADB device in the phone category) the
/// screen is theirs: tapping, typing and a screenshot together are the
/// whole phone, so these are the user's even at setup. On a TV they stay
/// at setup.
const _phoneScreenOnly = {
  'tv.input.tap': 'tapping another person\'s phone is the user\'s',
  'tv.input.swipe': 'swiping on another person\'s phone is the user\'s',
  'tv.text': 'typing on another person\'s phone is the user\'s',
  'tv.screenshot': 'what is on another person\'s screen is theirs',
  'tv.record.start': 'what is on another person\'s screen is theirs',
  'tv.record.stop': 'what is on another person\'s screen is theirs',
  'tv.notifications':
      'another person\'s notifications are theirs, so opening the shade is '
      'the user\'s',
  'tv.pointer': 'pointing on another person\'s phone is the user\'s',
  'tv.pointer.click': 'clicking on another person\'s phone is the user\'s',
};

/// What an agent at read sees on a TV, but on another person's phone only
/// at setup: its files, its apps, what runs and its settings, secure ones
/// included.
const _phoneSetupReads = {
  'tv.app.permissions',
  'tv.apps',
  'tv.files.list',
  'tv.files.stat',
  'tv.processes',
  'tv.settings.get',
  'tv.settings.list',
};

/// The `tv.*` and `android.*` commands that are the user's on a phone, with
/// why, and those that need setup there.
final agentPhoneUserOnly = withAndroidNames(_phoneScreenOnly);
final agentPhoneSetupReads = withAndroidCommandNames(_phoneSetupReads);

/// What the phone itself reports that says where its person has been and
/// what they do: the Wi-Fi network and access point (a location trail),
/// the app on screen and the Bluetooth devices nearby. Like home's
/// location, an agent sees them only at setup.
const agentPrivateStateKeys = {
  'wifi_ssid',
  'wifi_bssid',
  'app_on_screen',
  'bluetooth_devices',
};

/// The phone events whose details (the app, the Bluetooth device, what is
/// playing) are habits, so an agent at read sees only that one happened.
const agentPrivateEventKeys = {
  'app_opened',
  'app_closed',
  'app_installed',
  'app_updated',
  'bluetooth_connected',
  'bluetooth_disconnected',
  'media_started',
  'media_stopped',
};

/// [result] as an agent at [level] may see it: at read, the
/// [agentPrivateStateKeys] leave every state map, their history entries
/// are dropped, and the payload of a [agentPrivateEventKeys] event is
/// emptied, wherever they sit (a thing, a run log, a diagram).
Object? agentReadView(Object? result, AgentAccess level) =>
    level == AgentAccess.setup ? result : _withoutPrivate(result);

Object? _withoutPrivate(Object? value) {
  if (value is List) {
    return [
      for (final item in value)
        if (!_isPrivateHistoryEntry(item)) _withoutPrivate(item),
    ];
  }
  if (value is! Map) return value;
  final privateEvent = agentPrivateEventKeys.contains(value['key']);
  return {
    for (final e in value.entries)
      if (e.key == 'state' && e.value is Map)
        e.key: {
          for (final s in (e.value as Map).entries)
            if (!agentPrivateStateKeys.contains(s.key))
              s.key: _withoutPrivate(s.value),
        }
      else if (privateEvent && e.key == 'payload' && e.value is Map)
        e.key: const <String, Object?>{}
      else if (!agentPrivateVariables.contains(e.key))
        e.key: _withoutPrivate(e.value),
  };
}

/// The engine's own globals that carry a [agentPrivateStateKeys] reading:
/// the Wi-Fi network the phone is on now.
const agentPrivateVariables = {'WifiSsid', r'$WifiSsid'};

/// A `device.history` entry, `{at, key, value, by?}`, of a private key.
bool _isPrivateHistoryEntry(Object? item) =>
    item is Map &&
    agentPrivateStateKeys.contains(item['key']) &&
    item.containsKey('at') &&
    item.containsKey('value');

/// The level an agent needs to watch the packets the engine sends and
/// receives: they carry what devices report (MQTT and Home Assistant
/// payloads), so read is not enough.
const agentPacketsLevel = AgentAccess.setup;

/// Null when an agent at [level] may watch packets, else why not.
String? agentPacketsRefusal(AgentAccess level) => level == agentPacketsLevel
    ? null
    : 'watching packets shows what every device reports, which needs the '
          'user to allow setup: in the app, Settings, Claude and agents, What '
          'agents can do, choose Set up everything (or run omni agent allow '
          'setup)';

/// Globals the engine keeps for itself (presence and Wi-Fi, which rules
/// trigger on), which no agent may set or remove. Names come without `$`.
bool reservedVariable(Object? name) {
  if (name is! String) return false;
  final bare = name.startsWith(r'$') ? name.substring(1) : name;
  return bare.startsWith('_') ||
      bare.startsWith('Zone_') ||
      bare == 'WifiSsid' ||
      bare == 'HomeWifiConnected';
}

/// TV app actions an agent may take: the rest change or remove the app.
const _agentTvAppActions = {'open', 'stop', 'info'};

/// Null when an agent at [level] may send [command] with [args], else why
/// not, for a `needs_user` reply. [onPhone] says the device [args] names is
/// another person's phone over ADB rather than a TV.
/// The commands whose `moveTo` moves a thing or an automation to another
/// house.
const houseMoveCommands = {
  'device.organize',
  'automation.save',
  'flow.save',
  'scene.save',
  'scene.capture',
  'link.create',
};

String? agentRefusal(
  String command,
  Map<String, Object?> args,
  AgentAccess level, {
  bool onPhone = false,
}) {
  if (agentUserOnly[command] case final why?) {
    return '$command is for the user only: $why';
  }
  if (onPhone) {
    if (agentPhoneUserOnly[command] case final why?) {
      return '$command is for the user only: $why';
    }
    if (tvNameOf(command) == 'tv.key' && !_phoneKeyOpen(args)) {
      return '$command is for the user only on a phone, apart from the '
          'power, volume and media keys: other keys type or move around '
          'another person\'s screen';
    }
    if (agentPhoneSetupReads.contains(command) && level != AgentAccess.setup) {
      return _needsSetup(command);
    }
  }
  if (tvNameOf(command) == 'tv.app') {
    if (level != AgentAccess.setup) return _needsSetup(command);
    return _agentTvAppActions.contains(args['action'])
        ? null
        : '$command ${args['action']} is for the user only: it changes or '
              'removes the app';
  }
  if ((command == 'var.set' || command == 'var.remove') &&
      reservedVariable(args['name'] ?? args['var'])) {
    return '${args['name'] ?? args['var']} is the engine\'s own: it says '
        'where you are, and only your phone sets it';
  }
  if (houseMoveCommands.contains(command) && args['moveTo'] != null) {
    return 'moving a thing or an automation to another house is for the '
        'user only: it can turn off the automations of the old house';
  }
  if (agentReadCommands.contains(command)) return null;
  if (agentSetupCommands.contains(command)) {
    return level == AgentAccess.setup ? null : _needsSetup(command);
  }
  return '$command is not open to agents';
}

/// Whether a `tv.key` on a phone presses a key by name that neither types
/// nor moves around the screen. A raw key code could be any key.
bool _phoneKeyOpen(Map<String, Object?> args) {
  final key = args['key'];
  return args['keycode'] == null &&
      key is String &&
      adbPhoneAgentKeys.contains(key);
}

String _needsSetup(String command) =>
    '$command sets the home up, which needs the user to allow it: in the app, '
    'Settings, Claude and agents, What agents can do, choose Set up '
    'everything (or run omni agent allow setup)';

/// The discovery methods an agent may use: none opens a USB port.
const agentFindMethods = ['udp_broadcast', 'mdns', 'tuya_broadcast', 'hello'];

/// Arguments an agent never chooses: its saves are untrusted, so a
/// high-risk automation waits for the user, and nothing it runs may start a
/// pairing prompt.
Map<String, Object?> agentArgs(String command, Map<String, Object?> args) =>
    switch (command) {
      'automation.save' ||
      'flow.save' ||
      'scene.save' ||
      'scene.capture' ||
      'link.create' => {...args, 'trusted': false},
      'device.invoke' => {...args, 'allowPairing': false, 'by': changedByAgent},
      // A room sent by an agent is the agent's change, not a habit.
      'room.invoke' => {...args, 'by': changedByAgent},
      _
          when tvNameOf(command).startsWith(tvCommandPrefix) ||
              command == 'device.refresh' =>
        {...args, 'allowPairing': false},
      // Opening a USB port resets an ESP32 or an Uno, so an agent looks on
      // the network only.
      'device.discover' => {...args, 'serial': false},
      'thing.add' when args['candidate'] == null && args['driver'] == null => {
        ...args,
        'methods': agentFindMethods,
      },
      // An agent runs an automation as it is: the inputs a trigger gives
      // are not its to choose.
      'automation.run' || 'scene.run' => {
        for (final e in args.entries)
          if (e.key != 'msg' && e.key != 'trigger') e.key: e.value,
      },
      _ => args,
    };

/// The access level, kept in `agent.json` next to the database, where only
/// the engine's own process can write.
class AgentAccessStore {
  AgentAccessStore(Directory home) : _file = File('${home.path}/agent.json');

  final File _file;

  Future<AgentAccess> read() async {
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map) {
        return AgentAccess.parse(json['access']) ?? AgentAccess.read;
      }
    } on FileSystemException {
      // Never set: the default.
    } on FormatException {
      // A damaged file falls back to the safest level.
    }
    return AgentAccess.read;
  }

  Future<void> write(AgentAccess access) async {
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode({'access': access.name}), flush: true);
    await temp.rename(_file.path);
  }
}
