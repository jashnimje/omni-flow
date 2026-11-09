import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../device_sheets.dart' show confirm;
import 'tv_controller.dart';
import 'tv_widgets.dart';

class TvAppsTab extends ConsumerStatefulWidget {
  const TvAppsTab({super.key, required this.tv});

  final TvController tv;

  @override
  ConsumerState<TvAppsTab> createState() => _TvAppsTabState();
}

class _TvAppsTabState extends ConsumerState<TvAppsTab>
    with AutomaticKeepAliveClientMixin {
  var _filter = AppFilter.user;
  List<TvApp>? _apps;
  String? _error;
  final _search = TextEditingController();
  var _installing = false;

  TvController get tv => widget.tv;

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
      TvCalls.apps,
      TvCalls.appsArgs(tv.id, _filter),
    );
    if (!mounted) return;
    setState(() {
      if (result['ok'] == true) {
        _apps = TvCalls.appsOf(
          result,
        )..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        for (final a in _apps!) {
          if (a.label != null) tv.appLabels[a.package] = a.label!;
        }
      } else {
        _error = errorMessage(result);
      }
    });
  }

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
        );
        if (result['ok'] == true) showMessage('Installed ${apk.name}');
      }
    } finally {
      await files.cleanup();
      if (mounted) setState(() => _installing = false);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final query = _search.text.trim().toLowerCase();
    final apps = [
      for (final a in _apps ?? const <TvApp>[])
        if (query.isEmpty ||
            a.name.toLowerCase().contains(query) ||
            a.package.toLowerCase().contains(query))
          a,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('apps-search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search apps',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                key: const ValueKey('apps-install'),
                onPressed: _installing ? null : _install,
                icon: const Icon(Icons.install_mobile),
                label: const Text('Install APK'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SegmentedButton<AppFilter>(
            key: const ValueKey('apps-filter'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: AppFilter.user, label: Text('Installed')),
              ButtonSegment(value: AppFilter.system, label: Text('System')),
              ButtonSegment(value: AppFilter.all, label: Text('All')),
            ],
            selected: {_filter},
            onSelectionChanged: (s) {
              setState(() => _filter = s.first);
              unawaited(_load());
            },
          ),
        ),
        TransferProgress(tv: tv),
        Expanded(
          child: _error != null
              ? TvEmpty(text: _error!, onRetry: _load)
              : _apps == null
              ? const Center(child: CircularProgressIndicator())
              : apps.isEmpty
              ? TvEmpty(text: query.isEmpty ? 'No apps here' : 'No app matches')
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    key: const ValueKey('apps-list'),
                    itemCount: apps.length,
                    itemBuilder: (context, i) {
                      final a = apps[i];
                      return ListTile(
                        key: ValueKey('app-${a.package}'),
                        leading: CircleAvatar(
                          child: Text(
                            a.name.isEmpty ? '?' : a.name[0].toUpperCase(),
                          ),
                        ),
                        title: Text(a.name),
                        subtitle: Text(
                          [
                            if (a.label != null) a.package,
                            if (a.versionName != null) a.versionName!,
                            if (a.sizeBytes != null) formatBytes(a.sizeBytes),
                          ].join('  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: a.enabled
                            ? (a.system
                                  ? const Icon(Icons.shield_outlined, size: 18)
                                  : null)
                            : const Chip(
                                label: Text('Disabled'),
                                visualDensity: VisualDensity.compact,
                              ),
                        onTap: () => _openApp(a),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _openApp(TvApp app) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AppSheet(tv: tv, app: app),
    );
    if (changed == true) await _load();
  }
}

/// Everything that can be done to one app. Pops true when the app list
/// needs reading again.
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
        title: Text(app.name),
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
    }) {
      final color = danger ? Theme.of(context).colorScheme.error : null;
      return ListTile(
        key: ValueKey('app-$key'),
        enabled: !_busy,
        leading: Icon(icon, color: color),
        title: Text(label, style: TextStyle(color: color)),
        onTap: onTap,
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(
                app.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              subtitle: Text(
                [
                  app.package,
                  if (app.versionName != null) 'Version ${app.versionName}',
                  if (app.sizeBytes != null) formatBytes(app.sizeBytes),
                  if (app.system) 'System app',
                  if (!app.enabled) 'Disabled',
                ].join('\n'),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            const Divider(height: 1),
            if (app.launchable || app.enabled)
              action(
                'open',
                Icons.open_in_new,
                'Open on the TV',
                () => _run(AppAction.open, done: 'Opened ${app.name}'),
              ),
            action(
              'stop',
              Icons.stop_circle_outlined,
              'Force stop',
              () => _run(AppAction.stop, done: 'Stopped ${app.name}'),
            ),
            action(
              'clear-cache',
              Icons.cleaning_services_outlined,
              'Clear cache',
              () => _run(AppAction.clearCache, done: 'Cleared the cache'),
            ),
            action(
              'clear-data',
              Icons.delete_sweep_outlined,
              'Clear data',
              () => _run(
                AppAction.clearData,
                ask: 'Clear all data of ${app.name}?',
                body:
                    'Its accounts, sign-ins, downloads and settings on the TV '
                    'are deleted. This cannot be undone.',
                done: 'Cleared the data of ${app.name}',
                reload: true,
              ),
              danger: true,
            ),
            if (app.enabled)
              action(
                'disable',
                Icons.block,
                'Disable',
                () => _run(
                  AppAction.disable,
                  ask: 'Disable ${app.name}?',
                  body: app.system
                      ? 'It is a system app. The TV can stop working properly '
                            'until it is enabled again.'
                      : 'It stops running and leaves the home screen until '
                            'it is enabled again.',
                  done: 'Disabled ${app.name}',
                  reload: true,
                ),
                danger: true,
              )
            else
              action(
                'enable',
                Icons.check_circle_outline,
                'Enable',
                () => _run(
                  AppAction.enable,
                  done: 'Enabled ${app.name}',
                  reload: true,
                ),
              ),
            action(
              'uninstall',
              Icons.delete_forever_outlined,
              app.system ? 'Uninstall updates or remove' : 'Uninstall',
              () => _run(
                AppAction.uninstall,
                ask: 'Uninstall ${app.name}?',
                body: 'The app and all its data leave the TV.',
                done: 'Uninstalled ${app.name}',
                reload: true,
              ),
              danger: true,
            ),
            action(
              'info',
              Icons.info_outline,
              'App info',
              () => _run(AppAction.info),
            ),
          ],
        ),
      ),
    );
  }
}
