// 按页面色彩类型（黑白／彩色）集中管理文字擦除与译文排版策略。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'inpainting_pixels.dart';

/// 页面色彩类型。由 [classifyPageColorMode] 自动判定，用户可在设置中覆盖。
enum PageColorMode { monochrome, color }

/// 设置项：自动判定或强制使用某一策略。
enum PageColorPreference { auto, monochrome, color }

PageColorMode? pageColorModeFromName(Object? name) {
  for (final mode in PageColorMode.values) {
    if (mode.name == name) return mode;
  }
  return null;
}

/// 解析最终生效的色彩类型；未判定过的旧缓存按黑白处理，保持原有行为。
PageColorMode resolvePageColorMode(
  PageColorPreference preference,
  PageColorMode? detected,
) => switch (preference) {
  PageColorPreference.monochrome => PageColorMode.monochrome,
  PageColorPreference.color => PageColorMode.color,
  PageColorPreference.auto => detected ?? PageColorMode.monochrome,
};

/// 统计页面中饱和像素的占比判断是否为彩色页。近黑、近白像素不参与统计，
/// 泛黄扫描件的低饱和纸色也不会被当作彩色。[rgba] 为无行填充的 RGBA 字节。
PageColorMode classifyPageColorMode(Uint8List rgba, int width, int height) {
  final total = width * height;
  if (total <= 0 || rgba.length < total * 4) return PageColorMode.monochrome;
  final step = math.max(1, math.sqrt(total / 160000).floor());
  int samples = 0, saturated = 0;
  for (int y = 0; y < height; y += step) {
    for (int x = 0; x < width; x += step) {
      final i = (y * width + x) * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final maximum = math.max(r, math.max(g, b));
      final minimum = math.min(r, math.min(g, b));
      samples++;
      if (maximum < 40 || minimum > 235) continue;
      if (maximum - minimum >= 36) saturated++;
    }
  }
  return samples > 0 && saturated / samples >= .1
      ? PageColorMode.color
      : PageColorMode.monochrome;
}

/// 判定一张 `image` 包图片的色彩类型，供擦除 isolate 内使用。
PageColorMode classifyImageColorMode(img.Image source) {
  final rgba =
      source.format == img.Format.uint8 && source.numChannels == 4
          ? source.toUint8List()
          : source
              .convert(format: img.Format.uint8, numChannels: 4, alpha: 255)
              .toUint8List();
  return classifyPageColorMode(rgba, source.width, source.height);
}

/// 黑白与彩色页面在擦除和排版上的全部差异点。OCR、翻译、CTD 与 LaMa
/// 推理本身两种页面共用，不进入策略。
abstract class PageProcessingStrategy {
  const PageProcessingStrategy();

  PageColorMode get mode;

  /// 写入修复缓存键；策略变化时不会复用另一策略的修复结果。
  String get id;

  /// 把 CTD 粗多边形细化为逐像素擦除掩码（0=修复，255=保留）。
  Uint8List refineEraseMask(img.Image source, Uint8List coarse);

  /// 纯色区域直接填色，其余像素留给 LaMa。
  FlatInpaintingResult repairFlatRegions(img.Image source, Uint8List mask) =>
      repairFlatInpaintingRegions(source, mask);

  /// 是否使用气泡检测得到的版面区域排字。彩色页常无白底气泡，
  /// 检测区域可能跨越多段对白，因此改用原文自身范围。
  bool get useContainerLayoutRegions;

  /// 是否在排版后消除不同对白之间的重叠。
  bool get separateOverlappingTexts;

  static const PageProcessingStrategy monochrome = MonochromePageStrategy();
  static const PageProcessingStrategy color = ColorPageStrategy();

  static PageProcessingStrategy of(PageColorMode mode) => switch (mode) {
    PageColorMode.monochrome => monochrome,
    PageColorMode.color => color,
  };
}

