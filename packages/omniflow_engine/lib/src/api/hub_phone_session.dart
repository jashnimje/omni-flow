import 'android_names.dart';
import 'agent_policy.dart' show agentReadCommands, agentSetupCommands;

/// The first line `omni hub attach --phone NAME` writes on the phone socket,
/// before any line from the phone: `{"session": "phone", "phone": NAME}`.
const phoneSessionKey = 'session';
const phoneSessionValue = 'phone';

/// A phone's name is also the id of its phone thing on the hub.
final phoneNamePattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// Who a phone session on the hub is: the phone named in its
/// `authorized_keys` line, and that phone's person when it has one.
class PhoneSession {
  const PhoneSession(this.phone, {this.person});

  final String phone;
  final String? person;
}

/// What a phone session may not do, with why. A phone key reaches the hub
/// from the network, so nothing it sends may run a program, read or write a
/// file on the Mac, or change who may reach the hub. Those stay with the
/// Mac's own CLI.
const _phoneDenied = {
  'driver.register': 'a new driver can run programs on the Mac',
  'driver.approve': 'approving a driver lets it run programs on the Mac',
  'config.import': 'restoring a backup replaces the whole home',
  'device.hostkey': 'trusting an SSH host key is for the Mac',
  'tv.shell': 'a shell on a TV or phone is for the Mac',
  'tv.install': 'it reads an app file on the Mac',
  'tv.helper.install': 'it reads an app file on the Mac',
  'tv.files.download': 'it writes files on the Mac',
  'tv.files.upload': 'it reads files on the Mac',
  'tv.app.backup': 'it writes files on the Mac',
  'board.flash': 'writing firmware runs a program on the Mac',
  'hub.start': 'starting and stopping the hub is for the Mac',
  'hub.stop': 'starting and stopping the hub is for the Mac',
  'agent.access.set': 'what agents on the Mac may do is set on the Mac',
  'agent.call': 'agents use the Mac, not a phone key',
};

/// Commands a phone needs beyond what agents get: its own readings, answers
/// and replies (checked against the session), and the user's own steps the
/// app offers, such as pairing, approving and removing.
const _phoneExtra = {
  'ask.answer',
  'automation.approve',
  'automation.restore',
  'board.periph',
  'board.provision',
  'board.setup',
  'command.interpret',
  'device.add',
  'device.pair',
  'device.remove',
  'flow.approve',
  'flow.enable',
  'flow.remove',
  'flow.run',
  'nfc.scanned',
  'presence.set',
  'secret.set',
  'tag.write_payload',
  'web.secret.set',
  'zone.remove',
  'android.pair',
  'tv.app',
  'tv.app.permission',
  'tv.cache.trim',
  'tv.files.copy',
  'tv.files.delete',
  'tv.files.mkdir',
  'tv.files.move',
  'tv.files.rename',
  'tv.power',
  'tv.settings.delete',
  'tv.settings.put',
  // The TV remote and the screen of a paired phone, which the user drives
  // from the app whatever an agent may do.
  'tv.input.swipe',
  'tv.input.tap',
  'tv.key',
  'tv.notifications',
  'tv.pointer',
  'tv.pointer.click',
  'tv.record.start',
  'tv.record.status',
  'tv.record.stop',
  'tv.screenshot',
  'tv.text',
  'tv.volume',
  // Removed automations and the phone's backup settings.
  'automation.removed',
  'automation.unremove',
  'backup.auto.get',
  'backup.auto.set',
  // Removing a house, which the app offers in its house list.
  'house.remove',
};

final _denied = withAndroidNames(_phoneDenied);
final _extra = withAndroidCommandNames(_phoneExtra);

/// The commands named here, for a test that every one is in the engine.
Set<String> get phoneSessionNamedCommands => {..._denied.keys, ..._extra};

/// Whether [command] is a reading a phone sends about itself, which the hub
/// tags with the session's phone.
bool isPhoneReading(String command) =>
    command.startsWith('phone.') ||
    command.startsWith('sensor.') ||
    command == 'nfc.scanned';

