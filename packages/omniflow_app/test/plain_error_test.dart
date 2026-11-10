import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/api/plain_error.dart';

void main() {
  test('a CLI hint becomes what to do in the app', () {
    expect(
      plainError(
        'needs_user',
        'lounge_tv is not paired with OmniFlow yet. Pair it first: omni device pair lounge_tv',
      ),
      'Lounge_tv is not paired with OmniFlow yet. Pair it from its page first.',
    );
    expect(
      plainError(
        'missing_secret',
        'no secret stored for hall/token. Set it with omni secret set',
      ),
      'No secret stored for hall/token. Open the device and add the missing key or password.',
    );
  });

  test('an exception class name never shows', () {
    expect(
      plainError('timeout', 'SocketException: Connection reset by peer'),
      'Connection reset by peer.',
    );
    expect(
      plainError('internal', 'StateError: Bad state: No element'),
      'Something went wrong inside OmniFlow. Settings, Developer has the details.',
    );
  });

  test('a plain message is kept and an empty one gets a sentence', () {
    expect(plainError('timeout', 'no reply from tv'), 'No reply from tv.');
    expect(
      plainError('timeout', null),
      startsWith('The device did not answer'),
    );
    expect(plainError('weird', ''), 'Something went wrong.');
  });
}
