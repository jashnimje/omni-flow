import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/open_device.dart';

/// How to get the link, in the WiZ app's own words.
const wizExportSteps =
    'In the WiZ app: Settings, your home, Integrations, Local integrations, '
    'Export. Copy the link.';

/// The largest export file read, the engine's own cap.
const wizExportFileMaxBytes = 512 * 1024;

/// Where the export comes from on the phone: the clipboard, the system file
/// picker, and what was shared to OmniFlow from the WiZ app.
abstract interface class WizImportHands {
  /// The clipboard's text, or null.
  Future<String?> pasted();

  /// The text of a file the person picks, or null when they pick none.
  Future<String?> pickFile();

  /// What was shared to OmniFlow's "Add WiZ lights", once, or null.
  Future<String?> takeShared();
}

/// The phone's side. WizShareActivity.kt writes a share to
/// [sharedFileName] in the app's private files and opens this screen.
class PhoneWizImportHands implements WizImportHands {
  const PhoneWizImportHands();

  static const sharedFileName = 'wiz_share.json';

  /// A share older than this is not the one that opened the screen.
  static const sharedFor = Duration(minutes: 15);

  @override
  Future<String?> pasted() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<String?> pickFile() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    final path = files.firstOrNull?.path;
    if (path == null) return null;
    final file = File(path);
    if (await file.length() > wizExportFileMaxBytes) {
      return '{"tooLarge": true}';
    }
    return utf8.decode(await file.readAsBytes(), allowMalformed: true);
  }

  @override
  Future<String?> takeShared() async {
    try {
      final file = File(
        '${(await getApplicationSupportDirectory()).path}/$sharedFileName',
      );
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      await file.delete();
      if (json is! Map || json['text'] is! String) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(
        json['at'] is int ? json['at'] as int : 0,
      );
      if (DateTime.now().difference(at) > sharedFor) return null;
      return json['text'] as String;
    } on Object {
      return null;
    }
  }
}

final wizImportHandsProvider = Provider<WizImportHands>(
  (_) => const PhoneWizImportHands(),
);

/// Opens Add, From the WiZ app.
Future<void> openWizImport(BuildContext context) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(builder: (_) => const WizImportPage()));

/// Add, From the WiZ app: one step-by-step line on getting the export,
/// then paste the link (or pick the file) and every WiZ light that answers
/// on this Wi-Fi is added with its name, room and home key. A share from
/// the WiZ app opens it with the link filled in.
class WizImportPage extends ConsumerStatefulWidget {
  const WizImportPage({super.key});

  @override
  ConsumerState<WizImportPage> createState() => _WizImportPageState();
}

class _WizImportPageState extends ConsumerState<WizImportPage> {
  /// The link or the export, as it came.
  String? _source;

  /// Whether [_source] came from a file, which is shown by name only.
  var _fromFile = false;
  var _busy = false;
  ApiFailure? _failure;
  Json? _result;

