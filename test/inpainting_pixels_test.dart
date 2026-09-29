import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/utils/inpainting_pixels.dart';

void main() {
  test(
    'refinement keeps glyphs but rejects a border crossing the detector',
    () {
      final source = img.Image(width: 200, height: 200);
      img.fill(source, color: img.ColorRgb8(255, 255, 255));
      img.fillRect(
        source,
        x1: 60,
        y1: 60,
        x2: 65,
        y2: 69,
        color: img.ColorRgb8(0, 0, 0),
      );
      img.drawLine(
        source,
        x1: 80,
        y1: 0,
        x2: 80,
        y2: 199,
        color: img.ColorRgb8(0, 0, 0),
      );
      final coarse = Uint8List(40000)..fillRange(0, 40000, 255);
      for (int y = 50; y < 90; y++) {
        for (int x = 50; x < 90; x++) {
          coarse[y * 200 + x] = 0;
        }
      }
      final refined = refineInpaintingMask(source, coarse);
      expect(refined[65 * 200 + 63], 0);
      expect(refined[60 * 200 + 59], 0, reason: 'cover antialiased glyph edge');
      expect(
        refined[65 * 200 + 80],
        255,
        reason: 'preserve crossing bubble border',
      );
      expect(
        refined[52 * 200 + 52],
        255,
        reason: 'do not erase the entire coarse polygon',
      );
    },
  );

  test('LaMa input uses normalized RGB, repair=1, symmetric 64 padding', () {
    final source = img.Image(width: 3, height: 2);
    img.fill(source, color: img.ColorRgb8(255, 128, 0));
    final mask = Uint8List.fromList([255, 0, 255, 255, 255, 255]);
    final input = prepareLamaInput(source, mask);
    expect(input.width, 64);
    expect(input.height, 64);
    expect(input.contentWidth, 3);
    expect(input.contentHeight, 2);
    expect(input.rgb[0], 1);
    expect(input.rgb[4096], closeTo(128 / 255, 1e-6));
    expect(input.rgb[8192], 0);
    expect(input.mask[1], 1);
    expect(input.mask[0], 0);
    expect(input.mask[4], 1, reason: 'symmetric padding mirrors the mask');
  });

  test('refinement also supports white glyphs on a dark background', () {
    final source = img.Image(width: 200, height: 200);
    img.fill(source, color: img.ColorRgb8(0, 0, 0));
    img.fillRect(
      source,
      x1: 60,
      y1: 60,
      x2: 65,
      y2: 69,
      color: img.ColorRgb8(255, 255, 255),
    );
    final coarse = Uint8List(40000)..fillRange(0, 40000, 255);
    for (int y = 50; y < 90; y++) {
      for (int x = 50; x < 90; x++) {
        coarse[y * 200 + x] = 0;
      }
    }
    final refined = refineInpaintingMask(source, coarse);
    expect(refined[65 * 200 + 63], 0);
    expect(refined[52 * 200 + 52], 255);
  });

  test('an empty detection never erases source pixels', () {
    final source = img.Image(width: 200, height: 200);
    img.fill(source, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(
      source,
      x1: 60,
      y1: 60,
      x2: 65,
      y2: 69,
      color: img.ColorRgb8(0, 0, 0),
    );
    final coarse = Uint8List(40000)..fillRange(0, 40000, 255);
    expect(refineInpaintingMask(source, coarse), everyElement(255));
  });

  test('shrinking a mask cannot discard a one-pixel stroke', () {
    final source = img.Image(width: 128, height: 128);
    final mask = Uint8List(128 * 128)..fillRange(0, 128 * 128, 255);
    mask[1 * 128 + 1] = 0;
    final input = prepareLamaInput(source, mask, maxSide: 64);
    expect(input.mask[0], 1);
  });

  test('compositing preserves every unmasked source pixel and alpha', () {
    final source = img.Image(width: 3, height: 2, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(10, 20, 30, 100));
    final prediction = img.Image(width: 3, height: 2);
    img.fill(prediction, color: img.ColorRgb8(255, 255, 255));
    final output = compositeLamaOutput(
      source,
      Uint8List.fromList([255, 0, 255, 255, 255, 255]),
      prediction,
    );
    expect(output.getPixel(1, 0).r, 255);
    expect(output.getPixel(0, 0).r, 10);
    expect(output.getPixel(0, 0).a, 100);
    expect(source.getPixel(1, 0).r, 10);
  });

  test('sparse compositing matches full-page cubic interpolation', () {
    final source = img.Image(width: 24, height: 32, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(10, 20, 30, 128));
    final prediction = img.Image(width: 8, height: 10, numChannels: 4);
    for (int y = 0; y < prediction.height; y++) {
      for (int x = 0; x < prediction.width; x++) {
        prediction.setPixelRgb(x, y, x * 25, y * 21, (x + y) * 12);
      }
    }
    final mask = Uint8List(source.width * source.height)
      ..fillRange(0, source.width * source.height, 255);
    for (final (int, int) point in <(int, int)>[(1, 2), (7, 12), (22, 29)]) {
      mask[point.$2 * source.width + point.$1] = 0;
    }
    final expected = img.copyResize(
      prediction,
      width: source.width,
      height: source.height,
      interpolation: img.Interpolation.cubic,
    );
    final output = compositeLamaOutput(source, mask, prediction);
    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        final pixel = output.getPixel(x, y);
        if (mask[y * source.width + x] == 0) {
          final reference = expected.getPixel(x, y);
          expect(
            [pixel.r, pixel.g, pixel.b],
            [reference.r, reference.g, reference.b],
          );
        } else {
          expect([pixel.r, pixel.g, pixel.b, pixel.a], [10, 20, 30, 128]);
        }
      }
    }
  });
}
