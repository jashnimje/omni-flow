import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../automations/automations.dart';
import '../design/design.dart';
import '../devices/device_text.dart';
import '../devices/open_device.dart';
import '../settings/settings_screen.dart';
import '../shell/shell.dart';
import 'home_data.dart';

/// 1.3: one box for search and commands. As the user types, the engine's
/// reading of the line comes first ("Do it"), then the things, automations
/// and settings whose names match, then suggestions. Enter runs the top
/// result and says what happened.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  static const settle = Duration(milliseconds: 300);

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _field = TextEditingController();
  Timer? _debounce;
  Json? _reading;
  String? _readFor;
  String? _summary;

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _changed(String text) {
    setState(() => _summary = null);
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _reading = null);
      return;
    }
    _debounce = Timer(SearchScreen.settle, () => _interpret(text));
  }

  Future<Json?> _interpret(String text) async {
    final Json reply;
    try {
      reply = await ref.read(engineClientProvider).call(
        EngineCalls.commandInterpret,
        {'text': text},
      );
    } on Object {
      return null;
    }
    if (!mounted || reply['ok'] != true) return null;
    if (_field.text == text) {
      setState(() {
        _reading = reply;
        _readFor = text;
      });
    }
    return reply;
  }

  Future<void> _submit(String text) async {
    if (text.trim().isEmpty) return;
    _debounce?.cancel();
    final read = _readFor == text && _reading != null
        ? _reading!
        : await _interpret(text);
    if (read == null || !mounted) return;
    if (read['kind'] == 'ask') {
      // The Do it card already says what the engine made of it.
      setState(() {
        _reading = read;
        _readFor = text;
        _summary = null;
      });
      return;
    }
    final result = await callEngine(
      ref,
      read['command'] as String,
      Map<String, Object?>.from(read['args'] as Map),
    );
    if (!mounted) return;
    if (read['command'] == 'flow.run' && result['ok'] == true) {
      showMessage(runSummary(read['summary'], result));
    }
    setState(
      () => _summary = result['ok'] == true ? '${read['summary']}' : null,
    );
    if (result['ok'] == true) {
      _field.clear();
      setState(() => _reading = null);
    }
  }

  /// The engine explains a line it half understood. Its generic answer
  /// is for an AI the app does not have, so it gets examples instead.
  static String _askText(Json read) {
    final summary = read['summary'];
    return summary is String && summary != 'Ask the architect'
        ? summary
        : 'Nothing to do for that. Try a device and what to do, like '
              '"desk lamp 50%" or "tv off", or "run" and an automation.';
  }

  void _fill(String text) {
    _field.text = text;
    _field.selection = TextSelection.collapsed(offset: text.length);
    _changed(text);
  }

  @override
  Widget build(BuildContext context) {
    final query = _field.text.trim().toLowerCase();
    final drivers = ref.watch(driversProvider).value ?? const {};
    final devices = [
      for (final j in ref.watch(devicesProvider).value ?? const <Json>[])
        DeviceView(j),
    ];
    final automations = ref.watch(summariesProvider).value ?? const [];
    final things = query.isEmpty
        ? const <DeviceView>[]
        : _byHits(devices, (d) => _hits(query, d.name)).take(6).toList();
    final matching = query.isEmpty
        ? const <AutomationSummary>[]
        : _byHits(
            automations,
            (a) => _hits(
              query,
              [a.name, for (final p in a.sentence) p.text].join(' '),
            ),
          ).take(5).toList();
    final places = query.isEmpty
        ? const <SettingsPlace>[]
        : _byHits(settingsPlaces, (p) => _hits(query, p.title)).toList();
    final reading = _reading;
    final runnable = reading != null && reading['kind'] != 'ask';
    final target = runnable && reading['args'] is Map
        ? devices
              .where((d) => d.id == (reading['args'] as Map)['id'])
              .firstOrNull
        : null;
    return OmniPage(
      title: 'Search',
      body: ListView(
        key: const ValueKey('search-list'),
        children: [
          TextField(
            key: const ValueKey('command-bar'),
            controller: _field,
            autofocus: true,
            textInputAction: TextInputAction.go,
            onChanged: _changed,
            onSubmitted: _submit,
            decoration: const InputDecoration(
              prefixIcon: Icon(OmniIcons.chevron, color: OmniColors.muted),
              hintText: 'Search, or say what to do: desk lamp 50',
            ),
          ),
          if (_summary != null)
            Padding(
              padding: const EdgeInsets.only(top: OmniSpace.sm),
              child: OmniBanner.info(
                _summary!,
                key: const ValueKey('command-summary'),
              ),
            ),
          if (reading != null) ...[
            const OmniSectionHeader('Do it'),
            OmniCard(
              key: const ValueKey('search-do-it'),
              highlighted: runnable,
              title: runnable ? '${reading['summary']}' : _askText(reading),
              trailing: runnable
                  ? const Icon(
                      OmniIcons.enter,
                      size: 18,
                      color: OmniColors.muted,
                      semanticLabel: 'Press enter to run',
                    )
                  : null,
              onTap: runnable ? () => _submit(_field.text) : null,
              child: target == null
                  ? null
                  : Text(
                      [
                        shortDriverName(drivers[target.driver], target.driver),
                        ?target.room,
                      ].join(' · '),
                      style: OmniText.caption,
                    ),
            ),
          ],
          if (things.isNotEmpty) ...[
            const OmniSectionHeader('Things'),
            for (final d in things)
              OmniListRow(
                key: ValueKey('search-thing-${d.id}'),
                icon: iconOf(d, drivers),
                title: d.name,
                subtitle: stateLine(d),
                chevron: true,
                onTap: () => openDevice(context, d.id),
              ),
          ],
          if (matching.isNotEmpty) ...[
            const OmniSectionHeader('Automations'),
            for (final a in matching)
              OmniListRow(
                key: ValueKey('search-automation-${a.id}'),
                icon: OmniIcons.automations,
                title: a.name,
                subtitle: a.sentence.map((p) => p.text).join(' '),
                chevron: true,
                onTap: () => ref
                    .read(shellControllerProvider)
                    .open(AutomationLink(a.id)),
              ),
          ],
          if (places.isNotEmpty) ...[
            const OmniSectionHeader('Settings'),
            for (final p in places)
              OmniListRow(
                icon: p.icon,
                title: p.title,
                chevron: true,
                onTap: () => p.open(context, ref),
              ),
          ],
          const OmniSectionHeader('Try'),
          Wrap(
            spacing: 6,
            children: [
              for (final s in _suggestions(devices, automations))
                OmniFilterChip(
                  key: ValueKey('try-$s'),
                  label: s,
                  onTap: () => _fill(s),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Lines made from the user's own things, so each one works here.
  static List<String> _suggestions(
    List<DeviceView> devices,
    List<AutomationSummary> automations,
  ) {
    final level = devices
        .where((d) => d.capabilityOf('level') != null && d.online)
        .firstOrNull;
    final power = devices
        .where((d) => d.hasPower && d.capabilityOf('level') == null)
        .firstOrNull;
    final run = automations.where((a) => a.enabled && a.approved).firstOrNull;
    return [
      if (level != null) '${level.name.toLowerCase()} 50',
      if (power != null) '${power.name.toLowerCase()} off',
      if (run != null) 'run ${run.name.toLowerCase()}',
    ];
  }
}

/// How many words of [query] appear in [text]. Numbers and single letters
/// do not count, so "desk lamp 50" finds the desk lamp, then the desk plug.
int _hits(String query, String text) {
  final t = text.toLowerCase();
  return query
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 1 && num.tryParse(w) == null && t.contains(w))
      .length;
}

/// The [items] with at least one hit, most hits first, keeping their order
/// otherwise.
List<T> _byHits<T>(List<T> items, int Function(T) hits) {
  final scored = [
    for (final (i, item) in items.indexed)
      if (hits(item) case final n when n > 0) (n, i, item),
  ]..sort((a, b) => a.$1 != b.$1 ? b.$1 - a.$1 : a.$2 - b.$2);
  return [for (final s in scored) s.$3];
}