/// Null when a phone session may send [command] by name, else why not. The
/// arguments of `device.add`, `thing.add`, `thing.configure` and
/// `secret.set` are checked separately against the thing they touch.
String? phoneCommandRefusal(String command) {
  if (_denied[command] case final why?) return _onTheMac(command, why);
  if (isPhoneReading(command) ||
      _extra.contains(command) ||
      agentReadCommands.contains(command) ||
      agentSetupCommands.contains(command)) {
    return null;
  }
  return _onTheMac(command, 'it is not one a phone needs');
}

String _onTheMac(String command, String why) =>
    'A phone cannot send $command to the hub: $why. Run it on the Mac '
    'with omni.';

/// The driver and host a `device.add` or `thing.add` would use, read the
/// way `thing.add` merges a found candidate under its own arguments.
({String? driver, String? host}) addTarget(Map<String, Object?> args) {
  final candidate = args['candidate'];
  final base = candidate is Map
      ? (candidate['add'] is Map ? candidate['add'] as Map : candidate)
      : const {};
  final driver = args['driver'] ?? base['driver'];
  final host = args['host'] ?? base['host'];
  return (
    driver: driver is String ? driver : null,
    host: host is String ? host : null,
  );
}

/// A USB serial port path, the only host path a phone may give a serial
/// device or a board.
final _serialPort = RegExp(r'^/dev/(cu|tty)[A-Za-z0-9._-]+$');

/// Hosts that mean this Mac itself.
const _thisMac = {'local', 'localhost', '127.0.0.1', '::1'};

/// Null when a phone may add a thing of [transport] at [host], else why not.
/// An `exec` driver runs programs (on the Mac when its host is local, over
/// SSH otherwise), and a serial path that is not a port would be read and
/// written as a file.
String? phoneAddRefusal(String? transport, String? host) {
  if (transport == 'exec') {
    return 'A phone cannot add a thing that runs programs. Add it on the Mac '
        'with omni.';
  }
  if (host == null) return null;
  if (_thisMac.contains(host.trim().toLowerCase())) {
    return 'A phone cannot add a thing on the Mac itself. Add it on the Mac '
        'with omni.';
  }
  final path = host.startsWith('/');
  final port = transport == 'serial' || transport == 'omniflow';
  if (path && !port) return '$host is a path on the Mac, not an address';
  if ((path || transport == 'serial') && !_serialPort.hasMatch(host)) {
    return '$host is not a USB serial port such as /dev/cu.usbserial-1';
  }
  return null;
}

/// Why a phone may not change a thing whose driver uses [transport]: an
/// `exec` thing's settings and keys decide what it runs and where.
String? phoneChangeRefusal(String? transport) => transport == 'exec'
    ? 'A phone cannot change a thing that runs programs. Change it on the '
          'Mac with omni.'
    : null;

/// A command a phone session sent, as the hub runs it, or why it does not.
typedef PhoneAdmission = ({String? refusal, Map<String, Object?> args});

/// Runs one core API command on the hub, as [OmniEngine.handle] does.
typedef HubHandle = Future<Map<String, Object?>> Function(
  String command,
  Map<String, Object?> args,
);

/// Checks each command of one phone session: by name, then against the
/// thing it touches, then against who the session is. The phone, its
/// person, its asks and its action replies come from the session, never
/// from what the phone sends.
class PhoneGate {
  PhoneGate(this.session, this._handle);

  final PhoneSession session;
  final HubHandle _handle;

