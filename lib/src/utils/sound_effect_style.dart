import 'dart:math' as math;
import 'dart:typed_data';

import '../model/image_translation.dart';
import '../service/engine/engine_contract.dart';
import '../service/image_translation/onomatopoeia_filter.dart';
import 'bubble_detection_refinement.dart';
import 'rgba_raster.dart';

/// Large hand lettering can be recognized as arbitrary Latin/CJK fragments,
/// leaving no correctly recognized effect to use as a colour anchor. Require
/// uncertain, oversized text AND repeated white-edged ink in the source image.
/// Balloon dialogue remains authoritative, even when it uses the same outline.
Set<int> outlinedArtworkSoundEffects(
  RgbaRaster page,
  List<RecognizedTextBlock> blocks,
  List<DetectedTextRegion>? bubbles,
) {
  final dialogueSizes =
      blocks
          .where((b) => b.confidence >= .85 && b.text.runes.length >= 4)
          .map((b) => math.min(b.width, b.height))
          .where((size) => size > 0)
          .toList()
        ..sort();
  final minimumSize = math.max(
    math.min(page.width, page.height) * .04,
    dialogueSizes.isEmpty
        ? 0.0
        : dialogueSizes[dialogueSizes.length ~/ 2] * 1.8,
  );
  return {
    for (int i = 0; i < blocks.length; i++)
      if (blocks[i].confidence < .8 &&
          math.min(blocks[i].width, blocks[i].height) >= minimumSize &&
          _corruptedEffectText(blocks[i].text) &&
          !(bubbles ?? const <DetectedTextRegion>[]).any(
            (r) => bubbleRegionCoverage(blocks[i], r) >= .55,
          ) &&
          _hasWhiteEdgedInk(page, blocks[i]))
        i,
  };
}

bool _corruptedEffectText(String text) {
  final core = text.replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  if (core.isEmpty || core.runes.length > 8) {
    return false;
  }
  // Include short mixed kanji/katakana OCR errors. Dialogue remains protected
  // by balloon membership and the source must independently show outlined ink.
  return RegExp(r'[A-Za-z0-9]').hasMatch(core) ||
      (core.runes.length <= 2 &&
          RegExp(r'^[\u3400-\u9fff]+$').hasMatch(core)) ||
      RegExp(r'^[\u3400-\u9fff゠-ヿ]{1,4}$').hasMatch(core);
}

bool _hasWhiteEdgedInk(RgbaRaster page, RecognizedTextBlock block) {
  final left = block.left.floor().clamp(0, page.width);
  final top = block.top.floor().clamp(0, page.height);
  final right = (block.left + block.width).ceil().clamp(0, page.width);
  final bottom = (block.top + block.height).ceil().clamp(0, page.height);
  if (right <= left || bottom <= top) {
    return false;
  }
  // Bound work per candidate while retaining several samples across an outline.
  final step = math.max(1, math.max(right - left, bottom - top) ~/ 160);
  final width = (right - left + step - 1) ~/ step;
  final height = (bottom - top + step - 1) ~/ step;
  final white = Uint8List(width * height);
  final ink = Uint8List(width * height);
  int whiteCount = 0, colouredCount = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final p = ((top + y * step) * page.width + left + x * step) * 4;
      final r = page.pixels[p], g = page.pixels[p + 1], b = page.pixels[p + 2];
      final high = math.max(r, math.max(g, b));
      final low = math.min(r, math.min(g, b));
      final index = y * width + x;
      if (low >= 230 && high - low <= 25) {
        white[index] = 1;
        whiteCount++;
      }
      // Muted skin/background colours are not the bright effect outline. They
      // can fill most of an OCR crop without obscuring the lettering itself.
      if (high - low >= 50 && high >= 200) {
        colouredCount++;
        ink[index] = 1;
      }
      if (high <= 65) {
        ink[index] = 1;
      }
    }
  }
  final total = width * height;
  // White lettering on a solid coloured balloon is dialogue, not a glow.
  if (whiteCount < total * .03 || colouredCount > total * .45) {
    return false;
  }
  final radius = math.max(2, (10 / step).round());
  final bins = <int, int>{};
  final rows = <int>{}, columns = <int>{};
  int edgedInk = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      if (ink[y * width + x] == 0) {
        continue;
      }
      bool l = false, r = false, t = false, b = false;
      for (int d = 1; d <= radius; d++) {
        l |= x >= d && white[y * width + x - d] != 0;
        r |= x + d < width && white[y * width + x + d] != 0;
        t |= y >= d && white[(y - d) * width + x] != 0;
        b |= y + d < height && white[(y + d) * width + x] != 0;
      }
      if (!(l && r) && !(t && b)) {
        continue;
      }
      edgedInk++;
      rows.add(y);
      columns.add(x);
      final p = ((top + y * step) * page.width + left + x * step) * 4;
      final key =
          (page.pixels[p] ~/ 32) * 64 +
          (page.pixels[p + 1] ~/ 32) * 8 +
          page.pixels[p + 2] ~/ 32;
      bins[key] = (bins[key] ?? 0) + 1;
    }
  }
  // A few clothing highlights or one heart are not lettering. Require repeated
  // strokes spread across the crop and a coherent ink colour along their edges.
  return edgedInk >= total * .012 &&
      rows.length >= height * .4 &&
      columns.length >= width * .4 &&
      bins.values.any((count) => count >= total * .005);
}

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
