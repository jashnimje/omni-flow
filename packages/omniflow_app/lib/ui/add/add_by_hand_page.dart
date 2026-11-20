import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show thingIdFor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../help/setting_help.dart' show settingHelpLine;
import 'driver_kinds.dart';
import 'guided_steps_page.dart';
import 'room_field.dart';
import 'wiz_import_page.dart';

/// Where to find a device's IP address, under the field that takes it.
const ipAddressHelp =
    'Four numbers with dots. Find it in the device\'s own app or your '
    'router\'s app, in the list of connected devices.';

/// A device id from its name, the engine's way for any name, Latin or not.
String deviceIdFor(String name) => thingIdFor(name);

/// Adds a thing by its driver: pick the driver, look for it or type its
/// address (a place or a person takes none), name it and put it in a room,
/// then follow the steps the engine says come next.
class AddByHandPage extends ConsumerStatefulWidget {
  const AddByHandPage({super.key, this.driver, this.kind});

  /// The driver picked when the page opens.
  final String? driver;

  /// The kind of thing whose drivers the page opens on, such as lights.
  final String? kind;

  @override
  ConsumerState<AddByHandPage> createState() => _AddByHandPageState();
}

class _AddByHandPageState extends ConsumerState<AddByHandPage> {
  Reply<List<Json>>? _drivers;
  late String? _driver = widget.driver;

  /// The kind picked on the first list (Lights, TVs), whose drivers show.
  late String? _kind = widget.kind;
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

  /// The optional secrets typed behind Add by IP address (a WiZ home key).
  final _secrets = <String, TextEditingController>{};

