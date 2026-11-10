import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_widgets.dart';

/// 4.2 Apps: search, Installed, System and All, Install APK, and one row per
/// app with its colour badge, label, package and version.
class TvAppsTab extends ConsumerStatefulWidget {
  const TvAppsTab({super.key, required this.tv});

  final TvController tv;

  @override
  ConsumerState<TvAppsTab> createState() => _TvAppsTabState();
}

class _TvAppsTabState extends ConsumerState<TvAppsTab> {
  var _filter = AppFilter.user;
  List<TvApp>? _apps;
  String? _error;
  final _search = TextEditingController();
  var _installing = false;

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
    setState(() => _error = null);
    final result = await tv.client.call(
      TvCalls.apps,
      TvCalls.appsArgs(tv.id, _filter),
    );
    if (!mounted) return;
    setState(() {
      if (result['ok'] == true) {
        _apps = TvCalls.appsOf(result)
          ..sort(
            (a, b) => _name(a).toLowerCase().compareTo(_name(b).toLowerCase()),
          );
        for (final a in _apps!) {
          if (a.label != null) tv.appLabels[a.package] = a.label!;
        }
      } else {
        _error = errorMessage(result);
      }
    });
    tv.labelsChanged();
  }

  static String _name(TvApp a) => appNameOf(a.package, label: a.label);

  Future<void> _install() async {
    final files = ref.read(phoneFilesProvider);
    final picked = await files.pick(extensions: const ['apk']);
    if (picked.isEmpty || !mounted) return;
    setState(() => _installing = true);
    try {
      for (final apk in picked) {
        final result = await tv.transfer(
          TvCalls.install,
          TvCalls.installArgs(tv.id, apk.path),
          name: apk.name,
        );
        if (result['ok'] == true) showMessage('Installed ${apk.name}');
      }
    } finally {
      await files.cleanup();
      if (mounted) setState(() => _installing = false);
    }
    await _load();
  }

  void _setFilter(AppFilter f) {
    if (f == _filter) return;
    setState(() => _filter = f);
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final all = _apps;
    final apps = [
      for (final a in all ?? const <TvApp>[])
        if (query.isEmpty ||
            _name(a).toLowerCase().contains(query) ||
            a.package.toLowerCase().contains(query))
          a,
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('apps-list'),
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
        children: [
          TextField(
            key: const ValueKey('apps-search'),
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(OmniIcons.search),
              hintText: all == null
                  ? 'Search apps'
                  : 'Search ${all.length} apps',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: OmniSpace.xs),
          Wrap(
            spacing: OmniSpace.xs,
            children: [
              for (final (f, label) in const [
                (AppFilter.user, 'Installed'),
                (AppFilter.system, 'System'),
                (AppFilter.all, 'All'),
              ])
                OmniFilterChip(
                  key: ValueKey('apps-filter-${f.name}'),
                  label: label,
                  selected: _filter == f,
                  onTap: () => _setFilter(f),
                ),
              OmniFilterChip(
                key: const ValueKey('apps-install'),
                label: 'Install APK',
                icon: OmniIcons.add,
                onTap: _installing ? null : _install,
              ),
            ],
          ),
          TransferProgress(tv: tv),
          if (_error != null)
            TvLoadError(what: 'The apps', reason: _error!, onRetry: _load)
          else if (all == null)
            const TvLoading(label: 'Reading the apps')
          else if (apps.isEmpty)
            OmniEmptyState(
              icon: OmniIcons.search,
              title: query.isEmpty ? 'No apps here' : 'No app matches',
              message: query.isEmpty
                  ? 'Try System or All.'
                  : 'Search looks at names and packages.',
            )
          else
            for (final a in apps) _row(a),
        ],
      ),
    );
  }

  Widget _row(TvApp a) {
    final name = _name(a);
    final running = tv.state.app == a.package;
    return OmniListRow(
      key: ValueKey('app-${a.package}'),
      leading: AppBadge(package: a.package, name: name),
      title: name,
      subtitle: [a.package, ?a.versionName].join(' · '),
      value: running
          ? 'running'
          : !a.enabled
          ? 'disabled'
          : null,
      valueColor: running ? OmniColors.accent : OmniColors.muted,
      chevron: true,
      onTap: () => _openApp(a),
    );
  }

  Future<void> _openApp(TvApp app) async {
    final changed = await showOmniSheet<bool>(
      context,
      builder: (_) => AppSheet(tv: tv, app: app),
    );
    if (changed == true) await _load();
  }
}

