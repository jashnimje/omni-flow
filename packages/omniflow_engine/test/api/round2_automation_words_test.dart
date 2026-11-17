import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:omniflow_engine/src/api/automation_view.dart'
    show SentenceContext;
import 'package:omniflow_engine/src/dag/templates.dart'
    show ruleTemplates, templateCategories;
import 'package:test/test.dart';

void main() {
  final words = SentenceContext(
    names: const {'tv': 'Living room TV'},
    drivers: {'tv': DriverRegistry.withBuiltIns()['android_tv_adb']!},
  );

  test('a TV power check written as on reads as the TV being on', () {
    // `omni rule add --only-if tv.power_state=on` stores `value: true`.
    expect(
      words.condition({'state': 'tv.power_state', 'op': '==', 'value': true}),
      'Living room TV is on',
    );
    expect(
      words.condition({'state': 'tv.power_state', 'op': '!=', 'value': true}),
      'Living room TV is off',
    );
    expect(
      words.condition({'state': 'tv.power_state', 'op': '==', 'value': 'on'}),
      'Living room TV is on',
    );
  });

  test('the web value template has a group of its own', () {
    final web = ruleTemplates.singleWhere((t) => t.id == 'web_value_notify');
    expect(web.category, 'Web and data');
    expect(templateCategories, contains('Web and data'));
    expect(
      ruleTemplates
          .where((t) => t.category == 'Morning and night')
          .map((t) => t.id),
      isNot(contains('web_value_notify')),
    );
  });
}
