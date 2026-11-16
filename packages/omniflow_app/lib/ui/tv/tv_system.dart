import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'tv_controller.dart';
import 'tv_widgets.dart' show appNameOf;

/// "1.4 GB", "820 MB".
String sizeText(int kb) => kb >= 1024 * 1024
    ? '${(kb / (1024 * 1024)).toStringAsFixed(1)} GB'
    : '${(kb / 1024).round()} MB';

String _rate(double bytesPerSecond) => bytesPerSecond >= 1024 * 1024
    ? '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s'
    : '${(bytesPerSecond / 1024).round()} KB/s';

String _uptime(int s) {
  final d = s ~/ 86400;
  final h = (s % 86400) ~/ 3600;
  final m = (s % 3600) ~/ 60;
  return [if (d > 0) '$d d', if (d > 0 || h > 0) '$h h', '$m min'].join(' ');
}

/// 4.7: how the TV is doing (processor, memory, storage, network,
/// temperature), what runs on it with Stop, and the TV-wide actions: clear
/// every app's cache, restart and turn off.
class TvSystemTab extends ConsumerStatefulWidget {
  const TvSystemTab({super.key, required this.tv, required this.active});

  final TvController tv;
  final bool active;

  @override
  ConsumerState<TvSystemTab> createState() => _TvSystemTabState();
}

class _TvSystemTabState extends ConsumerState<TvSystemTab> {
  static const _every = Duration(seconds: 3);

  TvSystem? _system;
  List<TvProcess>? _apps;
  String? _error;
  ({int rx, int tx, DateTime at})? _lastNet;
  ({double rx, double tx})? _rates;
  Timer? _timer;
  var _reading = false;

  TvController get tv => widget.tv;