/// Everything that can be done to one app. Pops true when the app list
/// needs reading again. Clear data, disable and uninstall ask first and say
/// what is lost.
class AppSheet extends StatefulWidget {
  const AppSheet({super.key, required this.tv, required this.app});

  final TvController tv;
  final TvApp app;

  @override
  State<AppSheet> createState() => _AppSheetState();
}

class _AppSheetState extends State<AppSheet> {
  var _busy = false;

  TvApp get app => widget.app;
  String get _name => appNameOf(app.package, label: app.label);

  Future<void> _run(
    AppAction action, {
    String? ask,
    String? body,
    String? done,
    bool reload = false,
  }) async {
    if (ask != null) {
      final ok = await confirm(
        context,
        title: ask,
        body: body ?? '',
        destructive: true,
        action: switch (action) {
          AppAction.uninstall => 'Uninstall',
          AppAction.clearData => 'Clear data',
          AppAction.disable => 'Disable',
          _ => 'Go ahead',
        },
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final result = await widget.tv.call(
      TvCalls.app,
      TvCalls.appArgs(widget.tv.id, app.package, action),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result['ok'] != true) return;
    if (action == AppAction.info) {
      await _showInfo(result);
      return;
    }
    if (done != null) showMessage(done);
    if (reload && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _showInfo(Json result) => showDialog<void>(
    context: context,
    builder: (context) {
      final info = TvCalls.appInfoOf(result);
      return AlertDialog(
        title: Text(_name),
        content: SingleChildScrollView(
          child: SelectableText(
            [for (final e in info.entries) '${e.key}: ${e.value}'].join('\n'),
            key: const ValueKey('app-info-text'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    Widget action(
      String key,
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool danger = false,
    }) => TvKeyButton(
      key: ValueKey('app-$key'),
      label: label,
      icon: icon,
      foreground: danger ? OmniColors.bad : OmniColors.text,
      onTap: _busy ? null : onTap,
    );

    return OmniSheet(
      title: _name,
      subtitle: [
        app.package,
        ?app.versionName,
        if (app.sizeBytes != null) formatBytes(app.sizeBytes),
        if (app.system) 'system app',
        if (!app.enabled) 'disabled',
      ].join(' · '),
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(bottom: OmniSpace.sm),
            child: OmniProgressBar(height: 4, semanticLabel: 'Working'),
          ),
        const SizedBox(height: OmniSpace.xs),
        TvKeyGrid(
          columns: 3,
          children: [
            action(
              'open',
              TvIcons.open,
              'Open',
              () => _run(AppAction.open, done: 'Opened $_name'),
            ),
            action(
              'stop',
              TvIcons.forceStop,
              'Stop',
              () => _run(AppAction.stop, done: 'Stopped $_name'),
            ),
            action(
              'clear-cache',
              TvIcons.cache,
              'Cache',
              () => _run(AppAction.clearCache, done: 'Cleared the cache'),
            ),
            action(
              'clear-data',
              TvIcons.data,
              'Data',
              () => _run(
                AppAction.clearData,
                ask: 'Clear all data of $_name?',
                body:
                    'Its accounts, sign-ins, downloads and settings on the TV '
                    'are deleted. This cannot be undone.',
                done: 'Cleared the data of $_name',
                reload: true,
              ),
            ),
            if (app.enabled)
              action(
                'disable',
                TvIcons.disable,
                'Disable',
                () => _run(
                  AppAction.disable,
                  ask: 'Disable $_name?',
                  body: app.system
                      ? 'It is a system app. The TV can stop working properly '
                            'until it is enabled again.'
                      : 'It stops running and leaves the home screen until '
                            'it is enabled again. Its data stays.',
                  done: 'Disabled $_name',
                  reload: true,
                ),
              )
            else
              action(
                'enable',
                TvIcons.enable,
                'Enable',
                () => _run(
                  AppAction.enable,
                  done: 'Enabled $_name',
                  reload: true,
                ),
              ),
            action(
              'uninstall',
              OmniIcons.delete,
              app.system ? 'Remove' : 'Uninstall',
              () => _run(
                AppAction.uninstall,
                ask: 'Uninstall $_name?',
                body:
                    'The app and all its data leave the TV: sign-ins, '
                    'downloads and settings. Installing it again starts '
                    'fresh.',
                done: 'Uninstalled $_name',
                reload: true,
              ),
              danger: true,
            ),
          ],
        ),
        const SizedBox(height: OmniSpace.sm),
        OmniButton.ghost(
          key: const ValueKey('app-info'),
          label: 'App info',
          icon: OmniIcons.info,
          onPressed: _busy ? null : () => _run(AppAction.info),
        ),
      ],
    );
  }
}
