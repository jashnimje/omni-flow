import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../boards/firmware_sheet.dart';
import '../boards/usb_board.dart';
import '../design/design.dart';
import '../tags/tags_page.dart' show showAddTagSheet;
import 'add_by_hand_page.dart';
import 'add_phone_page.dart';
import 'driver_kinds.dart';
import 'guided_steps_page.dart';
import '../devices/weather_page.dart' show AddWeatherRow;

/// Add covers the whole screen, tab bar included, as a task you finish or
/// close with its cross.
Future<void> openAddThing(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const AddPage(),
      ),
    );

/// 6.1 Add: the engine looks on every method at once. While it looks a
/// banner says so; then what it found, with Add, the ones already added
/// greyed, and the ways to add by hand.
class AddPage extends ConsumerStatefulWidget {
  const AddPage({super.key});

  @override
  ConsumerState<AddPage> createState() => _AddPageState();
}

class _AddPageState extends ConsumerState<AddPage> {
  AddFind? _find;
  ApiFailure? _failure;
  var _looking = true;
  Map<String, Json> _drivers = const {};
  var _driversRead = false;
  String? _adding;

  @override
  void initState() {
    super.initState();
    unawaited(_discover());
  }

  EngineApi get _quiet => EngineApi(ref.read(engineClientProvider));

  /// Each found thing's place in the list, the order it was first seen,
  /// so a later look never moves what is already shown.
  final _seen = <String, int>{};

  static String _keyOf(FoundThing f) =>
      '${f.candidate['id'] ?? f.candidate['stableId'] ?? f.candidate['host'] ?? f.driverName}';

  Future<void> _discover() async {
    setState(() {
      _looking = true;
      _failure = null;
    });
    // The drivers decide the add-by-hand list, so they come first and on
    // their own: that list is whole from the start and never grows above
    // what is already shown when the slower look finishes.
    if (!_driversRead) {
      final drivers = await _quiet.drivers();
      if (!mounted) return;
      setState(() {
        _driversRead = drivers.ok;
        _drivers = {for (final d in drivers.or(const [])) '${d['id']}': d};
      });
    }
    final find = await _quiet.discover();
    if (!mounted) return;
    setState(() {
      _looking = false;
      _find = find.value ?? _find;
      _failure = find.failure;
      for (final f in _find?.found ?? const <FoundThing>[]) {
        _seen.putIfAbsent(_keyOf(f), () => _seen.length);
      }
    });
  }

  /// [things] in the order they were first seen.
  List<FoundThing> _stable(Iterable<FoundThing> things) => things.toList()
    ..sort((a, b) => (_seen[_keyOf(a)] ?? 0).compareTo(_seen[_keyOf(b)] ?? 0));

  String _knownName(String id) =>
      '${ref.read(devicesProvider).value?.where((d) => d['id'] == id).firstOrNull?['name'] ?? id}';

  Future<void> _add(FoundThing f) async {
    final c = f.candidate;
    final key = '${c['id'] ?? c['host']}';
    setState(() => _adding = key);
    await addAndFollow(
      context,
      ref,
      c,
      name: '${c['name'] ?? f.driverName}',
      always: true,
    );
    if (!mounted) return;
    setState(() => _adding = null);
    unawaited(_discover());
  }

