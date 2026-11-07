import '../manifest/capability.dart';
import '../manifest/driver_manifest.dart';

/// What the command bar understood: a core API call to make, or text for the
/// AI architect.
class Interpretation {
  const Interpretation.call(this.command, this.args, this.summary)
    : askText = null;
  const Interpretation.ask(String text)
    : command = null,
      args = const {},
      summary = 'Ask the architect',
      askText = text;

  final String? command;
  final Map<String, Object?> args;
  final String summary;
  final String? askText;

  Map<String, Object?> toJson() => command == null
      ? {'kind': 'ask', 'text': askText, 'summary': summary}
      : {'kind': 'call', 'command': command, 'args': args, 'summary': summary};
}

class CommandDevice {
  const CommandDevice(this.id, this.name, this.manifest);

  final String id;
  final String name;
  final DriverManifest manifest;
}

class CommandFlow {
  const CommandFlow(this.id, this.name);

  final String id;
  final String name;
}

final _percent = RegExp(r'^(\d{1,3})\s*%$');
final _kelvin = RegExp(r'^(\d{4,5})\s*k$', caseSensitive: false);
final _hex = RegExp(r'^#?([0-9a-f]{6})$', caseSensitive: false);
final _number = RegExp(r'^-?\d+(\.\d+)?$');

/// Reads one command-bar line. Understood forms:
///
/// - `run <flow>` runs a flow's manual triggers
/// - `<device> on`, `<device> off`
/// - `<device> 50%` sets the first level capability
/// - `<device> 3000k` sets colour temperature
/// - `<device> #ff8800` sets colour
/// - `<device> <capability> [value]` runs any capability by id
///
/// A device or flow matches by id or by name, ignoring case, and the longest
/// match wins. Anything else goes to the architect.
Interpretation interpretCommand(
  String text,
  List<CommandDevice> devices,
  List<CommandFlow> flows,
) {
  final line = text.trim().replaceFirst(RegExp(r'^>\s*'), '');
  if (line.isEmpty) return Interpretation.ask(text);
  final lower = line.toLowerCase();

  if (lower.startsWith('run ')) {
    final target = lower.substring(4).trim();
    final flow = flows
        .where(
          (f) => f.id.toLowerCase() == target || f.name.toLowerCase() == target,
        )
        .firstOrNull;
    if (flow != null) {
      return Interpretation.call('flow.run', {
        'id': flow.id,
      }, 'Run ${flow.name}');
    }
  }

  CommandDevice? device;
  var matched = 0;
  var rest = '';
  for (final d in devices) {
    for (final key in {d.id.toLowerCase(), d.name.toLowerCase()}) {
      final hit = lower == key || lower.startsWith('$key ');
      if (hit && key.length > matched) {
        device = d;
        matched = key.length;
        rest = line.substring(key.length).trim();
      }
    }
  }
  if (device == null) return Interpretation.ask(text);
  final caps = device.manifest.capabilities;
  CapabilitySpec? ofType(CapabilityType t) =>
      caps.where((c) => c.type == t).firstOrNull;
  Interpretation invoke(
    CapabilitySpec c,
    Map<String, Object?> params,
    String what,
  ) => Interpretation.call('device.invoke', {
    'id': device!.id,
    'capability': c.id,
    'params': params,
  }, '${device.name}: $what');

  final value = rest.toLowerCase();
  final toggle = ofType(CapabilityType.toggle);
  if ((value == 'on' || value == 'off') && toggle != null) {
    return invoke(toggle, {'value': value == 'on'}, value);
  }
  final pct = _percent.firstMatch(value);
  final level = ofType(CapabilityType.level);
  if (pct != null && level != null) {
    return invoke(level, {
      'value': int.parse(pct.group(1)!),
    }, '${pct.group(1)}%');
  }
  final k = _kelvin.firstMatch(value);
  final temp = ofType(CapabilityType.colorTemp);
  if (k != null && temp != null) {
    return invoke(temp, {'value': int.parse(k.group(1)!)}, '${k.group(1)} K');
  }
  final hex = _hex.firstMatch(value);
  final rgb = ofType(CapabilityType.colorRgb);
  if (hex != null && rgb != null) {
    final v = int.parse(hex.group(1)!, radix: 16);
    return invoke(rgb, {
      'r': v >> 16 & 0xFF,
      'g': v >> 8 & 0xFF,
      'b': v & 0xFF,
    }, '#${hex.group(1)}');
  }

  final words = rest.split(RegExp(r'\s+'));
  final byId = caps.where((c) => c.id == words.first.toLowerCase()).firstOrNull;
  if (byId != null) {
    final arg = words.skip(1).join(' ');
    Object? parsed = arg;
    if (arg == 'true' || arg == 'on') parsed = true;
    if (arg == 'false' || arg == 'off') parsed = false;
    if (_number.hasMatch(arg)) parsed = num.parse(arg);
    return invoke(
      byId,
      arg.isEmpty ? const {} : {'value': parsed},
      arg.isEmpty ? byId.label : '${byId.label} $arg',
    );
  }
  return Interpretation.ask(text);
}
