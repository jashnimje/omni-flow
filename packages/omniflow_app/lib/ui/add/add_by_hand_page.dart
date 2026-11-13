import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show thingIdFor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'guided_steps_page.dart';
import 'room_field.dart';

/// A device id from its name, the engine's way for any name, Latin or not.
String deviceIdFor(String name) => thingIdFor(name);

/// Adds a thing by its driver: pick the driver, look for it or type its
/// address (a place or a person takes none), name it and put it in a room,
/// then follow the steps the engine says come next.
class AddByHandPage extends ConsumerStatefulWidget {
  const AddByHandPage({super.key, this.driver});

  /// The driver picked when the page opens.
  final String? driver;

  @override
  ConsumerState<AddByHandPage> createState() => _AddByHandPageState();
}

class _AddByHandPageState extends ConsumerState<AddByHandPage> {
  Reply<List<Json>>? _drivers;
  late String? _driver = widget.driver;
  List<Json>? _found;
  var _scanning = false;
  var _adding = false;
  String? _stableId;
  ApiFailure? _failure;
  final _search = TextEditingController();
  final _host = TextEditingController();
  final _name = TextEditingController();
  var _room = '';
  final _settings = <String, TextEditingController>{};

  EngineApi get _quiet => EngineApi(ref.read(engineClientProvider));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final drivers = await _quiet.drivers();
    if (mounted) setState(() => _drivers = drivers);
  }

  @override
  void dispose() {
    _search.dispose();
    _host.dispose();
    _name.dispose();
    for (final c in _settings.values) {
      c.dispose();
    }
    super.dispose();
  }

  Json? get _picked =>
      _drivers?.value?.where((d) => d['id'] == _driver).firstOrNull;

  bool get _virtual => _picked?['transport'] == 'virtual';

  /// People and places are not tiles, so they get no room.
  bool get _presence => _picked?['category'] == 'presence';

  /// The driver's settings typed as text: not secrets, which the guided
  /// steps take masked, not a board's pins, which the pin picker sets, and
  /// not a place's Wi-Fi, beacon and zone, which Places and people sets.
  List<Json> get _settingFields {
    final driver = _picked;
    if (driver == null || driver['board'] == true) return const [];
    if (driver['id'] == 'place') return const [];
    return [
      for (final s in (driver['settings'] as List? ?? const []))
        if (s is Map && s['secret'] != true) Map<String, Object?>.from(s),
    ];
  }

  TextEditingController _setting(String key) =>
      _settings.putIfAbsent(key, TextEditingController.new);

  Future<void> _scan() async {
    final driver = _driver;
    if (driver == null) return;
    setState(() {
      _scanning = true;
      _found = null;
    });
    final found = await _quiet.discoverDriver(driver);
    if (!mounted) return;
    // Known entries stay listed: a Hue bridge or Home Assistant instance has
    // one stable id for every device behind it.
    setState(() {
      _scanning = false;
      final list = found.or(const []);
      _found = [
        ...list.where((f) => f['knownAs'] == null),
        ...list.where((f) => f['knownAs'] != null),
      ];
    });
  }

  String _deviceName(String id) =>
      '${ref.read(devicesProvider).value?.where((d) => d['id'] == id).firstOrNull?['name'] ?? id}';

  void _pick(Json found) => setState(() {
    _host.text = '${found['host']}';
    _stableId = found['stableId'] as String?;
    if (_name.text.isEmpty && _stableId != null && found['knownAs'] == null) {
      _name.text = _stableId!;
    }
  });

  Future<void> _add() async {
    final navigator = Navigator.of(context);
    final devices = ref.read(devicesProvider.notifier);
    final name = _name.text.trim();
    final id = deviceIdFor(name);
    final settings = {
      for (final f in _settingFields)
        if (_setting('${f['key']}').text.trim() case final v when v.isNotEmpty)
          '${f['key']}': typedSetting(v),
    };
    setState(() {
      _adding = true;
      _failure = null;
    });
    // device.add, not thing.add: thing.add refuses a find that matches a
    // device by host or stable id, and a hub's lights and entities share
    // both.
    final reply = await _quiet.addDevice({
      'id': id,
      'name': name,
      'driver': _driver,
      if (!_virtual) 'host': _host.text.trim(),
      if (_room.isNotEmpty) 'room': _room,
      if (!_virtual) 'stableId': ?_stableId,
      if (settings.isNotEmpty) 'settings': settings,
    });
    if (!mounted) return;
    setState(() {
      _adding = false;
      _failure = reply.failure;
    });
    final added = reply.value;
    if (added == null) return;
    await devices.refresh();
    await followAdded(
      navigator,
      added,
      name: name,
      id: id,
      replaceRoute: true,
      always: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(devicesProvider);
    final driver = _picked;
    return OmniPage(
      title: driver == null ? 'Add by hand' : 'Add ${driver['name']}',
      bottom: driver == null
          ? null
          : OmniButton(
              key: const ValueKey('add-save'),
              label: _adding ? 'Adding' : 'Add',
              onPressed: _ready ? _add : null,
            ),
      body: driver == null ? _driverList() : _form(driver),
    );
  }

  bool get _ready =>
      _driver != null &&
      (_virtual || _host.text.trim().isNotEmpty) &&
      _name.text.trim().isNotEmpty &&
      !_adding;

  Widget _driverList() {
    final drivers = _drivers;
    final query = _search.text.trim().toLowerCase();
    final list = [
      for (final d in drivers?.value ?? const <Json>[])
        if (query.isEmpty ||
            '${d['name']}'.toLowerCase().contains(query) ||
            '${d['id']}'.contains(query))
          d,
    ]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return ListView(
      key: const ValueKey('add-drivers'),
      children: [
        TextField(
          key: const ValueKey('add-driver-search'),
          controller: _search,
          decoration: const InputDecoration(
            prefixIcon: Icon(OmniIcons.search),
            hintText: 'Hue, Home Assistant, Tasmota, Mac…',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const OmniSectionHeader('What is it?'),
        if (drivers == null)
          const Padding(
            padding: EdgeInsets.all(OmniSpace.xl),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          )
        else if (!drivers.ok)
          OmniBanner.error(
            'The kinds of device could not be read. ${drivers.failure!.message}',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else if (list.isEmpty)
          const OmniEmptyState(
            icon: OmniIcons.search,
            title: 'No driver matches',
          )
        else
          for (final d in list)
            OmniListRow(
              key: ValueKey('driver-${d['id']}'),
              icon: _driverIcon(d),
              title: '${d['name']}',
              subtitle: d['transport'] == 'virtual'
                  ? 'No address needed'
                  : d['builtIn'] == false
                  ? 'Your driver'
                  : null,
              chevron: true,
              onTap: () => setState(() {
                _driver = '${d['id']}';
                _found = null;
                _stableId = null;
              }),
            ),
      ],
    );
  }

  Widget _form(Json driver) {
    final found = _found;
    return ListView(
      key: const ValueKey('add-form'),
      children: [
        OmniListRow(
          key: const ValueKey('add-driver'),
          icon: _driverIcon(driver),
          title: '${driver['name']}',
          subtitle: 'Tap to pick another kind',
          chevron: true,
          onTap: () => setState(() => _driver = null),
        ),
        if (!_virtual) ...[
          const SizedBox(height: OmniSpace.sm),
          OmniButton.ghost(
            key: const ValueKey('add-scan'),
            label: _scanning ? 'Looking' : 'Look for it on the network',
            icon: OmniIcons.search,
            onPressed: _scanning ? null : _scan,
          ),
          if (found != null && found.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: OmniSpace.sm),
              child: Text(
                'Nothing found. Type its address below.',
                style: OmniText.caption,
              ),
            ),
          for (final f in found ?? const <Json>[])
            OmniListRow(
              key: ValueKey('found-${f['host']}'),
              icon: _host.text == f['host'] ? OmniIcons.check : OmniIcons.wifi,
              iconForeground: _host.text == f['host']
                  ? OmniColors.accent
                  : null,
              title: '${f['host']}',
              subtitle: switch ((f['stableId'], f['knownAs'])) {
                (_, final String known) =>
                  'Already used by ${_deviceName(known)}',
                (final String id, _) => id,
                _ => null,
              },
              onTap: () => _pick(f),
            ),
          const SizedBox(height: OmniSpace.sm),
          TextField(
            key: const ValueKey('add-host'),
            controller: _host,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Address',
              hintText: '192.168.1.40',
            ),
            onChanged: (_) => setState(() => _stableId = null),
          ),
        ],
        const SizedBox(height: OmniSpace.sm),
        TextField(
          key: const ValueKey('add-name'),
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: _virtual ? 'Home' : 'Desk lamp',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: OmniSpace.sm),
        if (!_presence)
          RoomField(value: _room, onChanged: (r) => setState(() => _room = r)),
        for (final f in _settingFields) ...[
          const SizedBox(height: OmniSpace.sm),
          TextField(
            key: ValueKey('add-setting-${f['key']}'),
            controller: _setting('${f['key']}'),
            decoration: InputDecoration(labelText: '${f['label']}'),
          ),
        ],
        if (_failure case final f?)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpace.sm),
            child: OmniBanner.error(
              key: const ValueKey('add-refused'),
              [f.message, for (final i in f.issues) i.message].join('. '),
            ),
          ),
      ],
    );
  }
}

IconData _driverIcon(Json driver) =>
    OmniIcons.forManifestIcon(driver['icon'] as String?) ??
    OmniIcons.forCategory(driver['category'] as String?);
