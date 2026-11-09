import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../device_sheets.dart' show confirm;
import 'tv_controller.dart';
import 'tv_widgets.dart';

class TvSettingsTab extends StatefulWidget {
  const TvSettingsTab({super.key, required this.tv});

  final TvController tv;

  @override
  State<TvSettingsTab> createState() => _TvSettingsTabState();
}

class _TvSettingsTabState extends State<TvSettingsTab>
    with AutomaticKeepAliveClientMixin {
  List<TvSettingCategory>? _categories;
  String? _error;

  TvController get tv => widget.tv;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final result = await tv.client.call(
      TvCalls.settingsCatalog,
      TvCalls.idArgs(tv.id),
    );
    if (!mounted) return;
    setState(() {
      if (result['ok'] == true) {
        _categories = TvCalls.catalogOf(result);
      } else {
        _error = errorMessage(result);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final categories = _categories;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Read live from the TV',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey('settings-all'),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AllSettingsPage(tv: tv),
                    ),
                  );
                  if (mounted) await _load();
                },
                icon: const Icon(Icons.list_alt),
                label: const Text('All settings'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? TvEmpty(text: _error!, onRetry: _load)
              : categories == null
              ? const Center(child: CircularProgressIndicator())
              : categories.isEmpty
              ? const TvEmpty(text: 'The TV reported no settings')
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    key: const ValueKey('settings-list'),
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final (i, c) in categories.indexed)
                        ExpansionTile(
                          key: ValueKey('category-${c.category}'),
                          initiallyExpanded: i == 0,
                          leading: Icon(categoryIcon(c.category)),
                          title: Text(c.category),
                          subtitle: Text('${c.settings.length} settings'),
                          children: [
                            for (final s in c.settings)
                              SettingTile(
                                key: ValueKey(
                                  'setting-${s.namespace}.${s.key}',
                                ),
                                tv: tv,
                                setting: s,
                                risky: isNetwork(c.category),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

bool isNetwork(String category) => category.toLowerCase().contains('network');

IconData categoryIcon(String category) {
  final c = category.toLowerCase();
  if (c.contains('display') || c.contains('sound')) return Icons.tv;
  if (c.contains('network')) return Icons.wifi;
  if (c.contains('power') || c.contains('sleep')) return Icons.power_outlined;
  if (c.contains('screensaver')) return Icons.wallpaper;
  if (c.contains('hdmi')) return Icons.settings_input_hdmi;
  if (c.contains('bluetooth')) return Icons.bluetooth;
  if (c.contains('accessibility') || c.contains('caption')) {
    return Icons.accessibility_new;
  }
  if (c.contains('developer')) return Icons.developer_mode;
  if (c.contains('date') || c.contains('time')) return Icons.schedule;
  if (c.contains('location')) return Icons.location_on_outlined;
  return Icons.more_horiz;
}

/// One curated setting with the control its type calls for. A change is
/// written straight away, after a confirm for [risky] ones, and the shown
/// value moves only when the TV accepted it.
class SettingTile extends StatefulWidget {
  const SettingTile({
    super.key,
    required this.tv,
    required this.setting,
    this.risky = false,
  });

  final TvController tv;
  final TvSetting setting;
  final bool risky;

  @override
  State<SettingTile> createState() => _SettingTileState();
}

class _SettingTileState extends State<SettingTile> {
  late TvSetting _s = widget.setting;
  double? _dragging;
  var _busy = false;
  late final _text = TextEditingController(text: _s.textValue);

  @override
  void didUpdateWidget(SettingTile old) {
    super.didUpdateWidget(old);
    if (old.setting != widget.setting) {
      _s = widget.setting;
      _text.text = _s.textValue;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _unit => _s.unit == null ? '' : ' ${_s.unit}';

  Future<void> _put(Object? value) async {
    if (widget.risky) {
      final ok = await confirm(
        context,
        title: 'Change ${_s.label}?',
        body:
            'A wrong network setting can cut the TV off the internet, and '
            'OmniFlow off the TV.',
        action: 'Change',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final result = await widget.tv.call(
      TvCalls.settingsPut,
      TvCalls.settingPutArgs(widget.tv.id, _s.namespace, _s.key, value),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _dragging = null;
      if (result['ok'] == true) {
        _s = _s.withValue(TvCalls.putValueOf(result, value));
      }
      _text.text = _s.textValue;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final description = s.description;
    final subtitle = [
      if (description != null && description.isNotEmpty) description,
      '${s.namespace}/${s.key}',
    ].join('\n');
    final trailingBusy = _busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : null;
    switch (s.type) {
      case 'bool':
        return SwitchListTile(
          title: Text(s.label),
          subtitle: Text(subtitle),
          isThreeLine: description != null,
          secondary: trailingBusy,
          value: s.boolValue,
          onChanged: _busy ? null : (v) => _put(v),
        );
      case 'int' || 'float' when s.min != null && s.max != null:
        final min = s.min!.toDouble();
        final max = s.max!.toDouble();
        final step = (s.step ?? (s.type == 'int' ? 1 : (max - min) / 100))
            .toDouble();
        final divisions = step > 0 ? ((max - min) / step).round() : null;
        final current = _dragging ?? s.numValue?.toDouble();
        final shown = current == null ? 'Not set' : '${_fmt(current)}$_unit';
        return ListTile(
          title: Row(
            children: [
              Expanded(child: Text(s.label)),
              Text(shown, key: ValueKey('setting-value-${s.key}')),
              if (trailingBusy != null) ...[
                const SizedBox(width: 8),
                trailingBusy,
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Slider(
                key: ValueKey('setting-slider-${s.key}'),
                min: min,
                max: max,
                divisions: divisions == null || divisions <= 0
                    ? null
                    : divisions.clamp(1, 1000),
                value: (current ?? min).clamp(min, max),
                label: '${_fmt(current ?? min)}$_unit',
                onChanged: _busy ? null : (v) => setState(() => _dragging = v),
                onChangeEnd: _busy
                    ? null
                    : (v) => _put(s.type == 'int' ? v.round() : _round(v)),
              ),
              Text(subtitle),
            ],
          ),
        );
      case 'enum' when s.options.isNotEmpty:
        final value = s.options.any((o) => o.value == s.textValue)
            ? s.textValue
            : null;
        return ListTile(
          title: Text(s.label),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<String>(
                key: ValueKey('setting-enum-${s.key}'),
                isExpanded: true,
                value: value,
                hint: Text(s.textValue.isEmpty ? 'Not set' : s.textValue),
                items: [
                  for (final o in s.options)
                    DropdownMenuItem(value: o.value, child: Text(o.label)),
                ],
                onChanged: _busy
                    ? null
                    : (v) {
                        if (v != null && v != value) _put(v);
                      },
              ),
              Text(subtitle),
            ],
          ),
        );
      default:
        final numeric = s.type == 'int' || s.type == 'float';
        return ListTile(
          title: Text(s.label),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: ValueKey('setting-text-${s.key}'),
                      controller: _text,
                      keyboardType: numeric
                          ? const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            )
                          : TextInputType.text,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Not set',
                        suffixText: s.unit,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('setting-save-${s.key}'),
                    tooltip: 'Save ${s.label}',
                    onPressed: _busy
                        ? null
                        : () {
                            final text = _text.text.trim();
                            if (numeric) {
                              final n = num.tryParse(text);
                              if (n == null) {
                                showMessage('${s.label} must be a number');
                                return;
                              }
                              _put(s.type == 'int' ? n.round() : n);
                            } else {
                              _put(text);
                            }
                          },
                    icon: trailingBusy ?? const Icon(Icons.check),
                  ),
                ],
              ),
              Text(subtitle),
            ],
          ),
        );
    }
  }

  static double _round(double v) => (v * 100).round() / 100;

  static String _fmt(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);
}

/// Every setting the TV has, per namespace, with search, raw edit and
/// delete. Raw writes skip the catalog's checks, so each one is confirmed.
class AllSettingsPage extends StatelessWidget {
  const AllSettingsPage({super.key, required this.tv});

  final TvController tv;

  static const namespaces = ['system', 'secure', 'global'];

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: namespaces.length,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('All TV settings'),
        bottom: TabBar(tabs: [for (final n in namespaces) Tab(text: n)]),
      ),
      body: TabBarView(
        children: [
          for (final n in namespaces) _NamespaceList(tv: tv, namespace: n),
        ],
      ),
    ),
  );
}

