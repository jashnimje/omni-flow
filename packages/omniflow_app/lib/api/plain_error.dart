/// Engine errors in words a person can act on.
///
/// Engine messages are written for the CLI as well ("Pair it first: omni
/// device pair tv", "Set it with omni secret set") and background failures
/// can carry an exception's class name. The app never shows either: it keeps
/// the engine's wording when it is already plain, swaps a CLI hint for what
/// to do in the app, and falls back to a sentence per error type.
library;

final _cliHint = RegExp(
  r'[.,;:]?\s*[^.]*\bomni [a-z]+[^.]*\.?',
  caseSensitive: false,
);
final _typeName = RegExp(r'^\s*([A-Z][A-Za-z]*(Exception|Error))\s*:\s*');

/// What the app does instead of each CLI hint, by error type.
const _inApp = {
  'needs_user': 'Pair it from its page first.',
  'missing_secret': 'Open the device and add the missing key or password.',
  'secret_rejected': 'Open the device and enter the key or password again.',
  'host_key': 'Its SSH host key changed. Open the device, then SSH host key, to check it.',
  'pairing_failed': 'Look at the device, allow OmniFlow, then try again.',
};

/// The sentence for an error type when the message has nothing usable left.
const _byType = {
  'timeout':
      'The device did not answer. Check that it is on and on this Wi-Fi.',
  'not_found': 'That is not here any more.',
  'invalid': 'Something in that is not valid.',
  'needs_user': 'This needs you first: pair it from its page.',
  'missing_secret': 'A key or password is missing.',
  'device_error': 'The device said no.',
  'unreachable': 'OmniFlow did not answer. Try again in a moment.',
  'internal': 'Something went wrong inside OmniFlow. Settings, Developer has the details.',
};

String plainError(String type, String? message) {
  var text = (message ?? '').trim();
  final hadType = _typeName.hasMatch(text);
  text = text.replaceFirst(_typeName, '');
  final hadCli = _cliHint.hasMatch(text);
  if (hadCli) text = text.replaceAll(_cliHint, '').trim();
  if (text.isNotEmpty && !text.endsWith('.')) text = '$text.';
  if (hadCli && _inApp[type] != null) text = '$text ${_inApp[type]}'.trim();
  if (text.isEmpty || (hadType && type == 'internal')) {
    return _byType[type] ?? 'Something went wrong.';
  }
  return text[0].toUpperCase() + text.substring(1);
}
