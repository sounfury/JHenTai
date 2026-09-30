import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/utils/inpainting_pixels.dart';

const _root = 'test/acceptance/image_translation/white_outline_text';

void main() {
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  final source = img.decodeImage(File('$_root/source.png').readAsBytesSync())!;
  final observed =
      img.decodeImage(
        File('$_root/observed_background.png').readAsBytesSync(),
      )!;
  final snapshot = jsonDecode(
    File('$_root/pipeline_snapshot.json').readAsStringSync(),
  );
  final polygons = (snapshot['erasePolygons'] as List).map(
    (p) =>
        (p['points'] as List)
            .map(
              (point) => math.Point<double>(
                (point['x'] as num).toDouble(),
                (point['y'] as num).toDouble(),
              ),
            )
            .toList(),
  );
  final mask = refineInpaintingMask(
    source,
    rasterizeInpaintingMask(source.width, source.height, polygons),
  );
  final repaired = repairFlatInpaintingRegions(source, mask);

  test('真实灰色气泡中，黑字与相连的白色描边必须一起清除', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    final bounds = annotation['textBounds'] as List;
    int white = 0,
        black = 0,
        oldWhiteResidual = 0,
        whiteResidual = 0,
        blackResidual = 0;
    for (int y = bounds[1]; y < bounds[1] + bounds[3]; y++) {
      for (int x = bounds[0]; x < bounds[0] + bounds[2]; x++) {
        final before = source.getPixel(x, y).luminance;
        final after = repaired.image.getPixel(x, y).luminance;
        if (before > 235) {
          white++;
          if (observed.getPixel(x, y).luminance > 220) oldWhiteResidual++;
          if (after > 220) whiteResidual++;
        }
        if (before < 80) {
          black++;
          if (after < 100) blackResidual++;
        }
      }
    }
    expect(white, greaterThan(4000));
    expect(black, greaterThan(1500));
    expect(
      oldWhiteResidual / white,
      greaterThan(.5),
      reason: '保留用户实际遇到的白描边残留证据',
    );
    expect(whiteResidual / white, lessThan(annotation['maxResidualFraction']));
    expect(blackResidual / black, lessThan(annotation['maxResidualFraction']));
    expect(
      repaired.remainingMask.contains(0),
      isFalse,
      reason: '此灰色气泡可直接恢复周围底色',
    );
  });

  test('描边清理只影响文字，气泡边框和周围画面保持原样', () {
    // This larger ROI includes the balloon outline, tail, wall and foreground.
    for (int y = 0; y < 320; y++) {
      for (int x = 1050; x < source.width; x++) {
        final before = source.getPixel(x, y),
            after = repaired.image.getPixel(x, y);
        if (mask[y * source.width + x] != 0) {
          expect(
            [after.r, after.g, after.b, after.a],
            [before.r, before.g, before.b, before.a],
            reason: '擦除掩码外像素 ($x, $y) 发生改变',
          );
        }
        // White border must not become authorized for erasure either.
        if ((x < 1109 || x >= 1180 || y < 59 || y >= 263) &&
            before.luminance > 235) {
          expect(mask[y * source.width + x], 255, reason: '气泡外轮廓不能被当成文字描边');
        }
      }
    }
  });
}
