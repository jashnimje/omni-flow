import 'package:flutter/material.dart';

import 'tokens.dart';

/// A page that grows out of the card that opened it (Material's container
/// transform), and shrinks back into it on the way out. Without a card,
/// or under reduced motion, it uses the theme's usual page transition.
class OmniContainerRoute<T> extends PageRoute<T> {
  OmniContainerRoute({
    required this.builder,
    this.from,
    this.radius = OmniRadii.tile,
    super.settings,
  });

  /// Pushes [page] on [context]'s navigator, growing out of [source] (the
  /// tile's context) when given.
  static Future<T?> open<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    BuildContext? source,
    RouteSettings? settings,
  }) {
    final nav = Navigator.of(context);
    return nav.push(
      OmniContainerRoute<T>(
        builder: builder,
        from: source == null ? null : rectIn(source, nav.context),
        settings: settings,
      ),
    );
  }

  /// Where [source] sits inside [ancestor], or null when either is not
  /// laid out.
  static Rect? rectIn(BuildContext source, BuildContext ancestor) {
    final box = source.findRenderObject();
    final into = ancestor.findRenderObject();
    if (box is! RenderBox || into is! RenderBox || !box.hasSize) return null;
    if (!box.attached || !into.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: into) & box.size;
  }

  final WidgetBuilder builder;

  /// The card's rectangle in the navigator.
  final Rect? from;
  final double radius;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => OmniMotion.long;

  @override
  Duration get reverseTransitionDuration => OmniMotion.medium;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final start = from;
    if (start == null || OmniMotion.reduced(context)) {
      if (OmniMotion.reduced(context)) return child;
      return Theme.of(context).pageTransitionsTheme.buildTransitions(
        this,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    final grow = CurvedAnimation(
      parent: animation,
      curve: OmniMotion.emphasizedIn,
      reverseCurve: OmniMotion.emphasizedOut,
    );
    final fadeIn = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.1, 0.45, curve: Curves.easeOut),
    );
    final card = OmniPalette.of(context).card;
    return LayoutBuilder(
      builder: (context, box) {
        final full = Offset.zero & box.biggest;
        return AnimatedBuilder(
          animation: grow,
          child: child,
          builder: (context, page) {
            // The same widgets at every step, so the page keeps its state
            // when the growing ends.
            final t = grow.value;
            final rect = Rect.lerp(start, full, t)!;
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius * (1 - t)),
                    child: ColoredBox(
                      color: card,
                      child: FittedBox(
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.topCenter,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox.fromSize(
                          size: full.size,
                          child: FadeTransition(opacity: fadeIn, child: page),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
