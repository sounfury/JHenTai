import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Rasterize only detector polygons; OCR rectangles never authorize erasure.
Uint8List rasterizeInpaintingMask(
  int width,
  int height,
  Iterable<List<math.Point<double>>> polygons,
) {
  final result = Uint8List(width * height)..fillRange(0, width * height, 255);
  bool painted = false;
  for (final points in polygons) {
    if (points.length < 3) throw ArgumentError('invalid polygon');
    final left = math.max(0, points.map((p) => p.x).reduce(math.min).floor());
    final top = math.max(0, points.map((p) => p.y).reduce(math.min).floor());
    final right = math.min(
      width - 1,
      points.map((p) => p.x).reduce(math.max).ceil(),
    );
    final bottom = math.min(
      height - 1,
      points.map((p) => p.y).reduce(math.max).ceil(),
    );
    for (int y = top; y <= bottom; y++) {
      for (int x = left; x <= right; x++) {
        bool inside = false;
        for (int i = 0, j = points.length - 1; i < points.length; j = i++) {
          final a = points[i], b = points[j];
          if ((a.y > y + .5) != (b.y > y + .5) &&
              x + .5 < (b.x - a.x) * (y + .5 - a.y) / (b.y - a.y) + a.x) {
            inside = !inside;
          }
        }
        if (inside) {
          result[y * width + x] = 0;
          painted = true;
        }
      }
    }
  }
  if (!painted)
    throw StateError('polygon masks do not cover any source pixels');
  return result;
}

class FlatInpaintingResult {
  const FlatInpaintingResult(
    this.image,
    this.remainingMask,
    this.repairedPixels,
  );
  final img.Image image;
  final Uint8List remainingMask;
  final int repairedPixels;
}

/// Flat balloon fills need no generative prediction. Require nearly all
/// unmasked context to agree on a colour; patterned/shaded regions keep their
/// original mask for LaMa. Modify only glyph pixels already approved for erase.
FlatInpaintingResult repairFlatInpaintingRegions(
  img.Image source,
  Uint8List knownMask,
) {
  final w = source.width, h = source.height;
  if (knownMask.length != w * h) throw ArgumentError('mask dimensions');
  final output = img.Image.from(source);
  final remaining = Uint8List.fromList(knownMask);
  final visited = Uint8List(w * h);
  final queue = <int>[];
  int repaired = 0;
  for (int seed = 0; seed < knownMask.length; seed++) {
    if (knownMask[seed] != 0 || visited[seed] != 0) continue;
    queue.clear();
    queue.add(seed);
    visited[seed] = 1;
    for (int head = 0; head < queue.length; head++) {
      final i = queue[head], x = i % w, y = i ~/ w;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final next = ny * w + nx;
          if (knownMask[next] == 0 && visited[next] == 0) {
            visited[next] = 1;
            queue.add(next);
          }
        }
      }
    }
    // Follow the actual component contour. The bounding rectangle of joined
    // or slanted columns can include the balloon border and outside artwork,
    // wrongly sending a uniform fill through generative inpainting.
    final context = <int>{};
    for (final i in queue) {
      final x = i % w, y = i ~/ w;
      bool boundary = false;
      for (int dy = -1; dy <= 1 && !boundary; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx >= 0 &&
              ny >= 0 &&
              nx < w &&
              ny < h &&
              knownMask[ny * w + nx] != 0) {
            boundary = true;
            break;
          }
        }
      }
      if (!boundary) continue;
      for (int dy = -3; dy <= 3; dy++) {
        for (int dx = -3; dx <= 3; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final next = ny * w + nx;
          if (knownMask[next] != 0) context.add(next);
        }
      }
    }
    final bins = <int, List<int>>{};
    int samples = 0;
    for (final i in context) {
      final p = source.getPixel(i % w, i ~/ w);
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final bin = bins.putIfAbsent(
        (r >> 4) * 256 + (g >> 4) * 16 + (b >> 4),
        () => [0, 0, 0, 0],
      );
      bin[0]++;
      bin[1] += r;
      bin[2] += g;
      bin[3] += b;
      samples++;
    }
    if (samples < 12) continue;
    final best = bins.values.reduce((a, b) => a[0] >= b[0] ? a : b);
    final r = (best[1] / best[0]).round(),
        g = (best[2] / best[0]).round(),
        b = (best[3] / best[0]).round();
    // Scanned white paper contains faint grain and antialiasing. Allow this
    // small luminance variation only around an almost-white dominant colour.
    final tolerance = r >= 250 && g >= 250 && b >= 250 ? 20 : 8;
    int agreeing = 0;
    for (final i in context) {
      final p = source.getPixel(i % w, i ~/ w);
      if ((p.r - r).abs() <= tolerance &&
          (p.g - g).abs() <= tolerance &&
          (p.b - b).abs() <= tolerance)
        agreeing++;
    }
    if (agreeing < samples * .97) continue;
    for (final i in queue) {
      output.setPixelRgb(i % w, i ~/ w, r, g, b);
      remaining[i] = 255;
    }
    repaired += queue.length;
  }
  return FlatInpaintingResult(output, remaining, repaired);
}

