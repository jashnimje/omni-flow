import 'package:omniflow_engine/src/dag/conditions.dart';
import 'package:test/test.dart';

void main() {
  test('a boolean matches the word a device reports', () {
    expect(valuesEqual(true, 'on'), isTrue);
    expect(valuesEqual('On', true), isTrue);
    expect(valuesEqual(false, 'off'), isTrue);
    expect(valuesEqual(true, 'off'), isFalse);
    expect(valuesEqual(true, 'asleep'), isFalse);
    expect(valuesEqual('asleep', 'asleep'), isTrue);
    expect(valuesEqual(80, 80.0), isTrue);
  });
}
