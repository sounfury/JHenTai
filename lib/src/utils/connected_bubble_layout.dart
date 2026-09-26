import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../model/image_translation.dart';
import 'rgba_raster.dart';

/// Refine detector rectangles without changing group indices or translation
/// context. Runs in an isolate, and persists geometry with the OCR result.
List<Map<String, dynamic>> refineBubbleLayoutsFromBytes(
  Map<String, dynamic> payload,
) {
  final containers =
      (payload['containers'] as List)
          .map(
            (value) => RecognizedTextContainer.fromJson(
              Map<String, dynamic>.from(value),
            ),
          )
          .toList();
  if (containers.every((container) => container.hasAnalyzedLayout)) {
    return containers.map((value) => value.toJson()).toList();
  }
  final source = rasterFromPayload(payload)?.toImage();
  if (source == null) {
    return containers.map((value) => value.toJson()).toList();
  }
  return containers.map((container) {
    if (container.hasAnalyzedLayout) {
      return container.toJson();
    }
    final regions = detectBubbleLayoutRegions(source, container);
    return {
      ...container.toJson(),
      'layoutRegions': regions.map((r) => r.toJson()).toList(),
      'layoutAnalysisVersion': 1,
    };
  }).toList();
}

/// Recover the uniform balloon interior, fill enclosed glyph holes, and find
/// inset rectangles. Recursively split only when two rectangles recover
/// substantially more interior than one: ordinary ovals stay a single area,
/// while concave chains can produce three, four, or more areas.
List<TranslationLayoutRegion> detectBubbleLayoutRegions(
  image.Image source,
  RecognizedTextContainer container,
) {
  final left = container.left.floor().clamp(0, source.width);
  final top = container.top.floor().clamp(0, source.height);
  final right = (container.left + container.width).ceil().clamp(
    0,
    source.width,
  );
  final bottom = (container.top + container.height).ceil().clamp(
    0,
    source.height,
  );
  if (right - left < 8 || bottom - top < 8) {
    return [];
  }
  final scale = math.min(1.0, 80 / math.max(right - left, bottom - top));
  final w = math.max(1, ((right - left) * scale).round());
  final h = math.max(1, ((bottom - top) * scale).round());
  final crop = image.copyResize(
    image.copyCrop(
      source,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    ),
    width: w,
    height: h,
    interpolation: image.Interpolation.average,
  );
  final counts = <int, int>{};
  final edgeCounts = <int, int>{};
  final sums = <int, List<int>>{};
  for (final p in crop) {
    final key =
        (p.r.toInt() ~/ 32) * 64 + (p.g.toInt() ~/ 32) * 8 + p.b.toInt() ~/ 32;
    counts[key] = (counts[key] ?? 0) + 1;
    if (p.x == 0 || p.y == 0 || p.x == w - 1 || p.y == h - 1) {
      edgeCounts[key] = (edgeCounts[key] ?? 0) + 1;
    }
    final sum = sums.putIfAbsent(key, () => [0, 0, 0]);
    sum[0] += p.r.toInt();
    sum[1] += p.g.toInt();
    sum[2] += p.b.toInt();
  }
  // A concave balloon's bounding box may contain more exterior than interior.
  // Penalize colours dominating its outer edge instead of selecting the page
  // background simply because it is the most frequent colour.
  double score(int key) =>
      counts[key]! -
      (edgeCounts[key] ?? 0) * w * h / math.max(1, 2 * (w + h) - 4) * .85;
  final key = counts.keys.reduce((a, b) => score(a) >= score(b) ? a : b);
  if (counts[key]! < w * h * .2) {
    return [];
  }
  final rgb = sums[key]!.map((sum) => sum / counts[key]!).toList();
  final mask = Uint8List(w * h);
  for (final p in crop) {
    if ((p.r - rgb[0]).abs() <= 38 &&
        (p.g - rgb[1]).abs() <= 38 &&
        (p.b - rgb[2]).abs() <= 38) {
      mask[p.y * w + p.x] = 1;
    }
  }
  // Only the largest colour-connected interior is credible within this box.
  final seen = Uint8List(mask.length);
  List<int> largest = [];
  List<int> flood(int seed, bool foreground) {
    final queue = <int>[seed];
    seen[seed] = 1;
    for (int i = 0; i < queue.length; i++) {
      final p = queue[i];
      final x = p % w, y = p ~/ w;
      for (final n in [
        if (x > 0) p - 1,
        if (x + 1 < w) p + 1,
        if (y > 0) p - w,
        if (y + 1 < h) p + w,
      ]) {
        if (seen[n] == 0 && (mask[n] == 1) == foreground) {
          seen[n] = 1;
          queue.add(n);
        }
      }
    }
    return queue;
  }

  for (int p = 0; p < mask.length; p++) {
    if (mask[p] == 1 && seen[p] == 0) {
      final component = flood(p, true);
      if (component.length > largest.length) {
        largest = component;
      }
    }
  }
  if (largest.length < w * h * .25) {
    return [];
  }
  mask.fillRange(0, mask.length, 0);
  for (final p in largest) {
    mask[p] = 1;
  }
  seen.fillRange(0, seen.length, 0);
  for (int p = 0; p < mask.length; p++) {
    if (mask[p] != 0 || seen[p] != 0) {
      continue;
    }
    final hole = flood(p, false);
    if (hole.length < largest.length * .08 &&
        !hole.any(
          (p) => p % w == 0 || p % w == w - 1 || p ~/ w == 0 || p ~/ w == h - 1,
        )) {
      for (final p in hole) {
        mask[p] = 1;
      }
    }
  }
  // One grid cell of clearance prevents anti-aliased outlines being touched.
  final inset = Uint8List(mask.length);
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      bool inside = true;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (mask[(y + dy) * w + x + dx] == 0) {
            inside = false;
          }
        }
      }
      if (inside) {
        inset[y * w + x] = 1;
      }
    }
  }
  final regions = partitionBubbleInterior(inset, w, h);
  return regions
      .map(
        (r) => TranslationLayoutRegion(
          left + r.left * (right - left) / w,
          top + r.top * (bottom - top) / h,
          r.width * (right - left) / w,
          r.height * (bottom - top) / h,
        ),
      )
      .toList();
}

