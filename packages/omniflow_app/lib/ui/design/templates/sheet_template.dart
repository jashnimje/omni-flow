import 'package:flutter/material.dart';

import '../action_bar.dart';
import '../banner.dart';
import '../buttons.dart';
import '../icons.dart';
import '../sheet.dart';
import 'load_state.dart';

/// T6, every bottom sheet: the handle, [title], [subtitle] and
/// [trailing], the scrolling body, and the pinned action row
/// ([primaryLabel] and a ghost [secondaryLabel]) outside the scroll. The
/// last button always sits above the system navigation bar. It draws
/// skeleton rows, the error banner and a compact [empty] state from
/// [state]. Open it with [SheetTemplate.show].
class SheetTemplate extends StatelessWidget {
  const SheetTemplate({
    super.key,
    required this.children,
    this.title,
    this.subtitle,
    this.trailing,
    this.pinned,
    this.primaryLabel,
    this.onPrimary,
    this.primaryKey,
    this.destructive = false,
    this.secondaryLabel,
    this.onSecondary,
    this.missing,
    this.state = const OmniLoad.data(),
    this.empty,
    this.banners = const [],
  });

  final List<Widget> Function(BuildContext context) children;
  final String? title;
  final String? subtitle;
  final Widget? trailing;

  /// Stays in view above the scroll (a search field).
  final Widget? pinned;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final Key? primaryKey;

  /// Fills the primary red (Remove, Forget).
  final bool destructive;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? missing;
  final OmniLoad state;
  final Widget? empty;
  final List<Widget> banners;

  /// Opens [builder] (usually a [SheetTemplate]) over the whole app.
  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool dismissible = true,
  }) => showOmniSheet<T>(context, builder: builder, dismissible: dismissible);

  @override
  Widget build(BuildContext context) {
    final hasBar =
        state.isData && (primaryLabel != null || secondaryLabel != null);
    return OmniSheet(
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      pinned: pinned,
      actions: hasBar
          ? OmniActionBar(
              missing: onPrimary == null ? missing : null,
              secondary: secondaryLabel == null
                  ? null
                  : OmniButton.ghost(
                      key: const ValueKey('template-secondary'),
                      label: secondaryLabel!,
                      onPressed: onSecondary,
                    ),
              primary: primaryLabel == null
                  ? null
                  : OmniButton(
                      key: primaryKey ?? const ValueKey('template-primary'),
                      label: primaryLabel!,
                      kind: destructive
                          ? OmniButtonKind.destructive
                          : OmniButtonKind.primary,
                      onPressed: onPrimary,
                    ),
            )
          : null,
      children: omniStateChildren(
        context,
        state: state,
        skeletonRows: 3,
        empty:
            empty ??
            const OmniEmptyState(
              icon: OmniIcons.info,
              title: 'Nothing here yet',
              compact: true,
            ),
        banners: banners,
        data: children,
      ),
    );
  }
}

/// Asks for one line of text in a sheet (a name, a price): [label] on the
/// field, [action] to save. Returns the trimmed text, or null when the
/// user closes it. [validate] returns what is wrong, shown under the
/// field, and keeps Save off. Replaces the text prompt dialogs.
Future<String?> showPromptSheet(
  BuildContext context, {
  required String title,
  required String label,
  String? message,
  String initial = '',
  String action = 'Save',
  String? hint,
  TextInputType? keyboardType,
  int? maxLength,
  bool allowEmpty = false,
  String? Function(String text)? validate,
}) => showOmniSheet<String>(
  context,
  builder: (_) => PromptSheet(
    title: title,
    label: label,
    message: message,
    initial: initial,
    action: action,
    hint: hint,
    keyboardType: keyboardType,
    maxLength: maxLength,
    allowEmpty: allowEmpty,
    validate: validate,
  ),
);

/// The body of [showPromptSheet]: a [SheetTemplate] with one text field
/// and Save. Save pops the trimmed text.
class PromptSheet extends StatefulWidget {
  const PromptSheet({
    super.key,
    required this.title,
    required this.label,
    this.message,
    this.initial = '',
    this.action = 'Save',
    this.hint,
    this.keyboardType,
    this.maxLength,
    this.allowEmpty = false,
    this.validate,
  });

  final String title;
  final String label;
  final String? message;
  final String initial;
  final String action;
  final String? hint;
  final TextInputType? keyboardType;
  final int? maxLength;
  final bool allowEmpty;
  final String? Function(String text)? validate;

  @override
  State<PromptSheet> createState() => _PromptSheetState();
}

class _PromptSheetState extends State<PromptSheet> {
  late final _text = TextEditingController(text: widget.initial)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _value => _text.text.trim();

  String? get _issue => _value.isEmpty ? null : widget.validate?.call(_value);

  bool get _canSave =>
      (widget.allowEmpty || _value.isNotEmpty) && _issue == null;

  void _save() {
    if (_canSave) Navigator.of(context).pop(_value);
  }

  @override
  Widget build(BuildContext context) => SheetTemplate(
    title: widget.title,
    subtitle: widget.message,
    primaryLabel: widget.action,
    primaryKey: const ValueKey('prompt-save'),
    onPrimary: _canSave ? _save : null,
    children: (context) => [
      TextField(
        key: const ValueKey('prompt-field'),
        controller: _text,
        autofocus: true,
        keyboardType: widget.keyboardType,
        maxLength: widget.maxLength,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          errorText: _issue,
        ),
      ),
    ],
  );
}
