// 从原图采样文字底色、字形尺寸、字色及白描边，供阅读与导出共用。
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/image_translation.dart';
import 'rgba_raster.dart';

/// Samples each OCR region's fill and text-band thickness independently, so
/// inverted captions and mixed font sizes can coexist. Runs in an isolate;
/// the page comes from [rasterFromPayload] (`'image'` or encoded `'bytes'`).
List<RecognizedTextBlock> detectTranslationColors(
  Map<String, dynamic> payload,
) {
  final blocks = payload['blocks'] as List<RecognizedTextBlock>;
  final source = rasterFromPayload(payload);
  if (source == null) return blocks;
  final pixels = source.pixels;
  final double scaleX = source.width / (payload['width'] as int);
  final double scaleY = source.height / (payload['height'] as int);
  return blocks
      .map((block) {
        if ((block.backgroundColor != null &&
                block.sourceGlyphWidth != null &&
                block.sourceGlyphHeight != null &&
                block.textStyleVersion >= 1) ||
            block.width <= 0 ||
            block.height <= 0) {
          return block;
        }
        final left = math.max(0, (block.left * scaleX).floor());
        final top = math.max(0, (block.top * scaleY).floor());
        final right = math.min(
          source.width,
          ((block.left + block.width) * scaleX).ceil(),
        );
        final bottom = math.min(
          source.height,
          ((block.top + block.height) * scaleY).ceil(),
        );
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
        final dominant = counts.entries.reduce(
          (a, b) => a.value >= b.value ? a : b,
        );
        final rgb = sums[dominant.key]!;
        final color =
            0xff000000 |
            ((rgb[0] ~/ dominant.value) << 16) |
            ((rgb[1] ~/ dominant.value) << 8) |
            (rgb[2] ~/ dominant.value);
        final background = block.backgroundColor ?? color;
        final backgroundLuma =
            0.299 * ((background >> 16) & 255) +
            0.587 * ((background >> 8) & 255) +
            0.114 * (background & 255);
        final columns = List<int>.filled(right - left, 0);
        final rows = List<int>.filled(bottom - top, 0);
        // Project contrasting source strokes onto both axes. Empty margins and
        // gaps between text columns no longer contribute to the estimated glyph.
        for (int y = top; y < bottom; y++) {
          for (int x = left; x < right; x++) {
            final index = (y * source.width + x) * 4;
            final luma =
                0.299 * pixels[index] +
                0.587 * pixels[index + 1] +
                0.114 * pixels[index + 2];
            if (pixels[index + 3] > 127 &&
                (luma - backgroundLuma).abs() >= 64) {
              columns[x - left]++;
              rows[y - top]++;
            }
          }
        }
        final glyphWidth = _strokeBandSize(columns);
        final glyphHeight = _strokeBandSize(rows);
        final style = _detectSourceTextStyle(
          source,
          left,
          top,
          right,
          bottom,
          color,
        );
        return RecognizedTextBlock.fromJson({
          ...block.toJson(),
          'backgroundColor': background,
          'textStyleVersion': 1,
          if (style.textColor != null) 'textColor': style.textColor,
          if (style.outlineColor != null) 'outlineColor': style.outlineColor,
          'outlineWidthRatio': style.outlineWidthRatio,
          if (glyphWidth != null) 'sourceGlyphWidth': glyphWidth / scaleX,
          if (glyphHeight != null) 'sourceGlyphHeight': glyphHeight / scaleY,
        });
      })
      .toList(growable: false);
}

// ===== 私有工具 =====