/// All returned rectangles contain only interior cells and never overlap.
List<TranslationLayoutRegion> partitionBubbleInterior(
  Uint8List mask,
  int width,
  int height,
) {
  if (width <= 0 || height <= 0 || mask.length != width * height) {
    return [];
  }
  _Box largest(_Box bounds) {
    final heights = List<int>.filled(bounds.w, 0);
    var best = const _Box(0, 0, 0, 0);
    for (int y = bounds.y; y < bounds.y + bounds.h; y++) {
      for (int x = 0; x < bounds.w; x++) {
        heights[x] = mask[y * width + bounds.x + x] == 0 ? 0 : heights[x] + 1;
      }
      final stack = <int>[];
      for (int x = 0; x <= bounds.w; x++) {
        final value = x == bounds.w ? 0 : heights[x];
        while (stack.isNotEmpty && heights[stack.last] > value) {
          final tall = heights[stack.removeLast()];
          final start = stack.isEmpty ? 0 : stack.last + 1;
          final candidate = _Box(
            bounds.x + start,
            y - tall + 1,
            x - start,
            tall,
          );
          if (candidate.area > best.area) {
            best = candidate;
          }
        }
        stack.add(x);
      }
    }
    return best;
  }

  List<_Box> split(_Box bounds) {
    final whole = largest(bounds);
    if (whole.area < 36) {
      return whole.area == 0 ? [] : [whole];
    }
    double bestArea = whole.area * 1.30;
    (_Box, _Box)? best;
    for (final vertical in [true, false]) {
      final length = vertical ? bounds.w : bounds.h;
      for (int cut = 4; cut <= length - 4; cut += 2) {
        final a =
            vertical
                ? _Box(bounds.x, bounds.y, cut, bounds.h)
                : _Box(bounds.x, bounds.y, bounds.w, cut);
        final b =
            vertical
                ? _Box(bounds.x + cut, bounds.y, bounds.w - cut, bounds.h)
                : _Box(bounds.x, bounds.y + cut, bounds.w, bounds.h - cut);
        final ra = largest(a), rb = largest(b);
        if (ra.w < 4 ||
            ra.h < 4 ||
            rb.w < 4 ||
            rb.h < 4 ||
            math.min(ra.area, rb.area) < whole.area * .25) {
          continue;
        }
        if (ra.area + rb.area > bestArea) {
          bestArea = (ra.area + rb.area).toDouble();
          best = (a, b);
        }
      }
    }
    if (best == null) {
      return [whole];
    }
    return [...split(best.$1), ...split(best.$2)];
  }

  return split(_Box(0, 0, width, height))
      .map(
        (r) => TranslationLayoutRegion(
          r.x.toDouble(),
          r.y.toDouble(),
          r.w.toDouble(),
          r.h.toDouble(),
        ),
      )
      .toList();
}

class _Box {
  const _Box(this.x, this.y, this.w, this.h);
  final int x, y, w, h;
  int get area => w * h;
}