  EngineApi get _quiet => EngineApi(ref.read(engineClientProvider));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final drivers = await _quiet.drivers();
    if (!mounted) return;
    setState(() => _drivers = drivers);
    final kind = _pickedKind;
    if (_driver == null && kind != null) {
      final of = drivers.or(const []).where(kind.has).toList();
      if (of.length == 1) _pickDriver(of.single);
    }
  }

  int _driversOf(AddKind kind) =>
      (_drivers?.value ?? const <Json>[]).where(kind.has).length;

  /// Whether Back leaves the page rather than stepping back a list.
  bool get _atStart {
    if (widget.driver != null) return true;
    final opened = addKinds.where((k) => k.id == widget.kind).firstOrNull;
    if (_driver == null) return _kind == widget.kind;
    return opened != null && _kind == opened.id && _driversOf(opened) < 2;
  }

  @override
  void dispose() {
    _search.dispose();
    _host.dispose();
    _name.dispose();
    for (final c in [..._settings.values, ..._secrets.values]) {
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

  /// A driver whose lights come in from their own app (WiZ) puts the
  /// address behind Add by IP address, with its optional key beside it.
  bool get _imports => _picked?['importFrom'] != null;

  List<Json> get _secretFields => [
    for (final s in (_picked?['settings'] as List? ?? const []))
      if (s is Map && s['secret'] == true) Map<String, Object?>.from(s),
  ];

  TextEditingController _secret(String key) =>
      _secrets.putIfAbsent(key, TextEditingController.new);

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
    if (_imports) {
      for (final f in _secretFields) {
        final value = _secret('${f['key']}').text.trim();
        if (value.isEmpty) continue;
        await _quiet.setSecret(id, '${f['key']}', value);
      }
    }
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
    final kind = _pickedKind;
    return PopScope(
      canPop: _atStart,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: driver == null
          ? _driverList(kind?.title ?? 'Add by hand')
          : _form(driver),
    );
  }

  /// Back steps out one list at a time: from the form to the kind's list
  /// (or the first list, for a kind with one driver), then to the first.
  void _back() {
    final kind = _pickedKind;
    setState(() {
      if (_driver != null) {
        _driver = null;
        if (kind != null && _driversOf(kind) < 2) _kind = null;
      } else {
        _kind = null;
      }
    });
  }

  bool get _ready =>
      _driver != null &&
      (_virtual || _host.text.trim().isNotEmpty) &&
      _name.text.trim().isNotEmpty &&
      !_adding;

  void _pickDriver(Json d) => setState(() {
    _driver = '${d['id']}';
    _found = null;
    _stableId = null;
  });

  /// The drivers of [kind], or the kind's one driver straight away.
  void _openKind(AddKind kind, List<Json> drivers) {
    final of = drivers.where(kind.has).toList();
    if (of.length == 1) {
      setState(() => _kind = kind.id);
      _pickDriver(of.single);
      return;
    }
    setState(() => _kind = kind.id);
  }

  AddKind? get _pickedKind => addKinds.where((k) => k.id == _kind).firstOrNull;

  Widget _driverList(String title) {
    final drivers = _drivers;
    final all = drivers?.value ?? const <Json>[];
    final query = _search.text.trim().toLowerCase();
    final kind = _pickedKind;
    final list = [
      for (final d in all)
        if ((kind == null || kind.has(d)) &&
            (query.isEmpty ||
                '${d['name']}'.toLowerCase().contains(query) ||
                '${d['id']}'.contains(query)))
          d,
    ]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    final kinds = [
      for (final k in addKinds)
        if (all.any(k.has)) k,
    ];
    // The common kinds first, in plain words. Every driver, with its
    // protocol in its name, sits under More kinds.
    final showKinds = kind == null && query.isEmpty && kinds.isNotEmpty;
    return ListPage(
      key: const ValueKey('add-drivers'),
      title: title,
      search: kind == null
          ? TextField(
              key: const ValueKey('add-driver-search'),
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(OmniIcons.search),
                hintText: 'Hue, Home Assistant, Tasmota, Mac…',
              ),
              onChanged: (_) => setState(() {}),
            )
          : null,
      state: OmniLoad.flags(
        loading: drivers == null,
        error: drivers == null || drivers.ok
            ? null
            : 'The kinds of device could not be read. '
                  '${drivers.failure!.message}',
        onRetry: _load,
      ),
      children: (context) => [
        if (showKinds) ...[
          const OmniSectionHeader('What is it?'),
          for (final k in kinds)
            OmniListRow(
              key: ValueKey('kind-${k.id}'),
              icon: k.icon,
              title: k.title,
              subtitle: k.subtitle,
              chevron: true,
              onTap: () => _openKind(k, all),
            ),
        ],
        // A kind's list has its name as the page title already.
        if (kind == null)
          OmniSectionHeader(showKinds ? 'More kinds' : 'What is it?'),
        if (list.isEmpty)
          const OmniEmptyState(
            icon: OmniIcons.search,
            title: 'No driver matches',
            compact: true,
          )
        else
          for (final d in list)
            OmniListRow(
              key: ValueKey('driver-${d['id']}'),
              icon: _driverIcon(d),
              title: kind == null
                  ? '${d['name']}'
                  : plainDriverName('${d['name']}'),
              subtitle: d['transport'] == 'virtual'
                  ? 'No address needed'
                  : d['builtIn'] == false
                  ? 'Your driver'
                  : null,
              chevron: true,
              onTap: () => _pickDriver(d),
            ),
      ],
    );
  }

  Widget _hostField() => TextField(
    key: const ValueKey('add-host'),
    controller: _host,
    keyboardType: TextInputType.url,
    decoration: const InputDecoration(
      labelText: 'IP address on your Wi-Fi',
      hintText: '192.168.1.20',
      helperText: ipAddressHelp,
      helperMaxLines: 3,
    ),
    onChanged: (_) => setState(() => _stableId = null),
  );

  List<Widget> _secretInputs() => [
    for (final f in _secretFields) ...[
      const SizedBox(height: OmniSpace.sm),
      TextField(
        key: ValueKey('add-secret-${f['key']}'),
        controller: _secret('${f['key']}'),
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          label: Text('${f['label']} (optional)'),
          helper: settingHelpLine(
            settingKey: '${f['key']}',
            label: '${f['label']}',
            help: f['help'] as String?,
          ),
        ),
      ),
    ],
  ];

  Widget _form(Json driver) {
    final found = _found;
    final accent = OmniPalette.of(context).accent;
    return FormPage(
      key: const ValueKey('add-form'),
      title: 'Add ${plainDriverName('${driver['name']}')}',
      commitLabel: _adding ? 'Adding' : 'Add',
      commitKey: const ValueKey('add-save'),
      onCommit: _ready ? _add : null,
      missing: _adding
          ? null
          : _virtual || _host.text.trim().isNotEmpty
          ? 'Give it a name first.'
          : 'Look for it, or type its IP address, first.',
      banners: [
        if (_failure case final f?)
          OmniBanner.error(
            key: const ValueKey('add-refused'),
            [f.message, for (final i in f.issues) i.message].join('. '),
          ),
      ],
      children: (context) => [
        if (_imports)
          OmniListRow(
            key: const ValueKey('add-from-wiz-app'),
            icon: OmniIcons.light,
            title: 'Easiest: from the WiZ app',
            subtitle: 'Every WiZ light at once, with its name, room and key',
            chevron: true,
            onTap: () => openWizImport(context),
          ),
        OmniListRow(
          key: const ValueKey('add-driver'),
          icon: _driverIcon(driver),
          title: plainDriverName('${driver['name']}'),
          subtitle: 'Tap to pick another kind',
          chevron: true,
          onTap: _back,
        ),
        if (!_virtual) ...[
          const SizedBox(height: OmniSpace.sm),
          OmniButton(
            key: const ValueKey('add-scan'),
            label: _scanning ? 'Looking' : 'Look for it on your Wi-Fi',
            icon: OmniIcons.search,
            onPressed: _scanning ? null : _scan,
          ),
          if (found != null && found.isEmpty)
            const OmniEmptyState(
              icon: OmniIcons.search,
              title: 'Nothing found',
              message: 'Type its IP address below.',
              compact: true,
            ),
          for (final f in found ?? const <Json>[])
            OmniListRow(
              key: ValueKey('found-${f['host']}'),
              icon: _host.text == f['host'] ? OmniIcons.check : OmniIcons.wifi,
              iconForeground: _host.text == f['host'] ? accent : null,
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
          if (_imports)
            OmniDisclosure(
              key: const ValueKey('add-by-ip'),
              icon: OmniIcons.wifi,
              title: 'Add by IP address',
              summary: 'Only when it is not found and not in its own app',
              initiallyOpen: _host.text.isNotEmpty,
              children: [_hostField(), ..._secretInputs()],
            )
          else
            _hostField(),
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
            // A long label wraps, so a setting never reads cut off.
            decoration: InputDecoration(
              label: Text('${f['label']}', maxLines: 3, softWrap: true),
              helper: settingHelpLine(
                settingKey: '${f['key']}',
                label: '${f['label']}',
                help: f['help'] as String?,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

IconData _driverIcon(Json driver) =>
    OmniIcons.forManifestIcon(driver['icon'] as String?) ??
    OmniIcons.forCategory(driver['category'] as String?);