/// 黑白漫画：白纸黑字或白字黑底，亮度阈值即可分离文字。保持原有行为。
class MonochromePageStrategy extends PageProcessingStrategy {
  const MonochromePageStrategy();

  @override
  PageColorMode get mode => PageColorMode.monochrome;

  @override
  String get id => 'monochrome-v1';

  @override
  Uint8List refineEraseMask(img.Image source, Uint8List coarse) =>
      refineInpaintingMask(source, coarse);

  @override
  bool get useContainerLayoutRegions => true;

  @override
  bool get separateOverlappingTexts => false;
}

/// 彩色漫画／插画：背景有渐变与花纹，文字常为白字黑边或彩字白边，
/// 与背景亮度接近。按每个检测区域周围的局部背景色做色差分割。
class ColorPageStrategy extends PageProcessingStrategy {
  const ColorPageStrategy();

  @override
  PageColorMode get mode => PageColorMode.color;

  @override
  String get id => 'color-v1';

  @override
  Uint8List refineEraseMask(img.Image source, Uint8List coarse) =>
      refineColorInpaintingMask(source, coarse);

  @override
  bool get useContainerLayoutRegions => false;

  @override
  bool get separateOverlappingTexts => true;
}

/// 彩色页擦除掩码：每个 CTD 区域内与周围背景色差明显的像素即为文字
/// （填充色和描边都算），向外扩张少量像素覆盖抗锯齿边缘。不按亮度和
/// 连通块尺寸筛选，因此文字与同亮度彩色背景相连时也不会整块漏擦。
/// 背景估计失败或区域内几乎全是"文字"时，擦除整个检测区域。
Uint8List refineColorInpaintingMask(img.Image source, Uint8List coarse) {
  final w = source.width, h = source.height;
  if (coarse.length != w * h) throw ArgumentError('mask dimensions');
  final rgb = Uint8List(w * h * 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final p = source.getPixel(x, y), i = (y * w + x) * 3;
      rgb[i] = p.r.toInt();
      rgb[i + 1] = p.g.toInt();
      rgb[i + 2] = p.b.toInt();
    }
  }
  final result = Uint8List(w * h)..fillRange(0, w * h, 255);
  final visited = Uint8List(w * h);
  final component = <int>[];
  for (int seed = 0; seed < coarse.length; seed++) {
    if (coarse[seed] != 0 || visited[seed] != 0) continue;
    component
      ..clear()
      ..add(seed);
    visited[seed] = 1;
    int left = seed % w, right = left, top = seed ~/ w, bottom = top;
    for (int head = 0; head < component.length; head++) {
      final i = component[head], x = i % w, y = i ~/ w;
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final next = ny * w + nx;
          if (coarse[next] == 0 && visited[next] == 0) {
            visited[next] = 1;
            component.add(next);
          }
        }
      }
    }
    _refineColorComponent(
      rgb,
      coarse,
      result,
      component,
      w,
      h,
      left,
      top,
      right,
      bottom,
    );
  }
  return result;
}

// ===== 私有工具 =====

