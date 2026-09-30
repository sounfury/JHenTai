import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/utils/inpainting_pixels.dart';

const _root = 'test/acceptance/image_translation/pink_outline_text';

void main() {
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  final source = img.decodeImage(File('$_root/source.png').readAsBytesSync())!;
  final snapshot = jsonDecode(
    File('$_root/pipeline_snapshot.json').readAsStringSync(),
  );
  final polygons = (snapshot['erasePolygons'] as List).map(
    (p) =>
        (p['points'] as List)
            .map(
              (p) => math.Point<double>(
                (p['x'] as num).toDouble(),
                (p['y'] as num).toDouble(),
              ),
            )
            .toList(),
  );
  final coarse = rasterizeInpaintingMask(source.width, source.height, polygons);
  final bounds = annotation['textBounds'] as List;
  final evaluationRects = annotation['evaluationRects'] as List;
  bool isTextPixel(int x, int y) => evaluationRects.any(
    (r) => x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3],
  );

  test('浅粉色渐变原页的白描边和黑字均进入擦除掩码，保留边框及拟声词', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    final mask = refineInpaintingMask(source, coarse);
    int white = 0, missedWhite = 0, black = 0, missedBlack = 0;
    for (int y = bounds[1]; y < bounds[1] + bounds[3]; y++) {
      for (int x = bounds[0]; x < bounds[0] + bounds[2]; x++) {
        if (!isTextPixel(x, y)) continue;
        final tone = source.getPixel(x, y).luminance;
        if (tone > annotation['whiteSourceThreshold']) {
          white++;
          if (mask[y * source.width + x] != 0) missedWhite++;
        }
        if (tone < 80) {
          black++;
          if (mask[y * source.width + x] != 0) missedBlack++;
        }
      }
    }
    expect(white, greaterThan(2000));
    expect(black, greaterThan(500));
    expect(missedWhite / white, lessThan(.01));
    expect(missedBlack / black, lessThan(.01));
    // The larger region includes the balloon border and adjacent pink SFX.
    for (int y = 290; y < 575; y++) {
      for (int x = 45; x < 220; x++) {
        if (x < 118 || x >= 180 || y < 328 || y >= 527) {
          expect(
            mask[y * source.width + x],
            255,
            reason: '气泡边框及拟声词 ($x, $y) 不应授权擦除',
          );
        }
      }
    }
  });

  // Change only the tone curve of the real glyph/background geometry. These
  // are derived stress cases, not additional user-provided source evidence.
  for (final (label, background) in <(String, List<int>)>[
    ('亮度 120', [120, 120, 120]),
    ('亮度 180', [180, 180, 180]),
    ('亮度 230', [230, 230, 230]),
    ('亮度 240', [240, 240, 240]),
    ('蓝底', [130, 170, 220]),
    ('绿底', [170, 225, 185]),
    ('米黄底', [245, 232, 190]),
    ('淡紫底', [245, 210, 235]),
  ]) {
    test('同一真实描边在$label下自动适配', () {
      final variant = img.Image.from(source);
      for (int y = 290; y < 575; y++) {
        for (int x = 45; x < 220; x++) {
          final tone = source.getPixel(x, y).luminance;
          double channel(int value) =>
              tone <= 218
                  ? tone / 218 * value
                  : value + (tone - 218) / (255 - 218) * (255 - value);
          variant.setPixelRgb(
            x,
            y,
            channel(background[0]),
            channel(background[1]),
            channel(background[2]),
          );
        }
      }
      final mask = refineInpaintingMask(variant, coarse);
      int white = 0, missedWhite = 0;
      for (int y = bounds[1]; y < bounds[1] + bounds[3]; y++) {
        for (int x = bounds[0]; x < bounds[0] + bounds[2]; x++) {
          if (!isTextPixel(x, y)) continue;
          if (source.getPixel(x, y).luminance <= 245) continue;
          white++;
          if (mask[y * source.width + x] != 0) missedWhite++;
        }
      }
      expect(missedWhite / white, lessThan(.01));
    });
  }
}
