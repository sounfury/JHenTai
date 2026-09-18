import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../model/image_translation.dart';

/// Samples each OCR region independently, so inverted captions can coexist
/// with normal speech bubbles. Runs in an isolate; no decoded page is retained.
List<RecognizedTextBlock> detectTranslationColors(Map<String, dynamic> payload) {
  final blocks = payload['blocks'] as List<RecognizedTextBlock>;
  final decoded = image.decodeImage(payload['bytes'] as Uint8List);
  if (decoded == null) return blocks;
  final source = image.bakeOrientation(decoded);
  final double scaleX = source.width / (payload['width'] as int);
  final double scaleY = source.height / (payload['height'] as int);
  return blocks.map((block) {
    if (block.backgroundColor != null || block.width <= 0 || block.height <= 0) {
      return block;
    }
    final left = math.max(0, (block.left * scaleX).floor());
    final top = math.max(0, (block.top * scaleY).floor());
    final right = math.min(source.width, ((block.left + block.width) * scaleX).ceil());
    final bottom = math.min(source.height, ((block.top + block.height) * scaleY).ceil());
    if (left >= right || top >= bottom) return block;
    // Background occupies more pixels than glyph strokes. A dominant RGB bin
    // ignores anti-aliasing and avoids averaging white letters into black fill.
    final counts = <int, int>{};
    final sums = <int, List<int>>{};
    final stepX = math.max(1, (right - left) ~/ 64);
    final stepY = math.max(1, (bottom - top) ~/ 64);
    for (int y = top; y < bottom; y += stepY) {
      for (int x = left; x < right; x += stepX) {
        final pixel = source.getPixel(x, y);
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        final b = pixel.b.toInt();
        final key = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
        counts[key] = (counts[key] ?? 0) + 1;
        final sum = sums.putIfAbsent(key, () => [0, 0, 0]);
        sum[0] += r;
        sum[1] += g;
        sum[2] += b;
      }
    }
    final dominant = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final rgb = sums[dominant.key]!;
    final color = 0xff000000 |
        ((rgb[0] ~/ dominant.value) << 16) |
        ((rgb[1] ~/ dominant.value) << 8) |
        (rgb[2] ~/ dominant.value);
    return RecognizedTextBlock.fromJson({...block.toJson(), 'backgroundColor': color});
  }).toList(growable: false);
}
