import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'tile.dart' show OmniIconBox;
import 'tokens.dart';

/// A collapsed section (docs/ui/design-v2.md, The collapsed section): a
/// card whose header row shows an [icon], a [title], a one-line [summary]
/// that already answers the first question ("5 changes today", "Used in
/// 2") and a chevron. Tapping anywhere on the header opens it to show
/// [children]. It starts closed unless [initiallyOpen].
///
/// The open state is kept in the page's [PageStorage] under [storageId]
/// (the [title] by default), so a section scrolled out of a lazy list, or
/// a page come back to, stays as the user left it. The open and close
/// follow [OmniMotion.of], so they are instant under reduced motion.
/// Screen readers hear the header as a button with its expanded state.
///
/// A disclosure inside another one (Developer details inside More
/// settings) draws flat, as a row of its parent's card.
class OmniDisclosure extends StatefulWidget {
  const OmniDisclosure({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.summary,
    this.initiallyOpen = false,
    this.storageId,
    this.onChanged,
    this.margin = const EdgeInsets.only(bottom: OmniSpace.md),
  });

  final IconData icon;
  final String title;

  /// One line under the title. Null leaves a one-line row.
  final String? summary;
  final List<Widget> children;
  final bool initiallyOpen;

  /// Tells this section apart from others with the same [title] on one
  /// page.
  final String? storageId;

  /// Called with the new state after the user opens or closes it.
  final ValueChanged<bool>? onChanged;

  /// Space around the card. A nested disclosure ignores it.
  final EdgeInsetsGeometry margin;

  @override
  State<OmniDisclosure> createState() => _OmniDisclosureState();
}

class _OmniDisclosureState extends State<OmniDisclosure>
    with SingleTickerProviderStateMixin {
  late bool _open;
  late final AnimationController _controller;
  late final CurvedAnimation _size;

  String get _storageKey =>
      'omni-disclosure:${widget.storageId ?? widget.title}';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: OmniMotion.slow);
    _size = CurvedAnimation(
      parent: _controller,
      curve: OmniMotion.emphasizedIn,
      reverseCurve: OmniMotion.emphasizedOut,
    );
  }

  var _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = OmniMotion.of(context, OmniMotion.slow);
    if (_restored) return;
    _restored = true;
    final stored = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _storageKey);
    _open = stored is bool ? stored : widget.initiallyOpen;
    _controller.value = _open ? 1 : 0;
  }

  @override
  void dispose() {
    _size.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    PageStorage.maybeOf(context)
        ?.writeState(context, _open, identifier: _storageKey);
    if (_open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
    widget.onChanged?.call(_open);
  }

  @override
  Widget build(BuildContext context) {
    final palette = OmniPalette.of(context);
    final nested = _DisclosureScope.of(context);
    final w = widget;
    final summary = w.summary;
    final header = Semantics(
      container: true,
      button: true,
      expanded: _open,
      label: summary == null ? w.title : '${w.title}, $summary',
      excludeSemantics: true,
      onTap: _toggle,
      child: InkWell(
        onTap: _toggle,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: summary == null ? OmniSpace.row : OmniSpace.rowTwoLine,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OmniSpace.md,
              vertical: OmniSpace.sm,
            ),
            child: Row(
              children: [
                OmniIconBox(icon: w.icon, size: 40),
                const SizedBox(width: OmniSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        w.title,
                        style: OmniText.bodyStrong.copyWith(
                          color: palette.text,
                        ),
                      ),
                      if (summary != null)
                        Text(
                          summary,
                          style: OmniText.caption.copyWith(
                            color: palette.muted,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: OmniSpace.sm),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: OmniMotion.of(context, OmniMotion.slow),
                  curve: OmniMotion.curve,
                  child: Icon(
                    Symbols.expand_more_rounded,
                    size: 24,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final body = AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => _controller.isDismissed
          ? const SizedBox.shrink()
          : ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: _size.value,
                child: child,
              ),
            ),
      child: _DisclosureScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Divider(height: 1, thickness: 1, color: palette.line),
            Padding(
              padding: EdgeInsets.fromLTRB(
                nested ? 0 : OmniSpace.md,
                OmniSpace.xs,
                nested ? 0 : OmniSpace.md,
                nested ? 0 : OmniSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: w.children,
              ),
            ),
          ],
        ),
      ),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [header, body],
    );
    if (nested) {
      return Material(type: MaterialType.transparency, child: content);
    }
    final radius = BorderRadius.circular(OmniRadii.section);
    return Padding(
      padding: w.margin,
      child: Material(
        color: palette.card,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }
}

/// Marks the body of an [OmniDisclosure], so one inside it draws flat.
class _DisclosureScope extends InheritedWidget {
  const _DisclosureScope({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DisclosureScope>() != null;

  @override
  bool updateShouldNotify(_DisclosureScope old) => false;
}