  WizImportHands get _hands => ref.read(wizImportHandsProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_takeShared());
  }

  Future<void> _takeShared() async {
    final shared = await _hands.takeShared();
    if (!mounted || shared == null || shared.trim().isEmpty) return;
    setState(() {
      _source = shared.trim();
      _fromFile = _source!.startsWith('{');
      _result = null;
      _failure = null;
    });
  }

  Future<void> _paste() async {
    final text = (await _hands.pasted())?.trim();
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      setState(
        () => _failure = const ApiFailure(
          'invalid',
          'Nothing is copied yet. Copy the link in the WiZ app first',
        ),
      );
      return;
    }
    _source = text;
    _fromFile = text.startsWith('{');
    await _import();
  }

  Future<void> _pickFile() async {
    final text = await _hands.pickFile();
    if (!mounted || text == null) return;
    _source = text;
    _fromFile = true;
    await _import();
  }

  Future<void> _import() async {
    final source = _source;
    if (source == null) return;
    setState(() {
      _busy = true;
      _failure = null;
      _result = null;
    });
    final reply = await EngineApi(ref.read(engineClientProvider))
        .wizImport(source);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failure = reply.failure;
      _result = reply.value;
    });
    if (reply.ok) await ref.read(devicesProvider.notifier).refresh();
  }

  static List<Json> _rows(Object? list) => [
    for (final r in list as List? ?? const [])
      if (r is Map) Map<String, Object?>.from(r),
  ];

  String _where(Json row) =>
      [?row['room'] as String?, ?row['host'] as String?].join(' · ');

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final source = _source;
    return ListPage(
      key: const ValueKey('wiz-import'),
      title: 'From the WiZ app',
      banners: [
        if (_busy)
          const OmniBanner.info(
            key: ValueKey('wiz-busy'),
            'Looking for your WiZ lights on this Wi-Fi…',
          ),
        if (_failure case final f?)
          OmniBanner.error(key: const ValueKey('wiz-error'), f.message),
      ],
      children: (context) => [
        const OmniSectionHeader('Get the link'),
        const Padding(
          padding: EdgeInsets.only(bottom: OmniSpace.md),
          child: Text(wizExportSteps, key: ValueKey('wiz-steps')),
        ),
        if (source != null && result == null && !_busy) ...[
          OmniListRow(
            key: const ValueKey('wiz-source'),
            icon: _fromFile ? Icons.description_rounded : Icons.link_rounded,
            title: _fromFile ? 'Your WiZ export' : 'Your WiZ link',
            subtitle: _fromFile ? 'Ready to add' : source,
          ),
          OmniButton(
            key: const ValueKey('wiz-add'),
            label: 'Add my WiZ lights',
            icon: OmniIcons.add,
            onPressed: _import,
          ),
          const SizedBox(height: OmniSpace.sm),
        ],
        OmniButton(
          key: const ValueKey('wiz-paste'),
          label: 'Paste the link and add',
          icon: Icons.content_paste_rounded,
          kind: source != null && result == null
              ? OmniButtonKind.ghost
              : OmniButtonKind.primary,
          onPressed: _busy ? null : _paste,
        ),
        const SizedBox(height: OmniSpace.sm),
        OmniButton.ghost(
          key: const ValueKey('wiz-file'),
          label: 'Pick the exported file',
          icon: Icons.file_open_rounded,
          onPressed: _busy ? null : _pickFile,
        ),
        if (result != null) ..._resultRows(result),
      ],
    );
  }

  List<Widget> _resultRows(Json result) {
    final added = _rows(result['added']);
    final updated = _rows(result['updated']);
    final missing = _rows(result['notFound']);
    final rooms = [for (final r in result['roomsCreated'] as List? ?? []) '$r'];
    return [
      const SizedBox(height: OmniSpace.md),
      OmniBanner.info(
        key: const ValueKey('wiz-summary'),
        '${result['message'] ?? ''}'
        '${rooms.isEmpty ? '' : ' New rooms: ${rooms.join(', ')}.'}',
      ),
      if (added.isNotEmpty) ...[
        const OmniSectionHeader('Added'),
        for (final r in added) _thingRow(r, 'added'),
      ],
      if (updated.isNotEmpty) ...[
        const OmniSectionHeader('Already here, brought up to date'),
        for (final r in updated) _thingRow(r, 'updated'),
      ],
      if (missing.isNotEmpty) ...[
        const OmniSectionHeader('Not found on this Wi-Fi'),
        for (final r in missing)
          OmniListRow(
            key: ValueKey('wiz-missing-${r['mac'] ?? r['name']}'),
            icon: OmniIcons.warning,
            title: '${r['name']}',
            subtitle: '${r['reason']}',
            subtitleLines: 3,
          ),
      ],
    ];
  }

  Widget _thingRow(Json r, String what) => OmniListRow(
    key: ValueKey('wiz-$what-${r['id']}'),
    icon: OmniIcons.light,
    title: '${r['name']}',
    subtitle: _where(r),
    chevron: true,
    onTap: () => openDevice(context, '${r['id']}'),
  );
}
