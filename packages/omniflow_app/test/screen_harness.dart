import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/state/providers.dart';
import 'package:omniflow_app/ui/theme.dart';

import 'fake_engine.dart';

/// Shows [page] on its own, as a page pushed over a root, with the app's
/// theme and snackbars, so a screen test does not depend on how the tabs
/// reach it. Back pops to a plain root page.
Future<void> pumpScreen(
  WidgetTester tester,
  FakeEngine engine,
  Widget page, {
  List<Override> overrides = const [],
  Size size = const Size(1236, 5400),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        engineConnectionProvider.overrideWithValue(engine),
        ...overrides,
      ],
      child: MaterialApp(
        theme: omniTheme(),
        scaffoldMessengerKey: messengerKey,
        home: _Root(page: page),
      ),
    ),
  );
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

class _Root extends StatefulWidget {
  const _Root({required this.page});

  final Widget page;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => widget.page));
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('root', key: ValueKey('root'))),
  );
}
