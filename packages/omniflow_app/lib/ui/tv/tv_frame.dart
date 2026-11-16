import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The TV's screen pictures: decoded off the UI thread when they are big,
/// drawn at the size of their box, and dropped from the image cache as soon
/// as the next one replaces them.

/// Past this many characters of base64 the decode runs in another isolate.
/// A full TV frame is a few megabytes, an icon a few kilobytes.
const offThreadDecodeAbove = 64 * 1024;

/// The bytes of a base64 PNG, decoded in another isolate when it is big.
Future<Uint8List> decodeFrame(String base64) =>
    base64.length > offThreadDecodeAbove
    ? compute(base64Decode, base64, debugLabel: 'tv frame')
    : SynchronousFuture(base64Decode(base64));

/// One frame of the TV's screen. It decodes at the width it is drawn at
/// rather than the TV's full size, and evicts the frame before it from the
/// image cache, so live view holds about one frame instead of filling the
/// cache with full-size ones.
class TvFrame extends StatefulWidget {
  const TvFrame(this.bytes, {super.key, this.fit = BoxFit.contain});

  final Uint8List bytes;
  final BoxFit fit;

  @override
  State<TvFrame> createState() => _TvFrameState();
}

class _TvFrameState extends State<TvFrame> {
  ImageProvider? _shown;
  Uint8List? _bytes;
  int? _width;

  @override
  void dispose() {
    _shown?.evict();
    super.dispose();
  }

  /// The provider for the current bytes at [width] physical pixels, the
  /// old one evicted when either changed.
  ImageProvider _provider(int width) {
    final shown = _shown;
    if (shown != null && identical(_bytes, widget.bytes) && _width == width) {
      return shown;
    }
    // The old frame stays on screen until the new one has decoded (gapless
    // playback holds its own handle), but no longer sits in the cache.
    shown?.evict();
    _bytes = widget.bytes;
    _width = width;
    return _shown = ResizeImage(
      MemoryImage(widget.bytes),
      width: width,
      policy: ResizeImagePolicy.fit,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final logical = box.hasBoundedWidth && box.maxWidth > 0
          ? box.maxWidth
          : MediaQuery.sizeOf(context).width;
      final width = (logical * ratio).round().clamp(1, 4096);
      return Image(
        image: _provider(width),
        gaplessPlayback: true,
        fit: widget.fit,
        filterQuality: FilterQuality.medium,
      );
    },
  );
}