  /// Whether the app is in front: no reads behind the lock screen.
  var _inFront = true;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _inFront = false;
        _sync();
      },
      onShow: () {
        _inFront = true;
        _sync();
      },
    );
    _sync();
  }

  @override
  void didUpdateWidget(TvSystemTab old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _timer?.cancel();
    super.dispose();
  }

  /// Reads only while the tab is on screen and the app is in front.
  void _sync() {
    if (widget.active && _inFront) {
      if (_timer != null) return;
      unawaited(_read());
      _timer = Timer.periodic(_every, (_) => _read());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final results = await Future.wait([
        tv.client.call(TvCalls.system, TvCalls.readArgs(tv.id)),
        tv.client.call(TvCalls.processes, TvCalls.readArgs(tv.id)),
      ]);
      if (!mounted) return;
      final system = results[0];
      final apps = results[1];
      setState(() {
        if (system['ok'] != true) {
          _error = errorMessage(system);
          return;
        }
        _error = null;
        final s = TvSystem.fromJson(system);
        final now = DateTime.now();
        final last = _lastNet;
        if (last != null && s.rxBytes != null && s.txBytes != null) {
          final secs = now.difference(last.at).inMilliseconds / 1000;
          if (secs > 0) {
            _rates = (
              rx: ((s.rxBytes! - last.rx) / secs).clamp(0, double.infinity),
              tx: ((s.txBytes! - last.tx) / secs).clamp(0, double.infinity),
            );
          }
        }
        if (s.rxBytes != null && s.txBytes != null) {
          _lastNet = (rx: s.rxBytes!, tx: s.txBytes!, at: now);
        }
        _system = s;
        if (apps['ok'] == true) _apps = processesOf(apps);
      });
    } finally {
      _reading = false;
    }
  }

  Future<void> _stopApp(TvProcess p) async {
    final r = await tv.call(
      TvCalls.app,
      TvCalls.appArgs(tv.id, p.package, AppAction.stop),
    );
    if (r['ok'] == true) {
      showMessage(
        'Stopped ${appNameOf(p.package, label: tv.appLabels[p.package])}',
      );
      await _read();
    }
  }

  Future<void> _trim() async {
    final ok = await confirm(
      context,
      title: 'Clear every app\'s cache?',
      body:
          'Apps keep their data and sign-ins. They load a little slower the '
          'first time after.',
      action: 'Clear caches',
    );
    if (!ok || !mounted) return;
    final r = await tv.call(TvCalls.cacheTrim, TvCalls.idArgs(tv.id));
    if (r['ok'] != true) return;
    final freed = (r['freedKb'] as num?)?.toInt();
    showMessage(
      freed == null || freed <= 0
          ? 'Caches cleared'
          : 'Caches cleared: ${sizeText(freed)} free again',
    );
    await _read();
  }

  Future<void> _power(TvPower action) async {
    final restart = action == TvPower.reboot;
    final ok = await confirm(
      context,
      title: restart ? 'Restart the ${tv.noun}?' : 'Turn the ${tv.noun} off?',
      body: restart
          ? 'Whatever is playing stops. It is back in about a minute.'
          : 'It switches off fully, so OmniFlow cannot wake it again until '
                'it is turned on with its remote.',
      action: restart ? 'Restart' : 'Turn off',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final r = await tv.call(TvCalls.power, TvCalls.powerArgs(tv.id, action));
    if (r['ok'] == true) {
      showMessage(
        restart
            ? 'The ${tv.noun} is restarting'
            : 'The ${tv.noun} is turning off',
      );
    }
  }

  Widget _bar(String label, double? fraction, String value, {Key? key}) =>
      Padding(
        key: key,
        padding: const EdgeInsets.only(bottom: OmniSpace.sm),
        child: MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(label)),
                  Text(value, style: OmniText.caption),
                ],
              ),
              const SizedBox(height: 4),
              ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction?.clamp(0.0, 1.0),
                    minHeight: 6,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = _system;
    final apps = _apps;
    final memTotal = s?.memoryTotalKb;
    final memFree = s?.memoryAvailableKb;
    return ListView(
      key: const ValueKey('tv-system'),
      padding: OmniSpace.screenPadding,
      children: [
        if (_error case final e?)
          OmniBanner.error(e, actionLabel: 'Try again', onAction: _read)
        else if (s == null)
          const Padding(
            padding: EdgeInsets.all(OmniSpace.xl),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          const OmniSectionHeader('How it is doing'),
          OmniCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _bar(
                  'Processor',
                  s.cpuPercent == null ? null : s.cpuPercent! / 100,
                  s.cpuPercent == null ? '–' : '${s.cpuPercent!.round()}%',
                  key: const ValueKey('tv-cpu'),
                ),
                if (memTotal != null && memFree != null)
                  _bar(
                    'Memory',
                    (memTotal - memFree) / memTotal,
                    '${sizeText(memTotal - memFree)} of ${sizeText(memTotal)}',
                    key: const ValueKey('tv-memory'),
                  ),
                for (final (i, d) in s.storage.indexed)
                  // Shared storage is often the same disk as apps' storage:
                  // shown once then.
                  if (d.sizeKb > 0 &&
                      !s.storage
                          .take(i)
                          .any(
                            (o) => o.sizeKb == d.sizeKb && o.usedKb == d.usedKb,
                          ))
                    _bar(
                      switch (d.mount) {
                        '/data' => 'Storage',
                        '/sdcard' => 'Shared storage',
                        final m => 'Storage $m',
                      },
                      d.usedKb / d.sizeKb,
                      '${sizeText(d.usedKb)} of ${sizeText(d.sizeKb)}',
                      key: ValueKey('tv-storage-${d.mount}'),
                    ),
              ],
            ),
          ),
          if (_rates case final r?)
            OmniListRow(
              key: const ValueKey('tv-network'),
              icon: OmniIcons.network,
              title: 'Network',
              subtitle: 'down ${_rate(r.rx)} · up ${_rate(r.tx)}',
            ),
          if (s.temperatureC case final t?)
            OmniListRow(
              key: const ValueKey('tv-temperature'),
              icon: OmniIcons.temperature,
              title: 'Temperature',
              subtitle: '${t.round()} °C',
            ),
          if (s.uptimeSeconds case final up?)
            OmniListRow(
              key: const ValueKey('tv-uptime'),
              icon: OmniIcons.time,
              title: 'On for',
              subtitle: _uptime(up),
            ),
        ],
        const OmniSectionHeader('Running apps'),
        if (apps == null && _error == null)
          const SizedBox(height: 40)
        else if (apps != null && apps.isEmpty)
          const Text('Nothing else is running.', style: OmniText.caption)
        else
          for (final p in apps ?? const <TvProcess>[])
            OmniListRow(
              key: ValueKey('tv-process-${p.package}'),
              icon: p.foreground ? OmniIcons.play : OmniIcons.system,
              title: appNameOf(p.package, label: tv.appLabels[p.package]),
              subtitle:
                  '${p.foreground ? 'on screen · ' : ''}${sizeText(p.memoryKb)}',
              trailing: TextButton(
                key: ValueKey('tv-process-stop-${p.package}'),
                onPressed: () => _stopApp(p),
                child: const Text('Stop'),
              ),
            ),
        OmniSectionHeader('The whole ${tv.noun}'),
        OmniListRow(
          key: const ValueKey('tv-trim-caches'),
          icon: OmniIcons.cleaning,
          title: 'Clear every app\'s cache',
          subtitle: 'frees space, keeps data and sign-ins',
          onTap: _trim,
        ),
        OmniListRow(
          key: const ValueKey('tv-reboot'),
          icon: OmniIcons.retry,
          title: 'Restart the ${tv.noun}',
          onTap: () => _power(TvPower.reboot),
        ),
        OmniListRow(
          key: const ValueKey('tv-shutdown'),
          icon: OmniIcons.shutdown,
          title: 'Turn the ${tv.noun} off',
          subtitle: 'fully off: only its remote turns it on again',
          onTap: () => _power(TvPower.shutdown),
        ),
        const SizedBox(height: OmniSpace.xl),
      ],
    );
  }
}
