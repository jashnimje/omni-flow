import 'package:flutter/material.dart';
import 'package:omniflow_engine/omniflow_engine.dart' show thingIdFor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'tag_page.dart';
import 'write_tag_sheet.dart';

/// A tag id from its name, the engine's way for any name, Latin or not.
String tagIdFor(String name) => thingIdFor(name);

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
    return ListPage.builder(
      key: const ValueKey('tags-list'),
      title: 'NFC tags',
      actions: [
        OmniIconAction(
          key: const ValueKey('tags-add'),
          icon: OmniIcons.add,
          label: 'Add a tag',
          onPressed: () => showAddTagSheet(context),
        ),
      ],
      state: OmniLoad.of(
        devices,
        isEmpty: (_) => tags.isEmpty,
        onRetry: () => ref.read(devicesProvider.notifier).refresh(),
        error: 'The tags could not be read. Try again in a moment.',
      ),
      skeletonRows: 3,
      empty: OmniEmptyState(
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
      ),
      itemCount: tags.length,
      itemBuilder: (context, i) {
        final t = tags[i];
        return OmniListRow(
          key: ValueKey('tag-row-${t.id}'),
          icon: OmniIcons.tag,
          title: t.name,
          subtitle: switch (DateTime.tryParse('${t.state['last_scanned']}')) {
            final at? => 'scanned ${agoText(at)}',
            null => 'not scanned yet',
          },
          chevron: true,
          onTap: () => openTag(context, t.id),
        );
      },
    );
  }
}

/// Names a new tag and writes its link on a card held to the phone.
Future<void> showAddTagSheet(BuildContext context) =>
    SheetTemplate.show<void>(context, builder: (_) => const _AddTagSheet());

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
  Widget build(BuildContext context) => SheetTemplate(
    title: 'Add an NFC tag',
    subtitle: 'Name it, then hold a blank tag to the phone to write it',
    primaryLabel: 'Add and write it',
    primaryKey: const ValueKey('tag-add-write'),
    onPrimary: _saving || _name.text.trim().isEmpty ? null : _add,
    missing: _saving ? null : 'Give the tag a name first.',
    children: (context) => [
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
      const SizedBox(height: OmniSpace.sm),
      const Text(
        'A tag OmniFlow has not seen, held to the phone, is offered for '
        'naming too.',
        style: OmniText.caption,
      ),
    ],
  );
}
