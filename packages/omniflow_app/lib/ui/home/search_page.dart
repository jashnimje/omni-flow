import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/device_features.dart';
import '../../state/providers.dart';
import '../automations/automations.dart';
import '../design/automation_look.dart' show AutomationBadge;
import '../design/design.dart';
import '../devices/device_text.dart';
import '../devices/open_device.dart';
import '../settings/settings_screen.dart';
import '../shell/shell.dart';
import 'home_data.dart';
import 'tile_look.dart' show phoneLine;

/// 1.3: one box for search and commands. As the user types, the engine's
/// reading of the line comes first ("Do it"), then the things, automations
/// and settings whose names match, then suggestions. Enter runs the top
/// result and says what happened.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  /// How long typing pauses before the line is read.
  static const settle = Duration(milliseconds: 700);

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _field = TextEditingController();
  Timer? _debounce;
  Json? _reading;
  String? _readFor;
  String? _summary;

  /// Enter was pressed on the line read last, so a line the engine did not
  /// understand says so. While typing only a runnable reading shows.
  var _asked = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _changed(String text) {
    setState(() {
      _summary = null;
      _asked = false;
    });
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
      // The Do it card says what the engine made of it.
      setState(() {
        _reading = read;
        _readFor = text;
        _summary = null;
        _asked = true;
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
        : _byHits(
            devices,
            (d) => _hits(query, [d.name, ?d.room].join(' ')),
          ).take(6).toList();
    final matching = query.isEmpty
        ? const <AutomationSummary>[]
        : _byHits(
            automations,
            (a) => _hits(
              query,
              [a.name, for (final p in a.sentence) p.text].join(' '),
            ),
          ).take(5).toList();
    // Scenes are automations, not settings: the scenes whose names match,
    // and the Scenes page itself, list under Automations.
    final scenes = query.isEmpty
        ? const <Scene>[]
        : _byHits([
            for (final s in ref.watch(scenesProvider).value ?? const [])
              if (s.id != null) s,
          ], (s) => _hits(query, s.name)).take(5).toList();
    // Each place under the heading of where it sits ("Settings, Your
    // home"), in the order Settings shows them.
    final places = settingsPlacesFor(ref.watch(deviceFeaturesProvider));
    final placesBySection = <String, List<SettingsPlace>>{
      if (query.isNotEmpty)
        for (final section in {for (final p in places) p.section})
          section: [
            for (final p in places)
              if (p.section == section && p.matches(query)) p,
          ],
    }..removeWhere((_, places) => places.isEmpty);
    final automationPlaces =
        placesBySection.remove(_automationsHeading) ?? const [];
    final suggestions = _suggestions(devices, automations, drivers);
    // A reading of what was typed before is not shown for what is typed
    // now, when the new text could not be read.
    final reading = _readFor == _field.text ? _reading : null;
    final runnable = reading != null && reading['kind'] != 'ask';
    final showReading = runnable || (reading != null && _asked);
    final target = runnable && reading['args'] is Map
        ? devices
              .where((d) => d.id == (reading['args'] as Map)['id'])
              .firstOrNull
        : null;
    final nothing =
        query.isNotEmpty &&
        !showReading &&
        things.isEmpty &&
        matching.isEmpty &&
        scenes.isEmpty &&
        automationPlaces.isEmpty &&
        placesBySection.isEmpty;
    return ListPage(
      key: const ValueKey('search-list'),
      title: 'Search',
      search: TextField(
        key: const ValueKey('command-bar'),
        controller: _field,
        autofocus: true,
        textInputAction: TextInputAction.go,
        onChanged: _changed,
        onSubmitted: _submit,
        decoration: InputDecoration(
          prefixIcon: Icon(
            OmniIcons.chevron,
            color: OmniPalette.of(context).muted,
          ),
          hintText: 'Search, or say what to do: desk lamp 50',
        ),
      ),
      children: (context) => [
        if (_summary != null)
          Padding(
            padding: const EdgeInsets.only(top: OmniSpace.sm),
            child: OmniBanner.info(
              _summary!,
              key: const ValueKey('command-summary'),
            ),
          ),
        if (showReading) ...[
          const OmniSectionHeader('Do it'),
          OmniCard(
            key: const ValueKey('search-do-it'),
            highlighted: runnable,
            title: runnable ? '${reading['summary']}' : _askText(reading),
            trailing: runnable
                ? Icon(
                    OmniIcons.enter,
                    size: 18,
                    color: OmniPalette.of(context).muted,
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
                    style: OmniText.captionOf(context),
                  ),
          ),
        ],
        if (things.isNotEmpty) ...[
          const OmniSectionHeader('Devices, places and tags'),
          for (final d in things)
            OmniListRow(
              key: ValueKey('search-thing-${d.id}'),
              icon: iconOf(d, drivers),
              title: d.name,
              subtitle: kindOf(d) == DeviceKind.phone
                  ? phoneLine(d)
                  : stateLine(d),
              chevron: true,
              onTap: () => openDevice(context, d.id),
            ),
        ],
        if (matching.isNotEmpty ||
            scenes.isNotEmpty ||
            automationPlaces.isNotEmpty) ...[
          const OmniSectionHeader(_automationsHeading),
          for (final p in automationPlaces) _placeRow(context, p),
          for (final a in matching)
            OmniListRow(
              key: ValueKey('search-automation-${a.id}'),
              // The automation's own look, as on its card.
              leading: AutomationBadge(
                icon: automationIconFor(a),
                color: a.color,
                size: 32,
              ),
              title: a.name,
              subtitle: sentenceText(a.sentence),
              chevron: true,
              onTap: () =>
                  ref.read(shellControllerProvider).open(AutomationLink(a.id)),
            ),
          for (final sc in scenes)
            OmniListRow(
              key: ValueKey('search-scene-${sc.id}'),
              icon: sceneIconFor(sc.icon),
              title: sc.name,
              subtitle: 'Scene',
              chevron: true,
              onTap: () => openSceneEditor(context, id: sc.id),
            ),
        ],
        for (final MapEntry(key: section, value: places)
            in placesBySection.entries) ...[
          OmniSectionHeader(section),
          for (final p in places) _placeRow(context, p),
        ],
        if (nothing)
          OmniEmptyState(
            key: const ValueKey('search-none'),
            icon: OmniIcons.search,
            title: 'No results for "${_field.text.trim()}"',
            message: 'Try a device, a room or an automation name.',
            compact: true,
          ),
        // No commands to try under no results, so a search that found
        // nothing is not answered with something unrelated. With nothing
        // that answers to try, there is no heading either.
        if (!nothing && suggestions.isNotEmpty) ...[
          const OmniSectionHeader('Try'),
          Wrap(
            spacing: OmniSpace.sm,
            runSpacing: OmniSpace.xs,
            children: [
              for (final s in suggestions)
                OmniFilterChip(
                  key: ValueKey('try-$s'),
                  label: s,
                  onTap: () => _fill(s),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _placeRow(BuildContext context, SettingsPlace p) => OmniListRow(
    key: ValueKey('search-place-${p.title}'),
    icon: p.icon,
    title: p.title,
    chevron: true,
    onTap: () => p.open(context, ref),
  );

  /// The quick commands the command bar documents (`<device> 50%`,
  /// `<device> off`, `run <automation>`), made from the user's own lights,
  /// plugs and automations, so each one works here and reads plainly.
  static List<String> _suggestions(
    List<DeviceView> devices,
    List<AutomationSummary> automations,
    Map<String, Json> drivers,
  ) {
    String? category(DeviceView d) =>
        (d.json['category'] ?? drivers[d.driver]?['category']) as String?;
    final light = devices
        .where(
          (d) =>
              category(d) == 'lighting' &&
              d.capabilityOf('level') != null &&
              d.online,
        )
        .firstOrNull;
    final plug = devices
        .where((d) => category(d) == 'power' && d.hasPower && d.online)
        .firstOrNull;
    final run = automations.where((a) => a.enabled && a.approved).firstOrNull;
    return [
      if (light != null) '${light.name.toLowerCase()} 50%',
      if (plug != null) '${plug.name.toLowerCase()} off',
      if (run != null) 'run ${run.name.toLowerCase()}',
    ];
  }
}

/// The heading of automations, scenes and the Scenes page in search. A
/// place whose section is this lists under it.
const _automationsHeading = 'Automations';

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
