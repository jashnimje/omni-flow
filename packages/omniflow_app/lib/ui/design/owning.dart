import 'package:flutter/widgets.dart';

/// Disposes [owns] when [child] leaves the tree: after a sheet or dialog
/// has finished closing, so no field still shows a disposed controller.
class Owning extends StatefulWidget {
  const Owning(this.owns, {super.key, required this.child});

  final List<ChangeNotifier> owns;
  final Widget child;

  @override
  State<Owning> createState() => _OwningState();
}

class _OwningState extends State<Owning> {
  @override
  void dispose() {
    for (final c in widget.owns) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
