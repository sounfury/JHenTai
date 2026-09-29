import 'dart:math' as math;

import '../model/image_translation.dart';
import '../service/engine/engine_contract.dart';
import '../service/image_translation/onomatopoeia_filter.dart';
import 'bubble_detection_refinement.dart';
import 'rgba_raster.dart';

/// Corroborate an OCR-corrupted effect with the ink of a positively recognized
/// effect on the SAME page. Never infer sound effects from coloured art alone.
/// Only short, uncertain, outside-balloon blocks are eligible.
Set<int> styleMatchedSoundEffects(
  RgbaRaster page,
  List<RecognizedTextBlock> blocks,
  List<DetectedTextRegion> bubbles,
) {
  bool outside(RecognizedTextBlock b) =>
      !bubbles.any((r) => bubbleRegionCoverage(b, r) >= .55);
  final anchors = <(double, double, double)>[];
  final candidates = <int, (double, double, double)>{};
  for (int i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (!outside(b)) {
      continue;
    }
    final anchor = isOnomatopoeia(b.text) && b.confidence >= .8;
    final candidate =
        b.confidence < .8 &&
        b.text.trim().runes.length <= 2 &&
        b.width > 0 &&
        b.height > b.width * 1.3;
    if (!anchor && !candidate) {
      continue;
    }
    final ink = _saturatedInk(page, b);
    if (ink == null) {
      continue;
    }
    if (anchor) {
      anchors.add(ink);
    }
    if (candidate) {
      candidates[i] = ink;
    }
  }
  return {
    for (final entry in candidates.entries)
      if (anchors.any(
        (ink) =>
            (ink.$1 - entry.value.$1).abs() < 35 &&
            (ink.$2 - entry.value.$2).abs() < 35 &&
            (ink.$3 - entry.value.$3).abs() < 35,
      ))
        entry.key,
  };
}

(double, double, double)? _saturatedInk(
  RgbaRaster page,
  RecognizedTextBlock b,
) {
  final left = b.left.floor().clamp(0, page.width);
  final top = b.top.floor().clamp(0, page.height);
  final right = (b.left + b.width).ceil().clamp(0, page.width);
  final bottom = (b.top + b.height).ceil().clamp(0, page.height);
  if (right <= left || bottom <= top) {
    return null;
  }
  final step = math.max(1, math.max(right - left, bottom - top) ~/ 64);
  final bins = <int, List<int>>{};
  int total = 0, saturated = 0;
  for (int y = top; y < bottom; y += step) {
    for (int x = left; x < right; x += step) {
      total++;
      final p = (y * page.width + x) * 4;
      final r = page.pixels[p],
          g = page.pixels[p + 1],
          blue = page.pixels[p + 2];
      final high = math.max(r, math.max(g, blue));
      final low = math.min(r, math.min(g, blue));
      if (high - low < 65 || high < 110) {
        continue;
      }
      saturated++;
      final key = (r ~/ 32) * 64 + (g ~/ 32) * 8 + blue ~/ 32;
      final bin = bins.putIfAbsent(key, () => [0, 0, 0, 0]);
      bin[0]++;
      bin[1] += r;
      bin[2] += g;
      bin[3] += blue;
    }
  }
  // Reject colourful illustration crops: effect ink is a small foreground
  // fraction surrounded by an unsaturated fill or white outline.
  if (bins.isEmpty || saturated < total * .01 || saturated > total * .4) {
    return null;
  }
  final best = bins.values.reduce((a, b) => a[0] >= b[0] ? a : b);
  if (best[0] < total * .005) {
    return null;
  }
  return (best[1] / best[0], best[2] / best[0], best[3] / best[0]);
}