  Future<void> _byHand({String? driver, String? kind}) => Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          builder: (_) => AddByHandPage(driver: driver, kind: kind),
        ),
      );

  /// What a find needs before it works: pairing, a secret, or nothing.
  String? _needs(Json c) => switch (_drivers['${c['driver']}']?['pairing']) {
    null => null,
    'secret' => 'needs a key',
    _ => 'needs pairing',
  };

  IconData _icon(FoundThing f) => OmniIcons.forCategory(
    f.category ?? '${_drivers['${f.candidate['driver']}']?['category']}',
  );

  /// The Wi-Fi the phone is on, as the phone thing reports it.
  String? _wifi(List<Json> devices) {
    for (final d in devices) {
      if (d['driver'] != 'phone') continue;
      final ssid = DeviceView(d).state['wifi_ssid'];
      if (ssid is String && ssid.isNotEmpty) return ssid;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final wifi = _wifi(ref.watch(devicesProvider).value ?? const []);
    final find = _find;
    final kindsReady = _driversRead || !_looking;
    final found = _stable([
      for (final f in find?.found ?? const <FoundThing>[])
        if (f.candidate['knownAs'] == null) f,
    ]);
    final known = _stable([
      for (final f in find?.found ?? const <FoundThing>[])
        if (f.candidate['knownAs'] != null) f,
    ]);
    final place = find?.manual.where((m) => m['driver'] == 'place').firstOrNull;
    final others = [
      for (final m in find?.manual ?? const <Json>[])
        if (m['driver'] != 'place' && m['driver'] != 'nfc_tag')
          plainDriverName('${m['name'] ?? m['driver']}'),
    ];
    return ListPage.custom(
      title: 'Add',
      close: true,
      actions: [
        OmniIconAction(
          key: const ValueKey('add-rescan'),
          icon: OmniIcons.retry,
          label: 'Look again',
          onPressed: _looking ? null : _discover,
        ),
      ],
      body: (context, padding) => RefreshIndicator(
        onRefresh: _discover,
        child: ListView(
          key: const ValueKey('add-page'),
          padding: padding,
          children: [
            if (_looking)
              OmniBanner.info(
                key: const ValueKey('add-looking'),
                'Looking for lights, plugs, TVs and boards on '
                '${wifi ?? 'your Wi-Fi'}…',
              )
            else if (_failure case final f?)
              OmniBanner.error(
                key: const ValueKey('add-error'),
                'Looking for things did not finish: ${f.message}',
                actionLabel: 'Look again',
                onAction: _discover,
              ),
            OmniSectionHeader(
              'Found nearby',
              trailingText: find == null ? null : '${found.length}',
            ),
            if (find == null && _looking)
              const OmniListSkeleton(rows: 3, label: 'Looking nearby')
            else if (found.isEmpty)
              OmniEmptyState(
                key: const ValueKey('add-nothing'),
                icon: OmniIcons.search,
                title: _looking ? 'Still looking' : 'Nothing new found',
                message: _looking
                    ? null
                    : 'Check it is switched on and on the same Wi-Fi as this '
                          'phone, or add it by hand.',
                compact: true,
              )
            else
              for (final (i, f) in found.indexed)
                OmniListRow(
                  key: ValueKey('candidate-$i'),
                  icon: _icon(f),
                  title: '${f.candidate['name'] ?? f.driverName}',
                  subtitle: [
                    ?(f.candidate['host'] ?? f.candidate['stableId'])
                        as String?,
                    ?_needs(f.candidate),
                  ].join(' · '),
                  trailing:
                      _adding == '${f.candidate['id'] ?? f.candidate['host']}'
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          key: ValueKey('candidate-add-$i'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(72, OmniSpace.target),
                          ),
                          onPressed: _adding == null ? () => _add(f) : null,
                          child: const Text('Add'),
                        ),
                  onTap: _adding == null ? () => _add(f) : null,
                ),
            const OmniSectionHeader('Add by hand'),
            // The common kinds as big tiles, in plain words. Another phone
            // has its own steps. Until the drivers are read the kinds wait
            // as one skeleton, so none is inserted above another later.
            if (!kindsReady)
              const OmniListSkeleton(
                key: ValueKey('add-kinds-loading'),
                rows: 3,
                label: 'Loading the kinds',
              )
            else
              AddKindGrid(
                tiles: [
                  for (final k in addKinds)
                    if (k.id == 'phones' || _drivers.values.any(k.has))
                      AddKindTile(
                        key: ValueKey(
                          k.id == 'phones'
                              ? 'add-another-phone'
                              : 'manual-kind-${k.id}',
                        ),
                        icon: k.icon,
                        title: k.title,
                        onTap: () => k.id == 'phones'
                            ? openAddPhone(context)
                            : _byHand(kind: k.id),
                      ),
                  AddKindTile(
                    key: const ValueKey('manual-tag'),
                    icon: OmniIcons.tag,
                    title: 'NFC tag',
                    onTap: () => showAddTagSheet(context),
                  ),
                  AddKindTile(
                    key: const ValueKey('manual-place'),
                    icon: OmniIcons.place,
                    title: 'A place',
                    onTap: () =>
                        _byHand(driver: '${place?['driver'] ?? 'place'}'),
                  ),
                ],
              ),
            const SizedBox(height: OmniSpace.md),
            if (known.isNotEmpty)
              OmniDisclosure(
                key: const ValueKey('add-known'),
                icon: OmniIcons.check,
                title: 'Already added',
                summary: known.length == 1
                    ? '1 found that you have'
                    : '${known.length} found that you have',
                children: [
                  for (final (i, f) in known.indexed)
                    Opacity(
                      opacity: 0.6,
                      child: OmniListRow(
                        key: ValueKey('known-$i'),
                        icon: _icon(f),
                        title: _knownName('${f.candidate['knownAs']}'),
                        subtitle: '${f.candidate['host'] ?? ''}',
                        value: 'added',
                        valueColor: OmniPalette.of(context).muted,
                        divider: i < known.length - 1,
                      ),
                    ),
                ],
              ),
            OmniDisclosure(
              key: const ValueKey('add-more-ways'),
              icon: OmniIcons.more,
              title: 'More ways to add',
              summary: 'Weather, boards on USB, firmware, every kind',
              children: [
                const AddWeatherRow(),
                OmniListRow(
                  key: const ValueKey('manual-usb-board'),
                  icon: OmniIcons.board,
                  title: 'A board on USB',
                  subtitle:
                      'ESP32, ESP8266, Pico W or Uno, plugged into this phone',
                  chevron: true,
                  onTap: () => showUsbBoardSheet(context),
                ),
                OmniListRow(
                  key: const ValueKey('manual-firmware'),
                  icon: OmniIcons.developer,
                  title: 'Install firmware on a board',
                  subtitle: 'OmniFlow, or your own .bin or .hex, over USB',
                  chevron: true,
                  onTap: () => showFirmwareSheet(context),
                ),
                OmniListRow(
                  key: const ValueKey('add-by-driver'),
                  icon: OmniIcons.more,
                  title: 'More kinds',
                  subtitle: others.isEmpty
                      ? 'Every kind, by its full name'
                      : '${others.take(4).join(', ')}…',
                  chevron: true,
                  divider: false,
                  onTap: _byHand,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The kinds to add by hand as big tiles, two across, one across from
/// 130% text so a name never wraps into a sliver.
class AddKindGrid extends StatelessWidget {
  const AddKindGrid({super.key, required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(10) >= 13;
    final columns = large ? 1 : 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tiles.length; i += columns)
          Padding(
            padding: const EdgeInsets.only(bottom: OmniSpace.md),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < columns; c++) ...[
                    if (c > 0) const SizedBox(width: OmniSpace.md),
                    Expanded(
                      child: i + c < tiles.length
                          ? tiles[i + c]
                          : const SizedBox(),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One big kind tile: an icon and a plain name, and a tap opens its steps.
class AddKindTile extends StatelessWidget {
  const AddKindTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final radius = BorderRadius.circular(OmniRadii.tile);
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      child: Material(
        color: palette.card,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 104),
            child: Padding(
              padding: const EdgeInsets.all(OmniSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OmniIconBox(icon: icon, size: 40),
                  const SizedBox(height: OmniSpace.md),
                  Text(
                    title,
                    style: OmniText.bodyStrong.copyWith(color: palette.text),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
