import 'package:flutter/widgets.dart';

/// The OmniFlow mark, on a transparent background.
class OmniMark extends StatelessWidget {
  const OmniMark({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/omniflow_mark.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    semanticLabel: 'OmniFlow',
  );
}
