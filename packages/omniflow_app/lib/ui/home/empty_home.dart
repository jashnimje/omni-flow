import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../add/add_page.dart';
import '../add/guided_steps_page.dart';
import '../add/name_sheet.dart';
import '../design/design.dart';
import '../devices/device_text.dart';
import '../onboarding/start_options.dart';
import 'house_switcher.dart';

/// 8.2: Home with nothing added. It looks on the Wi-Fi at once and offers
/// what it found, each with Add.
class EmptyHome extends ConsumerStatefulWidget {
  const EmptyHome({super.key});

  @override
  ConsumerState<EmptyHome> createState() => _EmptyHomeState();
}

class _EmptyHomeState extends ConsumerState<EmptyHome> {
  List<FoundThing>? _found;

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    setState(() => _found = null);
    final reply = await ref.read(engineApiProvider).discover();
    if (!mounted) return;
    setState(
      () => _found = [
        for (final f in reply.value?.found ?? const [])
          if (f.candidate['knownAs'] == null) f,
      ],
    );
  }

  Future<void> _add(Json candidate) async {
    final named = await askName(
      context,
      title: 'Add ${candidate['name'] ?? 'it'}',
      name: '${candidate['name'] ?? ''}',
      room: candidate['room'] as String?,
    );
    if (named == null || !mounted) return;
    await addAndFollow(
      context,
      ref,
      candidate,
      name: named.name,
      room: named.room,
    );
  }

  String? get _wifi {
    for (final d in ref.read(devicesProvider).value ?? const <Json>[]) {
      if (d['driver'] != 'phone') continue;
      final ssid = DeviceView(d).state['wifi_ssid'];
      if (ssid is String && ssid.isNotEmpty) return ssid;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    final where = _wifi == null ? 'your Wi-Fi' : _wifi!;
    final message = switch (found) {
      null => 'Looking on $where...',
      [] => 'We looked on $where and found nothing new yet.',
      [_] => 'We looked on $where and found 1 thing.',
      _ => 'We looked on $where and found ${found.length} things.',
    };
    // Home's empty state. The shell hides its Add button here, since the
    // page carries its own add actions.
    return TabPage(
      key: const ValueKey('empty-home'),
      title: 'Welcome',
      fab: false,
      house: const HouseSwitcher(),
      children: (context) => [
        OmniEmptyState(
          icon: OmniIcons.search,
          title: 'Nothing added yet',
          message: message,
          padding: const EdgeInsets.fromLTRB(
            OmniSpace.lg,
            OmniSpace.xxl,
            OmniSpace.lg,
            OmniSpace.lg,
          ),
        ),
        for (final f in found ?? const <FoundThing>[])
          OmniListRow(
            key: ValueKey(
              'found-${f.candidate['host'] ?? f.candidate['name']}',
            ),
            icon: OmniIcons.forCategory(f.category),
            title:
                '${f.candidate['name'] ?? shortDriverName(null, f.driverName)}',
            subtitle: [
              if (f.candidate['host'] case final String host) host,
              shortDriverName(null, f.driverName),
            ].join(' · '),
            value: 'Add',
            onTap: () => _add(f.candidate),
          ),
        const SizedBox(height: OmniSpace.md),
        if (found != null && found.isEmpty)
          OmniButton.ghost(
            key: const ValueKey('empty-look-again'),
            label: 'Look again',
            icon: OmniIcons.retry,
            onPressed: _look,
          ),
        const SizedBox(height: OmniSpace.sm),
        OmniButton.ghost(
          key: const ValueKey('add-device-empty'),
          label: 'Add something else',
          onPressed: () => openAddThing(context),
        ),
        const SizedBox(height: OmniSpace.md),
        const StartOptions(),
      ],
    );
  }
}
