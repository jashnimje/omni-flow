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
import 'guided_steps_page.dart';

Future<void> openAddThing(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const AddPage()));

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
  String? _adding;

  @override
  void initState() {
    super.initState();
    unawaited(_discover());
  }

  EngineApi get _quiet => EngineApi(ref.read(engineClientProvider));

  Future<void> _discover() async {
    setState(() {
      _looking = true;
      _failure = null;
    });
    final drivers = await _quiet.drivers();
    final find = await _quiet.discover();
    if (!mounted) return;
    setState(() {
      _looking = false;
      _drivers = {for (final d in drivers.or(const [])) '${d['id']}': d};
      _find = find.value ?? _find;
      _failure = find.failure;
    });
  }

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

  Future<void> _byHand({String? driver}) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => AddByHandPage(driver: driver)),
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
    final found = [
      for (final f in find?.found ?? const <FoundThing>[])
        if (f.candidate['knownAs'] == null) f,
    ];
    final known = [
      for (final f in find?.found ?? const <FoundThing>[])
        if (f.candidate['knownAs'] != null) f,
    ];
    final place = find?.manual.where((m) => m['driver'] == 'place').firstOrNull;
    final others = [
      for (final m in find?.manual ?? const <Json>[])
        if (m['driver'] != 'place' && m['driver'] != 'nfc_tag')
          _shortName('${m['name'] ?? m['driver']}'),
    ];
    return OmniPage(
      title: 'Add',
      close: true,
      body: RefreshIndicator(
        onRefresh: _discover,
        child: ListView(
          key: const ValueKey('add-page'),
          padding: const EdgeInsets.only(bottom: OmniSpace.xl),
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
              for (var i = 0; i < 3; i++) const _RowSkeleton()
            else if (found.isEmpty)
              Padding(
                key: const ValueKey('add-nothing'),
                padding: const EdgeInsets.symmetric(vertical: OmniSpace.sm),
                child: Text(
                  _looking
                      ? 'Still looking'
                      : 'Nothing new found. Check it is switched on and on '
                            'the same Wi-Fi as this phone, or add it by hand.',
                  style: OmniText.caption,
                ),
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
                      : TextButton(
                          key: ValueKey('candidate-add-$i'),
                          onPressed: _adding == null ? () => _add(f) : null,
                          child: const Text('Add'),
                        ),
                  onTap: _adding == null ? () => _add(f) : null,
                ),
            if (known.isNotEmpty) ...[
              const OmniSectionHeader('Already added'),
              for (final (i, f) in known.indexed)
                Opacity(
                  opacity: 0.6,
                  child: OmniListRow(
                    key: ValueKey('known-$i'),
                    icon: _icon(f),
                    title: _knownName('${f.candidate['knownAs']}'),
                    subtitle: '${f.candidate['host'] ?? ''}',
                    value: 'added',
                    valueColor: OmniColors.muted,
                  ),
                ),
            ],
            const OmniSectionHeader('Or add by hand'),
            OmniListRow(
              key: const ValueKey('manual-tag'),
              icon: OmniIcons.tag,
              title: 'NFC tag',
              chevron: true,
              onTap: () => showAddTagSheet(context),
            ),
            OmniListRow(
              key: const ValueKey('manual-place'),
              icon: OmniIcons.place,
              title: 'A place (home, office)',
              chevron: true,
              onTap: () => _byHand(driver: '${place?['driver'] ?? 'place'}'),
            ),
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
              title: 'Any driver',
              subtitle: others.isEmpty
                  ? 'Pick what it is and type its address'
                  : '${others.take(4).join(', ')}…',
              chevron: true,
              onTap: _byHand,
            ),
            const SizedBox(height: OmniSpace.md),
            OmniButton.ghost(
              key: const ValueKey('add-rescan'),
              label: 'Look again',
              icon: OmniIcons.retry,
              onPressed: _looking ? null : _discover,
            ),
          ],
        ),
      ),
    );
  }
}

class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      height: 52,
      margin: const EdgeInsets.only(bottom: OmniSpace.xs),
      decoration: BoxDecoration(
        color: OmniColors.card,
        borderRadius: BorderRadius.circular(OmniRadii.step),
      ),
    ),
  );
}

/// A driver name without its transport note: "LG webOS TV (local SSAP over
/// WebSocket)" reads "LG webOS TV".
String _shortName(String name) {
  final cut = name.indexOf(' (');
  return cut > 0 ? name.substring(0, cut) : name;
}
