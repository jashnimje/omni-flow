import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/engine_calls.dart';
import '../state/providers.dart';
import 'device_sheets.dart';
import 'setup_page.dart';

Future<void> openAddThing(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const AddThingPage()));

/// Adds anything: the engine looks on every method at once and lists what
/// it found. Picking one adds it and follows the steps the engine says come
/// next (pair, secret, configure) until it is done.
class AddThingPage extends ConsumerStatefulWidget {
  const AddThingPage({super.key});

  @override
  ConsumerState<AddThingPage> createState() => _AddThingPageState();
}

class _AddThingPageState extends ConsumerState<AddThingPage> {
  List<({String driverName, Json candidate})>? _candidates;
  List<Json> _manual = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  Future<void> _discover() async {
    setState(() {
      _candidates = null;
      _error = null;
    });
    final result = await ref
        .read(engineClientProvider)
        .call(EngineCalls.thingAdd, EngineCalls.discoverArgs);
    if (!mounted) return;
    setState(() {
      if (result['ok'] == true) {
        _candidates = EngineCalls.candidatesOf(result);
        _manual = EngineCalls.manualOf(result);
      } else {
        _candidates = const [];
        _error = errorMessage(result);
      }
    });
  }

  Future<void> _pick(Json candidate) async {
    final named = await askName(
      context,
      title: 'Add ${candidate['name'] ?? 'it'}',
      name: '${candidate['name'] ?? ''}',
      room: candidate['room'] as String?,
    );
    if (named == null || !mounted) return;
    await addAndFollow(
      context,
      ref,
      candidate,
      name: named.name,
      room: named.room,
      replaceRoute: true,
    );
  }

  /// The add sheet, with [driver] picked when given, in place of this page.
  void _byHand(String? driver) {
    final navigator = Navigator.of(context)..pop();
    showAddDevice(navigator.context, driver: driver);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates;
    return Scaffold(
      appBar: AppBar(title: const Text('Add')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (candidates == null)
            const ListTile(
              leading: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Looking on the network, USB and boards'),
            )
          else ...[
            if (_error != null)
              Text(_error!, key: const ValueKey('add-error'))
            else if (candidates.isEmpty)
              const Text(
                'Nothing new found. Check it is on and on the same Wi-Fi, '
                'or pick its driver by hand.',
              ),
            for (final (i, (:driverName, candidate: c)) in candidates.indexed)
              ListTile(
                key: ValueKey('candidate-$i'),
                leading: Icon(
                  c['knownAs'] == null
                      ? Icons.add_circle_outline
                      : Icons.check_circle_outline,
                ),
                title: Text('${c['name'] ?? c['driver']}'),
                subtitle: Text(
                  [
                    driverName,
                    if (c['host'] != null) '${c['host']}',
                    if (c['method'] != null) 'via ${c['method']}',
                    if (c['knownAs'] != null)
                      'Already added as ${c['knownAs']}',
                  ].where((s) => s.isNotEmpty).join(' - '),
                ),
                enabled: c['knownAs'] == null,
                onTap: () => _pick(c),
              ),
            if (_manual.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 4),
                child: Text('Nothing to look for, add these by hand'),
              ),
              for (final m in _manual)
                ListTile(
                  key: ValueKey('manual-${m['driver']}'),
                  leading: Icon(
                    m['virtual'] == true
                        ? Icons.bubble_chart_outlined
                        : Icons.edit_note,
                  ),
                  title: Text('${m['name'] ?? m['driver']}'),
                  subtitle: Text(
                    m['virtual'] == true
                        ? 'No address needed'
                        : 'Type its address',
                  ),
                  onTap: () => _byHand('${m['driver']}'),
                ),
            ],
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('add-rescan'),
                onPressed: candidates == null ? null : _discover,
                icon: const Icon(Icons.refresh),
                label: const Text('Look again'),
              ),
              TextButton(
                key: const ValueKey('add-by-driver'),
                onPressed: () => _byHand(null),
                child: const Text('Pick a driver by hand'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks for a name and a room.
Future<({String name, String? room})?> askName(
  BuildContext context, {
  required String title,
  String name = '',
  String? room,
  bool withRoom = true,
}) {
  final nameField = TextEditingController(text: name);
  final roomField = TextEditingController(text: room ?? '');
  return showDialog<({String name, String? room})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('add-name'),
              controller: nameField,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            if (withRoom)
              TextField(
                key: const ValueKey('add-room'),
                controller: roomField,
                decoration: const InputDecoration(labelText: 'Room (optional)'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('add-confirm'),
            onPressed: nameField.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop((
                    name: nameField.text.trim(),
                    room: roomField.text.trim().isEmpty
                        ? null
                        : roomField.text.trim(),
                  )),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

/// Adds [candidate] and, when the engine says a step comes next, opens the
/// setup page on it. [replaceRoute] swaps the current page for it.
Future<void> addAndFollow(
  BuildContext context,
  WidgetRef ref,
  Json candidate, {
  required String name,
  String? room,
  bool replaceRoute = false,
}) async {
  final navigator = Navigator.of(context);
  final devices = ref.read(devicesProvider.notifier);
  final result = await callEngine(
    ref,
    EngineCalls.thingAdd,
    EngineCalls.addCandidateArgs(candidate, name: name, room: room),
  );
  if (result['ok'] != true) return;
  await devices.refresh();
  await followNext(navigator, result, name: name, replaceRoute: replaceRoute);
}

/// After a thing.add or device.add, opens the setup page on the step the
/// engine says comes next, or says it was added when nothing is left,
/// optional keys included. [id] is the id the add was given, when the
/// reply does not carry one. [replaceRoute] swaps the current page for it.
Future<void> followNext(
  NavigatorState navigator,
  Json added, {
  required String name,
  String? id,
  bool replaceRoute = false,
}) async {
  final thingId = id ?? EngineCalls.thingIdOf(added);
  final next = EngineCalls.nextOf(added);
  if (thingId == null ||
      (next.kind == NextKind.done && next.optional.isEmpty)) {
    showMessage('Added $name');
    if (replaceRoute) navigator.pop();
    return;
  }
  final route = MaterialPageRoute<void>(
    builder: (_) => SetupPage(id: thingId, name: name, first: next),
  );
  await (replaceRoute
      ? navigator.pushReplacement(route)
      : navigator.push(route));
}
