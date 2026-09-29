import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// A cropped, binary balloon-interior mask in source-image coordinates.
/// This is layout geometry, never a text-removal/inpainting mask.
class BubbleInteriorMask {
  BubbleInteriorMask({
    required this.bounds,
    required this.width,
    required this.height,
    required this.pixels,
  }) : assert(width > 0 && height > 0),
       assert(pixels.length == width * height);

  final Rect bounds;
  final int width, height;
  final Uint8List pixels;

  BubbleInteriorMask shifted(Offset offset) => BubbleInteriorMask(
    bounds: bounds.shift(offset),
    width: width,
    height: height,
    pixels: pixels,
  );

  /// Area coverage, rather than the rectangle centre: an effect beside a
  /// concave balloon can be inside its box but outside the balloon itself.
  double coverage(Rect rect) {
    if (rect.isEmpty || bounds.isEmpty || !rect.overlaps(bounds)) {
      return 0;
    }
    final cellWidth = bounds.width / width, cellHeight = bounds.height / height;
    final intersection = rect.intersect(bounds);
    final x0 = ((intersection.left - bounds.left) / cellWidth).floor().clamp(
      0,
      width,
    );
    final x1 = ((intersection.right - bounds.left) / cellWidth).ceil().clamp(
      0,
      width,
    );
    final y0 = ((intersection.top - bounds.top) / cellHeight).floor().clamp(
      0,
      height,
    );
    final y1 = ((intersection.bottom - bounds.top) / cellHeight).ceil().clamp(
      0,
      height,
    );
    double covered = 0;
    for (int y = y0; y < y1; y++) {
      final top = bounds.top + y * cellHeight;
      final h =
          math.min(top + cellHeight, rect.bottom) - math.max(top, rect.top);
      for (int x = x0; x < x1; x++) {
        if (pixels[y * width + x] == 0) {
          continue;
        }
        final left = bounds.left + x * cellWidth;
        covered +=
            h *
            (math.min(left + cellWidth, rect.right) -
                math.max(left, rect.left));
      }
    }
    return (covered / (rect.width * rect.height)).clamp(0, 1);
  }
}