/// 原文框外的主底色用于区分字色与彩色背景；白描边不能作为字色。
({int? textColor, int? outlineColor, double outlineWidthRatio})
_detectSourceTextStyle(
  RgbaRaster source,
  int left,
  int top,
  int right,
  int bottom,
  int fallbackBackground,
) {
  final pixels = source.pixels;
  final width = right - left, height = bottom - top;
  final margin = (math.min(width, height) * .15).ceil().clamp(2, 8);
  final context = <int, List<int>>{};
  void add(Map<int, List<int>> bins, int r, int g, int b) {
    final bin = bins.putIfAbsent(
      ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4),
      () => [0, 0, 0, 0],
    );
    bin[0]++;
    bin[1] += r;
    bin[2] += g;
    bin[3] += b;
  }

  for (
    int y = math.max(0, top - margin);
    y < math.min(source.height, bottom + margin);
    y++
  ) {
    for (
      int x = math.max(0, left - margin);
      x < math.min(source.width, right + margin);
      x++
    ) {
      if (x >= left && x < right && y >= top && y < bottom) continue;
      final offset = (y * source.width + x) * 4;
      if (pixels[offset + 3] > 127)
        add(context, pixels[offset], pixels[offset + 1], pixels[offset + 2]);
    }
  }
  final bg =
      context.isEmpty
          ? [
            fallbackBackground >> 16 & 255,
            fallbackBackground >> 8 & 255,
            fallbackBackground & 255,
          ]
          : _meanRgb(context.values.reduce((a, b) => a[0] >= b[0] ? a : b));
  final bgLuma = bg[0] * .299 + bg[1] * .587 + bg[2] * .114;
  final white = Uint8List(width * height);
  final coloredBins = <int, List<int>>{}, monochromeBins = <int, List<int>>{};
  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final offset = (y * source.width + x) * 4;
      if (pixels[offset + 3] <= 127) continue;
      final r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2];
      final maximum = math.max(r, math.max(g, b)),
          minimum = math.min(r, math.min(g, b));
      final chroma = maximum - minimum;
      final luma = r * .299 + g * .587 + b * .114;
      if (minimum > 224 && chroma < 28) white[(y - top) * width + x - left] = 1;
      final contrast = math.max(
        (r - bg[0]).abs(),
        math.max((g - bg[1]).abs(), (b - bg[2]).abs()),
      );
      if (contrast < 48) continue;
      if (chroma >= 48) add(coloredBins, r, g, b);
      if (chroma < 48 && (bgLuma >= 128 ? luma < 100 : luma > 200))
        add(monochromeBins, r, g, b);
    }
  }
  List<int>? coreBin;
  if (coloredBins.isNotEmpty) {
    coreBin = coloredBins.values.reduce((a, b) => a[0] >= b[0] ? a : b);
    if (coreBin[0] < math.max(8, width * height * .005)) coreBin = null;
  }
  if (coreBin == null && monochromeBins.isNotEmpty)
    coreBin = monochromeBins.values.reduce((a, b) => a[0] >= b[0] ? a : b);
  if (coreBin == null || coreBin[0] < 4)
    return (textColor: null, outlineColor: null, outlineWidthRatio: 0);
  final rgb = _meanRgb(coreBin);
  final textColor = 0xff000000 | rgb[0] << 16 | rgb[1] << 8 | rgb[2];
  // 白纸上的黑字无需额外白边；只有底色能与白边区分时才记录描边。
  if (bg.every((channel) => channel > 240))
    return (textColor: textColor, outlineColor: null, outlineWidthRatio: 0);
  final core = Uint8List(width * height);
  int corePixels = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final offset = ((top + y) * source.width + left + x) * 4;
      if (pixels[offset + 3] <= 127) continue;
      if ((pixels[offset] - rgb[0]).abs() <= 24 &&
          (pixels[offset + 1] - rgb[1]).abs() <= 24 &&
          (pixels[offset + 2] - rgb[2]).abs() <= 24) {
        core[y * width + x] = 1;
        corePixels++;
      }
    }
  }
  final radius = (math.min(width, height) * .2).ceil().clamp(2, 8);
  final distances = <int>[];
  int borderCore = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final index = y * width + x;
      if (white[index] == 0 && core[index] == 0) continue;
      int nearest = radius * radius + 1;
      for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
          final nx = x + dx, ny = y + dy, distance = dx * dx + dy * dy;
          if (distance >= nearest ||
              nx < 0 ||
              ny < 0 ||
              nx >= width ||
              ny >= height)
            continue;
          if ((white[index] != 0
                  ? core[ny * width + nx]
                  : white[ny * width + nx]) !=
              0)
            nearest = distance;
        }
      }
      if (nearest > radius * radius) continue;
      if (white[index] != 0)
        distances.add(nearest);
      else
        borderCore++;
    }
  }
  if (distances.length < 8 || corePixels == 0 || borderCore / corePixels < .5)
    return (textColor: textColor, outlineColor: null, outlineWidthRatio: 0);
  distances.sort();
  final thickness = math.sqrt(
    distances[(distances.length * .75).floor().clamp(0, distances.length - 1)],
  );
  return (
    textColor: textColor,
    outlineColor: 0xffffffff,
    outlineWidthRatio: (thickness / math.min(width, height)).clamp(.025, .12),
  );
}

List<int> _meanRgb(List<int> bin) => [
  bin[1] ~/ bin[0],
  bin[2] ~/ bin[0],
  bin[3] ~/ bin[0],
];

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
  final mainBands =
      widths.where((width) => width >= widths.last * 0.5).toList();
  final middle = mainBands.length ~/ 2;
  return mainBands.length.isOdd
      ? mainBands[middle].toDouble()
      : (mainBands[middle - 1] + mainBands[middle]) / 2;
}