/// Refine coarse detection polygons against source pixels. Keep complete ink
/// components supported by the detector, reject lines connected to surrounding
/// artwork, then grow by a glyph-relative radius to cover antialiased edges.
/// The mask convention here is 0=repair, 255=keep (independent of model input).
Uint8List refineInpaintingMask(img.Image source, Uint8List coarse) {
  final w = source.width, h = source.height;
  if (coarse.length != w * h) throw ArgumentError('mask dimensions');
  final result = Uint8List(w * h)..fillRange(0, w * h, 255);
  final visited = Uint8List(w * h);
  final queue = Int32List(w * h);
  final gray = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final p = source.getPixel(x, y);
      gray[y * w + x] = ((p.r * 299 + p.g * 587 + p.b * 114) / 1000).round();
    }
  }
  final outlineCandidates = _contrastOutlineCandidates(gray, coarse, w, h);
  // Local background contrast separates white outlines from the balloon.
  // Outlines may connect several letters, so only this pass accepts taller
  // components, and only when anchored to already accepted dark glyphs.
  for (int polarity = 0; polarity < 3; polarity++) {
    visited.fillRange(0, visited.length, 0);
    final outlined = polarity == 2;
    bool isInk(int i) => switch (polarity) {
      0 => gray[i] < 180,
      1 => gray[i] > 75,
      _ => outlineCandidates[i] != 0,
    };
    for (int seed = 0; seed < coarse.length; seed++) {
      if (visited[seed] != 0 || !isInk(seed)) continue;
      int head = 0, tail = 1, supported = 0;
      int left = seed % w, right = left, top = seed ~/ w, bottom = top;
      queue[0] = seed;
      visited[seed] = 1;
      while (head < tail) {
        final i = queue[head++], x = i % w, y = i ~/ w;
        if (coarse[i] == 0) supported++;
        left = math.min(left, x);
        right = math.max(right, x);
        top = math.min(top, y);
        bottom = math.max(bottom, y);
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final next = ny * w + nx;
            if (visited[next] == 0 && isInk(next)) {
              visited[next] = 1;
              queue[tail++] = next;
            }
          }
        }
      }
      if (tail < 2 || supported / tail < 0.9) continue;
      final bw = right - left + 1, bh = bottom - top + 1;
      // Reject backgrounds, panel edges and long connected illustration lines.
      if (bw > w * 0.12 ||
          bh > h * (outlined ? 0.4 : 0.08) ||
          tail > w * h * (outlined ? 0.006 : 0.002))
        continue;
      if (outlined) {
        int anchored = 0;
        for (int j = 0; j < tail; j++) {
          final x = queue[j] % w, y = queue[j] ~/ w;
          bool touchesGlyph = false;
          for (int dy = -2; dy <= 2 && !touchesGlyph; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
              final nx = x + dx, ny = y + dy;
              if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
              final next = ny * w + nx;
              if (result[next] == 0 && gray[next] < 100) {
                touchesGlyph = true;
                break;
              }
            }
          }
          if (touchesGlyph) anchored++;
        }
        if (anchored < math.min(12, tail * .1)) continue;
      }
      final radius = (math.min(bw, bh) * 0.12).ceil().clamp(1, 4);
      for (int j = 0; j < tail; j++) {
        final x = queue[j] % w, y = queue[j] ~/ w;
        for (int dy = -radius; dy <= radius; dy++) {
          for (int dx = -radius; dx <= radius; dx++) {
            if (dx * dx + dy * dy > radius * radius) continue;
            final nx = x + dx, ny = y + dy;
            if (nx >= 0 && ny >= 0 && nx < w && ny < h) result[ny * w + nx] = 0;
          }
        }
      }
    }
  }
  return result;
}

