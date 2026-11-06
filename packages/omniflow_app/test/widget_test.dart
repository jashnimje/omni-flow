import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/main.dart';
import 'package:omniflow_engine/omniflow_engine.dart';

void main() {
  testWidgets('shows the embedded engine version', (tester) async {
    await tester.pumpWidget(const OmniFlowApp());
    expect(find.text('OmniFlow engine $omniflowEngineVersion'), findsOneWidget);
  });
}
