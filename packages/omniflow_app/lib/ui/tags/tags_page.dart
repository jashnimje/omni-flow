import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'tag_page.dart';
import 'write_tag_sheet.dart';

/// A tag id from its name: lower snake case, as `tag.save` requires.
String tagIdFor(String name) {
  final id = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final full = RegExp(r'^[a-z]').hasMatch(id) ? id : 'tag_$id';
  return full.length > 64 ? full.substring(0, 64) : full;
}

Future<void> openTag(BuildContext context, String id) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => TagPage(id: id)));

/// Every NFC tag, each opening its tag page, with Add a tag.
class TagsPage extends ConsumerWidget {
  const TagsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final tags = [
      for (final d in devices.value ?? const <Json>[])
        if (isTagDevice(d)) DeviceView(d),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return OmniPage(
      title: 'NFC tags',
      actions: [
        OmniIconAction(
          key: const ValueKey('tags-add'),
          icon: OmniIcons.add,
          label: 'Add a tag',
          onPressed: () => showAddTagSheet(context),
        ),
      ],
      body: ListView(
        key: const ValueKey('tags-list'),
        children: [
          if (devices.hasError)
            OmniBanner.error(
              'The tags could not be read. Try again in a moment.',
              actionLabel: 'Try again',
              onAction: () => ref.read(devicesProvider.notifier).refresh(),
            )
          else if (devices.isLoading && devices.value == null)
            const Padding(
              padding: EdgeInsets.all(OmniSpace.xl),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            )
          else if (tags.isEmpty)
            OmniEmptyState(
              icon: OmniIcons.tag,
              title: 'No NFC tags yet',
              message:
                  'Write a tag, or hold one to the phone and OmniFlow offers '
                  'to name it. A scan can then run an automation.',
              action: OmniButton(
                label: 'Add a tag',
                icon: OmniIcons.add,
                onPressed: () => showAddTagSheet(context),
              ),
            )
          else
            for (final t in tags)
              OmniListRow(
                key: ValueKey('tag-row-${t.id}'),
                icon: OmniIcons.tag,
                title: t.name,
                subtitle: switch (DateTime.tryParse(
                  '${t.state['last_scanned']}',
                )) {
                  final at? => 'scanned ${agoText(at)}',
                  null => 'not scanned yet',
                },
                chevron: true,
                onTap: () => openTag(context, t.id),
              ),
        ],
      ),
    );
  }
}

/// Names a new tag and writes its link on a card held to the phone.
Future<void> showAddTagSheet(BuildContext context) =>
    showOmniSheet<void>(context, builder: (_) => const _AddTagSheet());

class _AddTagSheet extends ConsumerStatefulWidget {
  const _AddTagSheet();

  @override
  ConsumerState<_AddTagSheet> createState() => _AddTagSheetState();
}

class _AddTagSheetState extends ConsumerState<_AddTagSheet> {
  final _name = TextEditingController();
  var _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    final id = tagIdFor(name);
    final navigator = Navigator.of(context);
    final devices = ref.read(devicesProvider.notifier);
    final api = ref.read(engineApiProvider);
    final adapter = ref.read(nfcAdapterProvider);
    setState(() => _saving = true);
    final saved = await api.saveTag(id, name);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!saved.ok) return;
    await devices.refresh();
    navigator.pop();
    final under = navigator.context;
    if (!under.mounted) return;
    await writeTagWith(
      under,
      api: api,
      adapter: adapter,
      tag: {'id': id, 'name': name},
    );
  }

  @override
  Widget build(BuildContext context) => OmniSheet(
    title: 'Add an NFC tag',
    subtitle: 'Name it, then hold a blank tag to the phone to write it',
    children: [
      TextField(
        key: const ValueKey('tag-name'),
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Front door tag',
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: OmniSpace.md),
      OmniButton(
        key: const ValueKey('tag-add-write'),
        label: 'Add and write it',
        icon: OmniIcons.tag,
        onPressed: _saving || _name.text.trim().isEmpty ? null : _add,
      ),
      const SizedBox(height: OmniSpace.sm),
      const Text(
        'A tag OmniFlow has not seen, held to the phone, is offered for '
        'naming too.',
        style: OmniText.caption,
      ),
    ],
  );
}