class _NamespaceList extends StatefulWidget {
  const _NamespaceList({required this.tv, required this.namespace});

  final TvController tv;
  final String namespace;

  @override
  State<_NamespaceList> createState() => _NamespaceListState();
}

class _NamespaceListState extends State<_NamespaceList>
    with AutomaticKeepAliveClientMixin {
  List<TvRawSetting>? _settings;
  String? _error;
  final _search = TextEditingController();

  TvController get tv => widget.tv;
  String get ns => widget.namespace;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final result = await tv.client.call(
      TvCalls.settingsList,
      TvCalls.settingsListArgs(tv.id, ns),
    );
    if (!mounted) return;
    setState(() {
      if (result['ok'] == true) {
        _settings = TvCalls.settingsOf(result)
          ..sort((a, b) => a.key.compareTo(b.key));
      } else {
        _error = errorMessage(result);
      }
    });
  }

  Future<void> _edit({String? key, String? value}) async {
    final newKey =
        key ??
        await askText(
          context,
          title: 'New $ns setting',
          label: 'Key',
          action: 'Next',
          validate: _keyError,
        );
    if (newKey == null || !mounted) return;
    final newValue = await askText(
      context,
      title: newKey,
      label: 'Value',
      initial: value ?? '',
      action: 'Save',
      multiline: true,
    );
    if (newValue == null || newValue == value || !mounted) return;
    final ok = await confirm(
      context,
      title: 'Write $ns/$newKey?',
      body:
          'This writes "$newValue" straight to the TV with no checks. A wrong '
          'value can change how the TV behaves until it is set back.',
      action: 'Write',
    );
    if (!ok) return;
    final result = await tv.call(
      TvCalls.settingsPut,
      TvCalls.settingPutArgs(tv.id, ns, newKey, newValue),
    );
    if (result['ok'] == true) {
      showMessage('Saved $newKey');
      await _load();
    }
  }

  static String? _keyError(String key) =>
      RegExp(r'^[A-Za-z0-9_.\-]+$').hasMatch(key.trim())
      ? null
      : 'Letters, digits, dots, dashes and underscores';

  Future<void> _delete(String key) async {
    final ok = await confirm(
      context,
      title: 'Delete $ns/$key?',
      body:
          'The TV goes back to its built-in default for it, which may not be '
          'what it had before.',
      action: 'Delete',
    );
    if (!ok) return;
    final result = await tv.call(
      TvCalls.settingsDelete,
      TvCalls.settingArgs(tv.id, ns, key),
    );
    if (result['ok'] == true) {
      showMessage('Deleted $key');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final query = _search.text.trim().toLowerCase();
    final settings = [
      for (final s in _settings ?? const <TvRawSetting>[])
        if (query.isEmpty ||
            s.key.toLowerCase().contains(query) ||
            (s.value ?? '').toLowerCase().contains(query))
          s,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('raw-search-$ns'),
                  controller: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search ${_settings?.length ?? ''} $ns settings',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                key: ValueKey('raw-add-$ns'),
                tooltip: 'Add a $ns setting',
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? TvEmpty(text: _error!, onRetry: _load)
              : _settings == null
              ? const Center(child: CircularProgressIndicator())
              : settings.isEmpty
              ? const TvEmpty(text: 'No setting matches')
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: settings.length,
                    itemBuilder: (context, i) {
                      final s = settings[i];
                      return ListTile(
                        key: ValueKey('raw-$ns.${s.key}'),
                        dense: true,
                        title: Text(
                          s.key,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Text(
                          s.value ?? 'null',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _edit(key: s.key, value: s.value),
                        trailing: IconButton(
                          key: ValueKey('raw-delete-$ns.${s.key}'),
                          tooltip: 'Delete ${s.key}',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(s.key),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
