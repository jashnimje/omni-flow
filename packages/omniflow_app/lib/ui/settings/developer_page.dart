import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import '../devices/device_text.dart';
import '../home/home_data.dart';
import '../shell/shell.dart';
import 'inspector.dart';
import 'settings_screen.dart' show engineStatusProvider;

enum DeveloperTab { packets, runs, drivers, engine }

/// The newest runs of every automation.
final runLogProvider = FutureProvider<List<RunRecord>>((ref) async {
  ref.watch(flowsProvider);
  return (await ref.watch(engineApiProvider).runLog(limit: 50)).or(const []);
});

/// 7.3: Packets (filterable), the run log, the drivers (built in and the
/// user's, with register from a file) and the engine's status.
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key, this.filter});

  /// Opens Packets filtered to this text (a device's address).
  final String? filter;

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  var _tab = DeveloperTab.packets;

  @override
  Widget build(BuildContext context) => OmniPage(
    title: 'Developer',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniSegmented<DeveloperTab>(
          key: const ValueKey('developer-tabs'),
          segments: const [
            OmniSegment(DeveloperTab.packets, 'Packets'),
            OmniSegment(DeveloperTab.runs, 'Run log'),
            OmniSegment(DeveloperTab.drivers, 'Drivers'),
            OmniSegment(DeveloperTab.engine, 'Engine'),
          ],
          selected: _tab,
          onChanged: (t) => setState(() => _tab = t),
        ),
        Expanded(
          child: switch (_tab) {
            DeveloperTab.packets => Inspector(filter: widget.filter),
            DeveloperTab.runs => const _RunLog(),
            DeveloperTab.drivers => const _Drivers(),
            DeveloperTab.engine => const _Engine(),
          },
        ),
      ],
    ),
  );
}

class _RunLog extends ConsumerWidget {
  const _RunLog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(runLogProvider).value;
    final names = {
      for (final a in ref.watch(summariesProvider).value ?? const [])
        a.id: a.name,
    };
    if (runs == null) return const SizedBox();
    if (runs.isEmpty) {
      return const OmniEmptyState(
        icon: OmniIcons.automations,
        title: 'No runs yet',
        message: 'Each time an automation runs it shows here.',
      );
    }
    return ListView(
      key: const ValueKey('run-log'),
      children: [
        for (final r in runs)
          OmniListRow(
            key: ValueKey('run-${r.id}'),
            leading: Icon(
              r.ok ? AreaIcons.ok : AreaIcons.failed,
              color: r.ok ? OmniColors.accent : OmniColors.bad,
              semanticLabel: r.ok ? 'Worked' : 'Failed',
            ),
            title: names[r.automationId] ?? r.automationId,
            subtitle: [
              when(r.startedAt),
              '${r.steps.length} step${r.steps.length == 1 ? '' : 's'}',
              if (r.duration case final d?)
                '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s',
              if (!r.ok && r.reason != null) r.reason!,
              if (r.dryRun) 'test',
            ].join(' · '),
            chevron: true,
            onTap: () => ref
                .read(shellControllerProvider)
                .open(RunLink(r.automationId, r.id)),
          ),
      ],
    );
  }
}

class _Drivers extends ConsumerWidget {
  const _Drivers();

  Future<void> _register(WidgetRef ref) async {
    final files = ref.read(phoneFilesProvider);
    final picked = await files.pick(extensions: const ['json']);
    if (picked.isEmpty) return;
    Object? manifest;
    try {
      manifest = jsonDecode(await File(picked.first.path).readAsString());
    } on Object {
      manifest = null;
    } finally {
      await files.cleanup();
    }
    if (manifest is! Map) {
      showMessage('${picked.first.name} is not a driver file (JSON).');
      return;
    }
    final added = await ref
        .read(engineApiProvider)
        .registerDriver(Map<String, Object?>.from(manifest));
    if (added.ok) {
      ref.invalidate(driversProvider);
      showMessage('Added the driver ${added.value ?? picked.first.name}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers =
        (ref.watch(driversProvider).value ?? const {}).values.toList()
          ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return ListView(
      key: const ValueKey('drivers-list'),
      children: [
        OmniButton.ghost(
          key: const ValueKey('driver-register'),
          label: 'Register a driver from a file',
          icon: OmniIcons.add,
          onPressed: () => _register(ref),
        ),
        const SizedBox(height: OmniSpace.sm),
        for (final d in drivers)
          OmniListRow(
            key: ValueKey('driver-${d['id']}'),
            icon: OmniIcons.forCategory(d['category'] as String?),
            title: shortDriverName(d, '${d['id']}'),
            subtitle: [
              if (d['builtIn'] == true) 'built in' else 'added by you',
              '${d['transport']}',
              if (d['highRisk'] == true) 'runs commands, asks first',
            ].join(' · '),
            dot: d['highRisk'] == true ? StatusKind.warning : null,
          ),
      ],
    );
  }
}

class _Engine extends ConsumerWidget {
  const _Engine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider);
    final s = status.value;
    final hubError = ref.watch(hubErrorProvider);
    if (s == null) return const SizedBox();
    final issues = [
      for (final i in (s['loadIssues'] as List? ?? const []))
        if (i is Map) Map<String, Object?>.from(i),
    ];
    final flows = (s['flows'] as List? ?? const []).length;
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(engineStatusProvider),
      child: ListView(
        key: const ValueKey('engine-status'),
        children: [
          OmniListRow(
            title: 'Hub',
            value: s['hubRunning'] == true ? 'running' : 'stopped',
            valueColor: s['hubRunning'] == true
                ? OmniColors.accent
                : OmniColors.warn,
          ),
          if (hubError != null)
            OmniListRow(
              title: 'Hub start',
              subtitle: hubError,
              subtitleLines: 3,
            ),
          OmniListRow(title: 'Automations loaded', value: '$flows'),
          OmniListRow(
            title: 'Load issues',
            value: '${issues.length}',
            valueColor: issues.isEmpty ? OmniColors.accent : OmniColors.warn,
          ),
          for (final i in issues)
            OmniListRow(
              icon: OmniIcons.warning,
              title: '${i['kind'] ?? 'record'} ${i['id'] ?? ''}',
              subtitle: '${i['error'] ?? i['message'] ?? ''}',
              subtitleLines: 3,
            ),
        ],
      ),
    );
  }
}
