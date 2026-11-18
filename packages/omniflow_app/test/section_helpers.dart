import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the collapsed section keyed [key] when it is closed, scrolling to
/// it first.
Future<void> openSectionKey(WidgetTester tester, String key) async {
  final section = find.byKey(ValueKey(key));
  await tester.ensureVisible(section);
  await tester.pumpAndSettle();
  final header = find.descendant(
    of: section,
    matching: find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.expanded != null,
    ),
  );
  final open =
      tester.widget<Semantics>(header.first).properties.expanded ?? false;
  if (!open) {
    await tester.tap(header.first);
    await tester.pumpAndSettle();
  }
}
