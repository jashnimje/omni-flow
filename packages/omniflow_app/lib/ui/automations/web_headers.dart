import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../state/providers.dart';
import '../design/design.dart';

/// One header of a web request step: a name, and a value either typed
/// or from a web secret, which the step names as `{"secret": name}`.
class WebHeaderRow {
  WebHeaderRow({String name = '', Object? value})
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value is String ? value : ''),
      secretName = TextEditingController(
        text: value is Map && value['secret'] is String
            ? value['secret'] as String
            : '',
      ),
      secretValue = TextEditingController(),
      fromSecret = value is Map,
      saved = value is Map && value['secret'] is String;

  final TextEditingController name;
  final TextEditingController value;
  final TextEditingController secretName;

  /// The secret typed here, sent once to web.secret.set and never kept.
  final TextEditingController secretValue;
  bool fromSecret;

  /// Whether the secret named in [secretName] is stored.
  bool saved;

  void dispose() {
    name.dispose();
    value.dispose();
    secretName.dispose();
    secretValue.dispose();
  }
}

/// The headers of a web request step while its form is open.
class WebHeadersController extends ChangeNotifier {
  WebHeadersController([Object? headers]) {
    if (headers is Map) {
      for (final e in headers.entries) {
        rows.add(WebHeaderRow(name: '${e.key}', value: e.value));
      }
    }
  }

  final rows = <WebHeaderRow>[];

  void add() {
    rows.add(WebHeaderRow());
    notifyListeners();
  }

  /// The row's fields still hold its controllers until the next frame.
  void removeAt(int i) {
    final row = rows.removeAt(i);
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  void changed() => notifyListeners();

  /// Why the headers cannot be used yet, or null.
  String? get whyNot {
    for (final r in rows) {
      final name = r.name.text.trim();
      if (name.isEmpty) return 'Give each header a name, or remove it';
      if (r.fromSecret && !r.saved) return 'Save the secret for $name first';
    }
    return null;
  }

  /// The step's `headers`, or null for none.
  Map<String, Object?>? get headers => rows.isEmpty
      ? null
      : {
          for (final r in rows)
            r.name.text.trim(): r.fromSecret
                ? {'secret': r.secretName.text.trim()}
                : r.value.text,
        };

  @override
  void dispose() {
    for (final r in rows) {
      r.dispose();
    }
    super.dispose();
  }
}

/// A web secret name from a header name: letters, digits, `_` and `-`,
/// starting with a letter.
String secretNameFor(String header) {
  final cleaned = header
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
      .replaceAll(RegExp(r'^[^a-z]+'), '');
  final name = cleaned.isEmpty ? 'web_key' : cleaned;
  return name.length > 64 ? name.substring(0, 64) : name;
}

/// The Headers part of a web request form: each header with its value
/// typed or from a secret, Add a header, and a Save secret button that
/// stores the secret through web.secret.set. A literal key in an auth
/// header is refused when the rule is saved, with the engine's hint.
class WebHeadersEditor extends ConsumerStatefulWidget {
  const WebHeadersEditor({super.key, required this.controller, this.onChanged});

  final WebHeadersController controller;

  /// Called on every change, so the form can say whether it is ready.
  final VoidCallback? onChanged;

  @override
  ConsumerState<WebHeadersEditor> createState() => _WebHeadersEditorState();
}

class _WebHeadersEditorState extends ConsumerState<WebHeadersEditor> {
  final _saving = <WebHeaderRow>{};
  final _shown = <WebHeaderRow>{};

  WebHeadersController get _c => widget.controller;

  void _notify() => widget.onChanged?.call();

  @override
  void initState() {
    super.initState();
    _c.addListener(_notify);
  }

  @override
  void dispose() {
    _c.removeListener(_notify);
    super.dispose();
  }

