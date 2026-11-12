import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/devices/device_text.dart';

void main() {
  test('the greeting follows the time of day, and 1 am is not morning', () {
    String at(int hour) => greeting(DateTime(2026, 11, 9, hour));
    expect(at(0), 'Good evening');
    expect(at(1), 'Good evening');
    expect(at(5), 'Good morning');
    expect(at(11), 'Good morning');
    expect(at(12), 'Good afternoon');
    expect(at(18), 'Good evening');
  });
}