  Future<PhoneAdmission> admit(
    String command,
    Map<String, Object?> args,
  ) async {
    PhoneAdmission no(String why) => (refusal: why, args: args);
    if (phoneCommandRefusal(command) case final why?) return no(why);
    final named = args['phone'];
    if (named != null && named != session.phone) {
      return no(
        'This is ${session.phone}, so it cannot send for $named. Each phone '
        'speaks only for itself.',
      );
    }
    var sent = args;
    if (isPhoneReading(command) || command == 'phone.actionDone') {
      sent = {...args, 'phone': session.phone};
    }
    switch (command) {
      case 'presence.set':
        final person = args['person'];
        if (person != null && person != session.person) {
          return no(
            '${session.phone} belongs to '
            '${session.person ?? 'no one on the hub'}, so it cannot say '
            'where $person is.',
          );
        }
        if (session.person case final p?) sent = {...sent, 'person': p};
      case 'ask.answer':
        final to = await _askPerson(args['askId']);
        if (to != null && to != session.person) {
          return no(
            'That question is for $to, so only their phone answers it.',
          );
        }
      case 'device.add' || 'thing.add':
        final target = addTarget(args);
        if (target.driver == null && target.host == null) break;
        final transport = target.driver == null
            ? null
            : await _transportOf(target.driver!);
        if (phoneAddRefusal(transport, target.host) case final why?) {
          return no(why);
        }
      case 'thing.configure' || 'secret.set':
        final id = args['id'] ?? args['deviceId'];
        if (id is! String) break;
        final got = await _handle('device.get', {'id': id});
        final driver = (got['device'] as Map?)?['driver'];
        if (driver is! String) break;
        if (phoneChangeRefusal(await _transportOf(driver)) case final why?) {
          return no(why);
        }
    }
    return (refusal: null, args: sent);
  }

  /// The person the open ask [askId] is for, or null when it is for anyone
  /// or not open (the engine then says so itself).
  Future<String?> _askPerson(Object? askId) async {
    final pending = await _handle('ask.pending', const {});
    final asks = pending['asks'];
    if (asks is! List) return null;
    for (final a in asks) {
      if (a is Map && a['askId'] == askId) {
        final person = a['person'];
        return person is String && person.isNotEmpty ? person : null;
      }
    }
    return null;
  }

  Future<String?> _transportOf(String driver) async {
    final listed = await _handle('driver.list', const {});
    final drivers = listed['drivers'];
    if (drivers is! List) return null;
    for (final d in drivers) {
      if (d is Map && d['id'] == driver) {
        final transport = d['transport'];
        return transport is String ? transport : null;
      }
    }
    return null;
  }
}

/// Picks which hub events go to one phone session: its own phone's events,
/// its person's asks and notifications, and the home-wide rest. Another
/// phone's readings, notification words, requests and asks stay on the hub.
class PhoneEventFilter {
  PhoneEventFilter(this.session, this._isPhoneThing);

  final PhoneSession session;

  /// Whether a thing id is a phone thing on the hub.
  final bool Function(String id) _isPhoneThing;

  final _asks = <String>{};

  bool _otherPhone(Object? id) =>
      id is String && id != session.phone && _isPhoneThing(id);

  bool _forThisPerson(Object? to) =>
      to is! String || to.isEmpty || to == session.person;

  /// Whether [event] goes to this session.
  bool allows(Map<String, Object?> event) {
    switch (event['event']) {
      case 'packet.captured':
        return false;
      case 'ask.request':
        if (!_forThisPerson(event['person'])) return false;
        if (event['askId'] case final String id) _asks.add(id);
        return true;
      case 'ask.closed':
        return _asks.remove(event['askId']);
      case 'flow.announce':
        return _forThisPerson(event['person'] ?? event['to']) &&
            !_otherPhone(event['thing']);
      case 'phone.action':
        return event['phone'] == session.phone;
      case 'wifi.changed':
        return event['phone'] == session.phone;
      case 'thing.event':
        return !_otherPhone(event['thing']);
      case 'device.stateChanged':
        final device = event['device'];
        if (device is Map) {
          return device['driver'] != 'phone' || device['id'] == session.phone;
        }
        return true;
    }
    final device = event['device'];
    if (device is String && _otherPhone(device)) return false;
    final phone = event['phone'];
    if (phone is String && phone != session.phone) return false;
    return true;
  }
}
