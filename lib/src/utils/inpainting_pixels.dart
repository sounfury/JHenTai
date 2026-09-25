import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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
  // Text can be dark on a light bubble or light on a dark one. Process both
  // polarities; a page background component is rejected by support/size tests.
  for (final bool dark in <bool>[true, false]) {
    visited.fillRange(0, visited.length, 0);
    bool isInk(int i) => dark ? gray[i] < 180 : gray[i] > 75;
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
      if (bw > w * 0.12 || bh > h * 0.08 || tail > w * h * 0.002) continue;
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
  final scaled = img.copyResize(
    prediction,
    width: source.width,
    height: source.height,
    interpolation: img.Interpolation.cubic,
  );
  final output = img.Image.from(source);
  for (int y = 0; y < source.height; y++) {
    for (int x = 0; x < source.width; x++) {
      if (knownMask[y * source.width + x] != 0) continue;
      final p = scaled.getPixel(x, y);
      output.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }
  return output;
}
