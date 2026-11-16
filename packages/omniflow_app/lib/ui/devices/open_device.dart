import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../api/tv_calls.dart';
import '../../state/providers.dart';
import '../boards/board_page.dart' show BoardPage;
import '../design/design.dart';
import '../shell/links.dart';
import '../tags/tag_page.dart' show TagPage;
import '../tv/tv_page.dart';
import 'device_page.dart';
import 'device_text.dart';
import 'sensor_page.dart';

/// Opens a device's page on top of the tab it was tapped in. With
/// [source] (the tile's context) the page grows out of the tile.
Future<void> openDevice(
  BuildContext context,
  String id, {
  BuildContext? source,
}) => OmniContainerRoute.open<void>(
  context,
  source: source,
  settings: RouteSettings(name: DeviceLink(id).location),
  builder: (_) => DeviceRoute(id: id),
);

/// The page a device gets: the Android device page for a TV or another
/// phone, the board page for a board, the tag page for an NFC tag, the
/// sensor page for a thing that only reports, the device page otherwise.
class DeviceRoute extends ConsumerWidget {
  const DeviceRoute({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final json = devices.value?.where((d) => d['id'] == id).firstOrNull;
    if (json == null) return DeviceGone(loading: devices.isLoading);
    final d = DeviceView(json);
    if (TvCalls.isPhone(json)) return TvPage(id: id, name: d.name, phone: true);
    return switch (kindOf(d)) {
      DeviceKind.tv => TvPage(id: id, name: d.name),
      DeviceKind.board => BoardPage(id: id),
      DeviceKind.tag => TagPage(id: id),
      DeviceKind.sensor => SensorPage(id: id),
      _ => DevicePage(id: id),
    };
  }
}

/// A device page with no device: the page skeleton while the list loads,
/// then that it is not here any more. Every device page shows it.
class DeviceGone extends StatelessWidget {
  const DeviceGone({super.key, required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) => DetailPage(
    title: 'Device',
    state: loading ? const OmniLoad.loading() : const OmniLoad.empty(),
    notFound: const OmniEmptyState(
      key: ValueKey('device-gone'),
      icon: AreaIcons.notFound,
      title: 'This device is not here any more',
      message: 'It may have been removed.',
    ),
    children: (_) => const [],
  );
}
