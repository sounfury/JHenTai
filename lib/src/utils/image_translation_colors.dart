import 'dart:math' as math;

import '../model/image_translation.dart';
import 'rgba_raster.dart';

/// Samples each OCR region's fill and text-band thickness independently, so
/// inverted captions and mixed font sizes can coexist. Runs in an isolate;
/// the page comes from [rasterFromPayload] (`'image'` or encoded `'bytes'`).
List<RecognizedTextBlock> detectTranslationColors(Map<String, dynamic> payload) {
  final blocks = payload['blocks'] as List<RecognizedTextBlock>;
  final source = rasterFromPayload(payload);
  if (source == null) return blocks;
  final pixels = source.pixels;
  final double scaleX = source.width / (payload['width'] as int);
  final double scaleY = source.height / (payload['height'] as int);
  return blocks.map((block) {
    if ((block.backgroundColor != null &&
            block.sourceGlyphWidth != null && block.sourceGlyphHeight != null) ||
        block.width <= 0 || block.height <= 0) {
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
        final index = (y * source.width + x) * 4;
        final r = pixels[index];
        final g = pixels[index + 1];
        final b = pixels[index + 2];
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
    final background = block.backgroundColor ?? color;
    final backgroundLuma = 0.299 * ((background >> 16) & 255) +
        0.587 * ((background >> 8) & 255) + 0.114 * (background & 255);
    final columns = List<int>.filled(right - left, 0);
    final rows = List<int>.filled(bottom - top, 0);
    // Project contrasting source strokes onto both axes. Empty margins and
    // gaps between text columns no longer contribute to the estimated glyph.
    for (int y = top; y < bottom; y++) {
      for (int x = left; x < right; x++) {
        final index = (y * source.width + x) * 4;
        final luma = 0.299 * pixels[index] +
            0.587 * pixels[index + 1] +
            0.114 * pixels[index + 2];
        if (pixels[index + 3] > 127 && (luma - backgroundLuma).abs() >= 64) {
          columns[x - left]++;
          rows[y - top]++;
        }
      }
    }
    final glyphWidth = _strokeBandSize(columns);
    final glyphHeight = _strokeBandSize(rows);
    return RecognizedTextBlock.fromJson({
      ...block.toJson(),
      'backgroundColor': background,
      if (glyphWidth != null) 'sourceGlyphWidth': glyphWidth / scaleX,
      if (glyphHeight != null) 'sourceGlyphHeight': glyphHeight / scaleY,
    });
  }).toList(growable: false);
}

/// Dominant stroke bands: narrow punctuation and furigana should not set the
/// dialogue size. Tiny internal holes are joined, but inter-column gaps remain.
double? _strokeBandSize(List<int> projection) {
  final peak = projection.fold<int>(0, math.max);
  if (peak == 0) {
    return null;
  }
  final threshold = math.max(1, (peak * 0.08).ceil());
  final active = projection.map((count) => count >= threshold).toList();
  for (int i = 1; i < active.length - 1; i++) {
    if (!active[i] && active[i - 1] && active[i + 1]) {
      active[i] = true;
    }
  }
  final widths = <int>[];
  int start = -1;
  for (int i = 0; i <= active.length; i++) {
    if (i < active.length && active[i]) {
      if (start < 0) {
        start = i;
      }
    } else if (start >= 0) {
      if (i - start >= 2) {
        widths.add(i - start);
      }
      start = -1;
    }
  }
  if (widths.isEmpty) {
    return null;
  }
  widths.sort();
  final mainBands = widths.where((width) => width >= widths.last * 0.5).toList();
  final middle = mainBands.length ~/ 2;
  return mainBands.length.isOdd
      ? mainBands[middle].toDouble()
      : (mainBands[middle - 1] + mainBands[middle]) / 2;
}