/// Estimate the surrounding tone independently for short bands of each CTD
/// region. A dominant histogram bin rejects incidental ink in the context;
/// bands follow gradients instead of assuming a page-wide background colour.
/// Only pixels brighter than the midpoint between that tone and white become
/// candidates. Detector support and dark-glyph anchors are still checked by
/// [refineInpaintingMask] before any candidate authorizes erasure.
Uint8List _contrastOutlineCandidates(
  Uint8List gray,
  Uint8List coarse,
  int w,
  int h,
) {
  final candidates = Uint8List(w * h);
  final visited = Uint8List(w * h);
  final queue = <int>[];
  for (int seed = 0; seed < coarse.length; seed++) {
    if (coarse[seed] != 0 || visited[seed] != 0) continue;
    queue.clear();
    queue.add(seed);
    visited[seed] = 1;
    int left = seed % w, right = left, top = seed ~/ w, bottom = top;
    for (int head = 0; head < queue.length; head++) {
      final i = queue[head], x = i % w, y = i ~/ w;
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
            queue.add(next);
          }
        }
      }
    }
    final shortSide = math.min(right - left + 1, bottom - top + 1);
    final bandSize = (shortSide ~/ 2).clamp(8, 32);
    final margin = (shortSide * .2).ceil().clamp(4, 12);
    final x0 = math.max(0, left - margin), x1 = math.min(w - 1, right + margin);
    final y0 = math.max(0, top - 4), y1 = math.min(h - 1, bottom + 4);
    for (int band = y0; band <= y1; band += bandSize) {
      final end = math.min(y1, band + bandSize - 1);
      final counts = List<int>.filled(32, 0);
      final sums = List<int>.filled(32, 0);
      int samples = 0;
      for (
        int y = math.max(0, band - margin);
        y <= math.min(h - 1, end + margin);
        y++
      ) {
        for (int x = x0; x <= x1; x++) {
          final i = y * w + x;
          if (coarse[i] == 0) continue;
          final bin = gray[i] >> 3;
          counts[bin]++;
          sums[bin] += gray[i];
          samples++;
        }
      }
      if (samples < 12) continue;
      int best = 0;
      for (int bin = 1; bin < counts.length; bin++) {
        if (counts[bin] > counts[best]) best = bin;
      }
      final background = sums[best] / counts[best];
      final threshold = background + (255 - background) * .5;
      for (int y = band; y <= end; y++) {
        for (
          int x = math.max(0, left - 4);
          x <= math.min(w - 1, right + 4);
          x++
        ) {
          final i = y * w + x;
          if (gray[i] > threshold) candidates[i] = 1;
        }
      }
    }
  }
  return candidates;
}

class LamaInput {
  const LamaInput(
    this.rgb,
    this.mask,
    this.width,
    this.height,
    this.contentWidth,
    this.contentHeight,
  );
  final Float32List rgb;
  final Float32List mask;
  final int width, height, contentWidth, contentHeight;
}

/// Preserve aspect ratio and pad to 64, matching LaMa Large's encoder stride.
LamaInput prepareLamaInput(
  img.Image source,
  Uint8List knownMask, {
  int maxSide = 2048,
}) {
  if (knownMask.length != source.width * source.height || maxSide < 64) {
    throw ArgumentError('invalid LaMa input');
  }
  final scale = math.min(1.0, maxSide / math.max(source.width, source.height));
  final cw = math.max(1, (source.width * scale).round());
  final ch = math.max(1, (source.height * scale).round());
  final w = ((cw + 63) ~/ 64) * 64, h = ((ch + 63) ~/ 64) * 64;
  final resized = img.copyResize(
    source,
    width: cw,
    height: ch,
    interpolation: img.Interpolation.linear,
  );
  final rgb = Float32List(3 * w * h), mask = Float32List(w * h);
  int mirror(int i, int n) {
    final j = i % (2 * n);
    return j < n ? j : 2 * n - 1 - j;
  }

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final px = mirror(x, cw), py = mirror(y, ch);
      final p = resized.getPixel(px, py), i = y * w + x;
      rgb[i] = p.r / 255;
      rgb[w * h + i] = p.g / 255;
      rgb[2 * w * h + i] = p.b / 255;
      // Max-pool the repair mask when shrinking; nearest-neighbor alone can
      // discard thin strokes entirely before inference.
      final x0 = px * source.width ~/ cw, y0 = py * source.height ~/ ch;
      final x1 = ((px + 1) * source.width / cw).ceil().clamp(1, source.width);
      final y1 = ((py + 1) * source.height / ch).ceil().clamp(1, source.height);
      for (int sy = y0; sy < y1 && mask[i] == 0; sy++) {
        for (int sx = x0; sx < x1; sx++) {
          if (knownMask[sy * source.width + sx] == 0) {
            mask[i] = 1;
            break;
          }
        }
      }
    }
  }
  return LamaInput(rgb, mask, w, h, cw, ch);
}

/// Never let model output alter pixels outside the original refined mask.
img.Image compositeLamaOutput(
  img.Image source,
  Uint8List knownMask,
  img.Image prediction,
) {
  if (knownMask.length != source.width * source.height)
    throw ArgumentError('mask dimensions');
  final output = img.Image.from(source);
  // copyResize interpolates the entire page even though only refined glyph
  // pixels are used. Sample those pixels at the same source coordinates.
  final double scaleX = prediction.width / source.width;
  final double scaleY = prediction.height / source.height;
  for (int y = 0; y < source.height; y++) {
    for (int x = 0; x < source.width; x++) {
      if (knownMask[y * source.width + x] != 0) continue;
      final p = prediction.getPixelInterpolate(
        x * scaleX,
        y * scaleY,
        interpolation: img.Interpolation.cubic,
      );
      output.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }
  return output;
}