void _refineColorComponent(
  Uint8List rgb,
  Uint8List coarse,
  Uint8List result,
  List<int> component,
  int w,
  int h,
  int left,
  int top,
  int right,
  int bottom,
) {
  final shortSide = math.min(right - left + 1, bottom - top + 1);
  final margin = (shortSide * .25).ceil().clamp(6, 16);
  final radius = (shortSide * .04).ceil().clamp(2, 4);
  // 沿长边分段估计背景，跟随渐变而不是假设整块区域同色。
  final horizontal = right - left >= bottom - top;
  final span = horizontal ? right - left + 1 : bottom - top + 1;
  final bandSize = math.max(16, shortSide);
  final bands = (span / bandSize).ceil();
  final palettes = List<List<List<int>>?>.filled(bands, null);
  for (int band = 0; band < bands; band++) {
    final start = (horizontal ? left : top) + band * bandSize;
    final end = math.min(start + bandSize - 1, horizontal ? right : bottom);
    final x0 = math.max(0, (horizontal ? start : left) - margin);
    final x1 = math.min(w - 1, (horizontal ? end : right) + margin);
    final y0 = math.max(0, (horizontal ? top : start) - margin);
    final y1 = math.min(h - 1, (horizontal ? bottom : end) + margin);
    palettes[band] = _backgroundPalette(rgb, coarse, w, x0, y0, x1, y1);
  }
  int candidates = 0;
  final text = <int>[];
  bool failed = palettes.every((palette) => palette == null);
  if (!failed) {
    for (final i in component) {
      final x = i % w, y = i ~/ w;
      final band = (((horizontal ? x - left : y - top) ~/ bandSize)).clamp(
        0,
        bands - 1,
      );
      final palette = palettes[band] ?? palettes.firstWhere((p) => p != null)!;
      int nearest = 1 << 30;
      for (final color in palette) {
        final dr = rgb[i * 3] - color[0];
        final dg = rgb[i * 3 + 1] - color[1];
        final db = rgb[i * 3 + 2] - color[2];
        nearest = math.min(nearest, dr * dr + dg * dg + db * db);
      }
      // 约等于每通道 30 的色差；JPEG 噪点和背景细微纹理不会超过。
      if (nearest > 2700) {
        text.add(i);
        candidates++;
      }
    }
    // 几乎整块都和背景不同，说明背景估计已失效（例如文字压在复杂花纹上）。
    failed = candidates > component.length * .7;
  }
  if (failed) {
    for (final i in component) {
      result[i] = 0;
    }
    return;
  }
  // 只允许在检测区域外扩 radius+1 像素以内补齐描边，不擦除区域外的画面。
  final limit = radius + 1;
  for (final i in text) {
    final x = i % w, y = i ~/ w;
    for (int dy = -radius; dy <= radius; dy++) {
      for (int dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy * dy > radius * radius) continue;
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        if (nx < left - limit ||
            nx > right + limit ||
            ny < top - limit ||
            ny > bottom + limit) {
          continue;
        }
        result[ny * w + nx] = 0;
      }
    }
  }
}

/// 区域外环（不含检测区域本身）的主背景色，最多四种以覆盖多色或渐变背景。
List<List<int>>? _backgroundPalette(
  Uint8List rgb,
  Uint8List coarse,
  int w,
  int x0,
  int y0,
  int x1,
  int y1,
) {
  final bins = <int, List<int>>{};
  int samples = 0;
  for (int y = y0; y <= y1; y++) {
    for (int x = x0; x <= x1; x++) {
      final i = y * w + x;
      if (coarse[i] == 0) continue;
      final r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2];
      final bin = bins.putIfAbsent(
        (r >> 4) << 8 | (g >> 4) << 4 | b >> 4,
        () => [0, 0, 0, 0],
      );
      bin[0]++;
      bin[1] += r;
      bin[2] += g;
      bin[3] += b;
      samples++;
    }
  }
  if (samples < 24) return null;
  final ranked = bins.values.toList()..sort((a, b) => b[0].compareTo(a[0]));
  List<int> mean(List<int> bin) => [
    bin[1] ~/ bin[0],
    bin[2] ~/ bin[0],
    bin[3] ~/ bin[0],
  ];
  // 渐变背景分散在相邻色箱中；合并与首位色接近的色箱再判断占比。
  final palette = <List<int>>[];
  int covered = 0;
  for (final bin in ranked) {
    final color = mean(bin);
    final near = palette.any(
      (c) =>
          (c[0] - color[0]).abs() <= 24 &&
          (c[1] - color[1]).abs() <= 24 &&
          (c[2] - color[2]).abs() <= 24,
    );
    if (!near) {
      if (palette.length >= 4 || bin[0] < samples * .08) continue;
      palette.add(color);
    }
    covered += bin[0];
  }
  // 外环颜色过于分散时（复杂画面），背景色无法代表文字周围。
  return palette.isEmpty || covered < samples * .5 ? null : palette;
}
