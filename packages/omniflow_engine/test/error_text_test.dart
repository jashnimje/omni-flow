import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  group('asSentence', () {
    test('adds a full stop to plain words', () {
      expect(asSentence('The device said no'), 'The device said no.');
    });

    test('never doubles the end of a sentence', () {
      expect(
        asSentence('Bed lamp did not answer. Is it switched on?'),
        'Bed lamp did not answer. Is it switched on?',
      );
      expect(
        asSentence('Check that it is on and on this Wi-Fi.'),
        'Check that it is on and on this Wi-Fi.',
      );
      expect(asSentence('Stop!'), 'Stop!');
      expect(asSentence('It said "no."'), 'It said "no."');
    });

    test('trims, and leaves nothing as nothing', () {
      expect(asSentence('  Gone  '), 'Gone.');
      expect(asSentence('   '), '');
    });
  });
}
