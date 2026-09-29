import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../model/bubble_interior_mask.dart';

/// YOLO-seg: sigmoid(sum(coeff[c] * prototype[c,y,x])) > .5 is
/// equivalent to a positive logit. Decode only the selected detection's crop,
/// discard padding, and retain the exact inverse letterbox transform.
BubbleInteriorMask? decodeBubbleInteriorMask({
  required List<double> coefficients,
  required Float32List prototypes,
  required int prototypeWidth,
  required int prototypeHeight,
  required int inputSize,
  required Rect sourceBox,
  required double scale,
  required double padX,
  required double padY,
}) {
  final plane = prototypeWidth * prototypeHeight;
  if (plane <= 0 ||
      inputSize <= 0 ||
      scale <= 0 ||
      sourceBox.isEmpty ||
      prototypes.length != plane * coefficients.length ||
      coefficients.any((v) => !v.isFinite)) {
    return null;
  }
  final stepX = inputSize / prototypeWidth, stepY = inputSize / prototypeHeight;
  final x0 = ((sourceBox.left * scale + padX) / stepX).floor().clamp(
    0,
    prototypeWidth,
  );
  final x1 = ((sourceBox.right * scale + padX) / stepX).ceil().clamp(
    0,
    prototypeWidth,
  );
  final y0 = ((sourceBox.top * scale + padY) / stepY).floor().clamp(
    0,
    prototypeHeight,
  );
  final y1 = ((sourceBox.bottom * scale + padY) / stepY).ceil().clamp(
    0,
    prototypeHeight,
  );
  final width = x1 - x0, height = y1 - y0;
  if (width <= 0 || height <= 0) {
    return null;
  }
  // Resample logits at source-box grid centres. This keeps cells entirely
  // within the box even when it is not aligned with the prototype grid.
  final pixels = Uint8List(width * height);
  int foreground = 0;
  for (int y = 0; y < height; y++) {
    final py =
        ((sourceBox.top + (y + .5) * sourceBox.height / height) * scale +
                padY) /
            stepY -
        .5;
    final ya = py.floor().clamp(0, prototypeHeight - 1);
    final yb = (py.floor() + 1).clamp(0, prototypeHeight - 1);
    final fy = py - py.floor();
    for (int x = 0; x < width; x++) {
      final px =
          ((sourceBox.left + (x + .5) * sourceBox.width / width) * scale +
                  padX) /
              stepX -
          .5;
      final xa = px.floor().clamp(0, prototypeWidth - 1);
      final xb = (px.floor() + 1).clamp(0, prototypeWidth - 1);
      final fx = px - px.floor();
      double logit = 0;
      for (int c = 0; c < coefficients.length; c++) {
        final base = c * plane;
        final top =
            prototypes[base + ya * prototypeWidth + xa] * (1 - fx) +
            prototypes[base + ya * prototypeWidth + xb] * fx;
        final bottom =
            prototypes[base + yb * prototypeWidth + xa] * (1 - fx) +
            prototypes[base + yb * prototypeWidth + xb] * fx;
        logit += coefficients[c] * (top * (1 - fy) + bottom * fy);
      }
      if (logit.isFinite && logit > 0) {
        pixels[y * width + x] = 1;
        foreground++;
      }
    }
  }
  // Empty/broken output must not be mistaken for evidence of outside text.
  if (foreground < math.max(1, pixels.length * .02)) {
    return null;
  }
  return BubbleInteriorMask(
    bounds: sourceBox,
    width: width,
    height: height,
    pixels: pixels,
  );
}
