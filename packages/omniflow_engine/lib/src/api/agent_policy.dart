import 'dart:convert';
import 'dart:io';

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
const agentReadCommands = {
  'agent.access',
  'agent.describe',
  'ask.pending',
  'automation.dry_run',
  'automation.get',
  'automation.list',
  'automation.log',
  'automation.templates',
  'board.describe',
  'board.ports',
  'device.discover',
  'device.get',
  'device.history',
  'device.list',
  'driver.list',
  'driver.validate',
  'engine.status',
  'flow.cards',
  'flow.dryRun',
  'flow.get',
  'flow.list',
  'flow.log',
  'flow.validate',
  'link.list',
  'link.options',
  'room.list',
  'rule.tokens',
  'scene.list',
  'tag.list',
  'thing.next',
  'tv.app.permissions',
  'tv.apps',
  'tv.capabilityRisk',
  'tv.files.list',
  'tv.files.stat',
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
const agentSetupCommands = {
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
  'tag.remove',
  'tag.save',
  'thing.add',
  'thing.configure',
  'tv.input.swipe',
  'tv.input.tap',
  'tv.key',
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
};

/// Why each command no agent may send is the user's alone.
const agentUserOnly = {
  'agent.access.set': 'only the user decides what an agent may do',
  'automation.approve': 'approving a high-risk automation is the user check',
  'flow.approve': 'approving a high-risk automation is the user check',
  'device.pair': 'pairing needs someone at the device',
  'device.hostkey': 'trusting a host key is a security decision',
  'device.remove': 'removing a thing deletes its secrets and history',
  'secret.set': 'keys and passwords never pass through an agent',
  'web.secret.set': 'keys and passwords never pass through an agent',
  'driver.register':
      'use register_custom_driver_manifest, which refuses '
      'drivers that run host commands',
  'driver.approve': 'approving a driver an agent added is the user check',
  'tv.shell': 'a shell on the TV is the user\'s',
  'tv.install': 'installing apps is the user\'s',
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
  'zone.remove': 'removing a place deletes it with its history',
  'board.flash': 'writing firmware replaces what a board runs',
  'config.import':
      'restoring a backup replaces the home, and only you choose to',
};

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
/// not, for a `needs_user` reply.
String? agentRefusal(
  String command,
  Map<String, Object?> args,
  AgentAccess level,
) {
  if (agentUserOnly[command] case final why?) {
    return '$command is for the user only: $why';
  }
  if (command == 'tv.app') {
    if (level != AgentAccess.setup) return _needsSetup(command);
    return _agentTvAppActions.contains(args['action'])
        ? null
        : 'tv.app ${args['action']} is for the user only: it changes or '
              'removes the app';
  }
  if ((command == 'var.set' || command == 'var.remove') &&
      reservedVariable(args['name'] ?? args['var'])) {
    return '${args['name'] ?? args['var']} is the engine\'s own: it says '
        'where you are, and only your phone sets it';
  }
  if (agentReadCommands.contains(command)) return null;
  if (agentSetupCommands.contains(command)) {
    return level == AgentAccess.setup ? null : _needsSetup(command);
  }
  return '$command is not open to agents';
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
      'link.create' => {...args, 'trusted': false},
      'device.invoke' => {...args, 'allowPairing': false},
      _ when command.startsWith('tv.') || command == 'device.refresh' => {
        ...args,
        'allowPairing': false,
      },
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
