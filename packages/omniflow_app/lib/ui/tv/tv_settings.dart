import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_widgets.dart';

const tvNamespaces = ['system', 'secure', 'global'];

String _capital(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// 4.3 Settings: one search over every setting, the curated categories with
/// real controls and a line each on what they do, then All settings.
class TvSettingsTab extends StatefulWidget {
  const TvSettingsTab({super.key, required this.tv});

  final TvController tv;

  @override
  State<TvSettingsTab> createState() => _TvSettingsTabState();
}

class _TvSettingsTabState extends State<TvSettingsTab> {
  List<TvSettingCategory>? _categories;
  String? _error;
  final _search = TextEditingController();

  /// Every raw key per namespace, read after the catalog for the search and
  /// the counts. A namespace that fails stays out.
  final _raw = <String, List<TvRawSetting>>{};

  TvController get tv => widget.tv;

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
    if (!mounted) return;
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
    if (result['ok'] == true) await _loadRaw();
  }

  Future<void> _loadRaw() async {
    for (final ns in tvNamespaces) {
      final result = await tv.client.call(
        TvCalls.settingsList,
        TvCalls.settingsListArgs(tv.id, ns),
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        setState(() => _raw[ns] = TvCalls.settingsOf(result));
      }
    }
  }

  int get _rawCount => _raw.values.fold(0, (n, l) => n + l.length);

  Future<void> _openAll({String? namespace}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AllSettingsPage(tv: tv, namespace: namespace),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    final query = _search.text.trim().toLowerCase();
    final total = _rawCount;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('settings-list'),
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
        children: [
          TextField(
            key: const ValueKey('settings-search'),
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(OmniIcons.search),
              hintText: total == 0
                  ? 'Search settings'
                  : 'Search $total settings',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null)
            TvLoadError(what: 'The settings', reason: _error!, onRetry: _load)
          else if (categories == null)
            const TvLoading(label: 'Reading the settings')
          else if (query.isNotEmpty)
            ..._results(categories, query)
          else ...[
            if (categories.isEmpty)
              OmniEmptyState(
                icon: OmniIcons.settings,
                title: 'No curated settings',
                message:
                    'All settings below lists every key the ${tv.noun} has.',
              ),
            for (final c in categories) ...[
              OmniSectionHeader(c.category),
              for (final s in c.settings)
                SettingCard(
                  key: ValueKey('setting-${s.namespace}.${s.key}'),
                  tv: tv,
                  setting: s,
                  risky: isNetwork(c.category),
                ),
            ],
            const SizedBox(height: OmniSpace.sm),
            OmniListRow(
              key: const ValueKey('settings-all'),
              title: 'All settings',
              subtitle: _raw.isEmpty
                  ? 'every key per namespace'
                  : [
                      for (final ns in tvNamespaces)
                        if (_raw[ns] case final list?) '$ns ${list.length}',
                    ].join(' · '),
              chevron: true,
              onTap: _openAll,
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _results(List<TvSettingCategory> categories, String query) {
    bool hit(String? text) => text?.toLowerCase().contains(query) ?? false;
    final curated = [
      for (final c in categories)
        for (final s in c.settings)
          if (hit(s.label) || hit(s.description) || hit(s.key)) (c, s),
    ];
    final curatedKeys = {
      for (final (_, s) in curated) '${s.namespace}/${s.key}',
    };
    final raw = [
      for (final ns in tvNamespaces)
        for (final s in _raw[ns] ?? const <TvRawSetting>[])
          if ((hit(s.key) || hit(s.value)) &&
              !curatedKeys.contains('$ns/${s.key}'))
            s,
    ];
    if (curated.isEmpty && raw.isEmpty) {
      return [
        const OmniEmptyState(
          icon: OmniIcons.search,
          title: 'No setting matches',
          message: 'Search looks at names, descriptions, keys and values.',
        ),
      ];
    }
    return [
      if (curated.isNotEmpty) const OmniSectionHeader('Settings'),
      for (final (c, s) in curated)
        SettingCard(
          key: ValueKey('setting-${s.namespace}.${s.key}'),
          tv: tv,
          setting: s,
          risky: isNetwork(c.category),
        ),
      if (raw.isNotEmpty)
        OmniSectionHeader('Raw keys', trailingText: '${raw.length}'),
      for (final s in raw.take(100))
        OmniListRow(
          key: ValueKey('search-raw-${s.namespace}.${s.key}'),
          title: s.key,
          subtitle: '${s.namespace} · ${s.value ?? 'not set'}',
          chevron: true,
          onTap: () => _openAll(namespace: s.namespace),
        ),
    ];
  }
}

bool isNetwork(String category) => category.toLowerCase().contains('network');

/// One curated setting with the control its type calls for, in a card. A
/// change is written straight away, after a confirm for [risky] ones, and
/// the shown value moves only when the TV accepted it.
class SettingCard extends StatefulWidget {
  const SettingCard({
    super.key,
    required this.tv,
    required this.setting,
    this.risky = false,
  });

  final TvController tv;
  final TvSetting setting;
  final bool risky;

  @override
  State<SettingCard> createState() => _SettingCardState();
}

class _SettingCardState extends State<SettingCard> {
  late TvSetting _s = widget.setting;
  var _busy = false;
  late final _text = TextEditingController(text: _s.textValue);

  @override
  void didUpdateWidget(SettingCard old) {
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
            'A wrong network setting can cut the ${widget.tv.noun} off the internet, and '
            'OmniFlow off the ${widget.tv.noun}.',
        action: 'Change',
        destructive: true,
      );
      if (!ok || !mounted) {
        setState(() {});
        return;
      }
    }
    setState(() => _busy = true);
    final result = await widget.tv.call(
      TvCalls.settingsPut,
      TvCalls.settingPutArgs(widget.tv.id, _s.namespace, _s.key, value),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result['ok'] == true) {
        _s = _s.withValue(TvCalls.putValueOf(result, value));
      }
      _text.text = _s.textValue;
    });
  }

  Widget? get _description => switch (_s.description) {
    final String d when d.isNotEmpty => Text(
      d,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: OmniText.caption,
    ),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final s = _s;
    switch (s.type) {
      case 'bool':
        return OmniCard(
          title: s.label,
          trailing: Semantics(
            label: s.label,
            child: Switch(
              key: ValueKey('setting-switch-${s.key}'),
              value: s.boolValue,
              onChanged: _busy ? null : (v) => _put(v),
            ),
          ),
          child: _description,
        );
      case 'int' || 'float' when s.min != null && s.max != null:
        final min = s.min!.toDouble();
        final max = s.max!.toDouble();
        final step = (s.step ?? (s.type == 'int' ? 1 : (max - min) / 100))
            .toDouble();
        final current = s.numValue?.toDouble();
        return OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OmniLabelledSlider(
                key: ValueKey('setting-slider-${s.key}'),
                label: s.label,
                min: min,
                max: max,
                step: step > 0 ? step : null,
                value: (current ?? min).clamp(min, max),
                format: (v) => current == null && v == min
                    ? 'Not set'
                    : '${_fmt(v)}$_unit',
                onChangeEnd: _busy
                    ? null
                    : (v) {
                        // A tap can report its end twice; only a new value
                        // is written.
                        if (v == current) return;
                        _put(s.type == 'int' ? v.round() : _round(v));
                      },
              ),
              ?_description,
            ],
          ),
        );
      case 'enum' when s.options.isNotEmpty:
        final value = s.options.any((o) => o.value == s.textValue)
            ? s.textValue
            : null;
        return OmniCard(
          title: s.label,
          trailing: DropdownButton<String>(
            key: ValueKey('setting-enum-${s.key}'),
            value: value,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(OmniRadii.field),
            hint: Text(
              s.textValue.isEmpty ? 'Not set' : s.textValue,
              style: OmniText.caption,
            ),
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
          child: _description,
        );
      default:
        final numeric = s.type == 'int' || s.type == 'float';
        return OmniCard(
          title: s.label,
          trailing: Text(
            s.type == 'string' ? 'text' : s.type,
            style: OmniText.caption,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?_description,
              const SizedBox(height: OmniSpace.xs),
              TextField(
                key: ValueKey('setting-text-${s.key}'),
                controller: _text,
                keyboardType: numeric
                    ? const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      )
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: s.label,
                  hintText: 'Not set',
                  suffixText: s.unit,
                  suffixIcon: OmniIconAction(
                    key: ValueKey('setting-save-${s.key}'),
                    icon: OmniIcons.check,
                    label: 'Save ${s.label}',
                    color: OmniColors.accent,
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
                  ),
                ),
              ),
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
class AllSettingsPage extends StatefulWidget {
  const AllSettingsPage({super.key, required this.tv, this.namespace});

  final TvController tv;

  /// The namespace shown first.
  final String? namespace;

  @override
  State<AllSettingsPage> createState() => _AllSettingsPageState();
}

class _AllSettingsPageState extends State<AllSettingsPage> {
  late var _ns = widget.namespace ?? tvNamespaces.first;
  late final _opened = {_ns};

  @override
  Widget build(BuildContext context) => OmniPage(
    title: 'All settings',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniSegmented<String>(
          key: const ValueKey('raw-namespaces'),
          segments: [for (final n in tvNamespaces) OmniSegment(n, _capital(n))],
          selected: _ns,
          onChanged: (n) => setState(() {
            _ns = n;
            _opened.add(n);
          }),
        ),
        Expanded(
          child: IndexedStack(
            index: tvNamespaces.indexOf(_ns),
            children: [
              for (final n in tvNamespaces)
                _opened.contains(n)
                    ? _NamespaceList(tv: widget.tv, namespace: n)
                    : const SizedBox.shrink(),
            ],
          ),
        ),
      ],
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

class _NamespaceListState extends State<_NamespaceList> {
  List<TvRawSetting>? _settings;
  String? _error;
  final _search = TextEditingController();

  TvController get tv => widget.tv;
  String get ns => widget.namespace;

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
    if (!mounted) return;
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
    final settingKey = newKey.trim();
    final newValue = await askText(
      context,
      title: settingKey,
      label: 'Value',
      initial: value ?? '',
      action: 'Save',
      // The engine takes one line: a setting value has no line breaks.
      validate: (v) => v.contains('\n') ? 'One line only' : null,
    );
    if (newValue == null || newValue == value || !mounted) return;
    final ok = await confirm(
      context,
      title: 'Write $ns/$settingKey?',
      body:
          'This writes "$newValue" straight to the ${tv.noun} with no checks. A wrong '
          'value can change how the ${tv.noun} behaves until it is set back.',
      action: 'Write',
      destructive: true,
    );
    if (!ok) return;
    final result = await tv.call(
      TvCalls.settingsPut,
      TvCalls.settingPutArgs(tv.id, ns, settingKey, newValue),
    );
    if (result['ok'] == true) {
      showMessage('Saved $settingKey');
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
          'The ${tv.noun} goes back to its built-in default for it, which may not be '
          'what it had before.',
      action: 'Delete',
      destructive: true,
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
    final query = _search.text.trim().toLowerCase();
    final settings = [
      for (final s in _settings ?? const <TvRawSetting>[])
        if (query.isEmpty ||
            s.key.toLowerCase().contains(query) ||
            (s.value ?? '').toLowerCase().contains(query))
          s,
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('raw-search-$ns'),
                  controller: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(OmniIcons.search),
                    hintText: 'Search ${_settings?.length ?? ''} $ns settings',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              OmniIconAction(
                key: ValueKey('raw-add-$ns'),
                icon: OmniIcons.add,
                label: 'Add a $ns setting',
                onPressed: () => _edit(),
              ),
            ],
          ),
          if (_error != null)
            TvLoadError(
              what: 'The $ns settings',
              reason: _error!,
              onRetry: _load,
            )
          else if (_settings == null)
            const TvLoading(label: 'Reading the settings')
          else if (settings.isEmpty)
            const OmniEmptyState(
              icon: OmniIcons.search,
              title: 'No setting matches',
            )
          else
            for (final s in settings)
              OmniListRow(
                key: ValueKey('raw-$ns.${s.key}'),
                title: s.key,
                subtitle: s.value ?? 'null',
                subtitleLines: 2,
                onTap: () => _edit(key: s.key, value: s.value),
                trailing: OmniIconAction(
                  key: ValueKey('raw-delete-$ns.${s.key}'),
                  icon: OmniIcons.delete,
                  label: 'Delete ${s.key}',
                  onPressed: () => _delete(s.key),
                ),
              ),
        ],
      ),
    );
  }
}