  Future<void> _save(WebHeaderRow r) async {
    setState(() => _saving.add(r));
    final reply = await ref
        .read(engineApiProvider)
        .setWebSecret(r.secretName.text.trim(), r.secretValue.text);
    if (!mounted) return;
    setState(() {
      _saving.remove(r);
      if (reply.ok) {
        r.saved = true;
        r.secretValue.clear();
      }
    });
    _c.changed();
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('http-headers'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: OmniSpace.sm),
      Semantics(
        header: true,
        child: const Text('Headers', style: OmniText.bodyStrong),
      ),
      const Text(
        'Keys, tokens and passwords go in a secret, which stays on this '
        'phone. A key typed into a header such as Authorization is refused.',
        style: OmniText.caption,
      ),
      for (final (i, r) in _c.rows.indexed) _row(i, r),
      Align(
        alignment: Alignment.centerLeft,
        child: OmniButton.ghost(
          key: const ValueKey('http-header-add'),
          label: 'Add a header',
          icon: OmniIcons.add,
          expand: false,
          onPressed: () {
            _c.add();
            setState(() {});
          },
        ),
      ),
    ],
  );

  Widget _row(int i, WebHeaderRow r) {
    final shown = _shown.contains(r);
    return Padding(
      key: ObjectKey(r),
      padding: const EdgeInsets.only(top: OmniSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('http-header-name-$i'),
                  controller: r.name,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Header name',
                    hintText: 'X-Api-Key',
                  ),
                  onChanged: (_) {
                    setState(() {});
                    _c.changed();
                  },
                ),
              ),
              OmniIconAction(
                key: ValueKey('http-header-remove-$i'),
                icon: OmniIcons.delete,
                label: 'Remove header ${r.name.text.trim()}',
                onPressed: () {
                  _shown.remove(r);
                  _saving.remove(r);
                  _c.removeAt(i);
                  setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: OmniSpace.xs),
          OmniSegmented<bool>(
            key: ValueKey('http-header-kind-$i'),
            segments: const [
              OmniSegment(false, 'Typed'),
              OmniSegment(true, 'From a secret'),
            ],
            selected: r.fromSecret,
            onChanged: (secret) {
              setState(() {
                r.fromSecret = secret;
                if (secret && r.secretName.text.trim().isEmpty) {
                  r.secretName.text = secretNameFor(r.name.text);
                  r.saved = false;
                }
              });
              _c.changed();
            },
          ),
          const SizedBox(height: OmniSpace.xs),
          if (!r.fromSecret)
            TextField(
              key: ValueKey('http-header-value-$i'),
              controller: r.value,
              decoration: const InputDecoration(
                labelText: 'Value',
                hintText: 'application/json',
              ),
              onChanged: (_) => _c.changed(),
            )
          else ...[
            TextField(
              key: ValueKey('http-header-secret-name-$i'),
              controller: r.secretName,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Secret name',
                helperText: 'Other web requests can use the same secret.',
              ),
              onChanged: (_) {
                setState(() => r.saved = false);
                _c.changed();
              },
            ),
            const SizedBox(height: OmniSpace.xs),
            TextField(
              key: ValueKey('http-header-secret-value-$i'),
              controller: r.secretValue,
              obscureText: !shown,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: r.saved
                    ? 'New value (leave empty to keep the saved one)'
                    : 'Secret value',
                suffixIcon: OmniIconAction(
                  icon: shown
                      ? Symbols.visibility_off_rounded
                      : Symbols.visibility_rounded,
                  label: shown ? 'Hide the secret' : 'Show the secret',
                  onPressed: () =>
                      setState(() => shown ? _shown.remove(r) : _shown.add(r)),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.saved
                        ? 'Saved on this phone as ${r.secretName.text.trim()}'
                        : 'Not saved yet',
                    key: ValueKey('http-header-secret-state-$i'),
                    style: OmniText.caption.copyWith(
                      color: r.saved ? OmniColors.muted : OmniColors.warn,
                    ),
                  ),
                ),
                TextButton(
                  key: ValueKey('http-header-secret-save-$i'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(OmniSpace.target, OmniSpace.target),
                  ),
                  onPressed:
                      _saving.contains(r) ||
                          r.secretValue.text.isEmpty ||
                          r.secretName.text.trim().isEmpty
                      ? null
                      : () => _save(r),
                  child: const Text('Save secret'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
