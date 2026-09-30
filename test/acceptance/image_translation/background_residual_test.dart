import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/utils/inpainting_pixels.dart';

const _root = 'test/acceptance/image_translation/background_residual';

void main() {
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  final snapshot = jsonDecode(
    File('$_root/pipeline_snapshot.json').readAsStringSync(),
  );
  final source = img.decodeImage(File('$_root/source.png').readAsBytesSync())!;
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
  final coarse = rasterizeInpaintingMask(source.width, source.height, polygons);
  final mask = refineInpaintingMask(source, coarse);
  final repaired = repairFlatInpaintingRegions(source, mask);

  test('真实气泡的日文笔画被清理，旧修复背景确实留有残影', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    final observed =
        img.decodeImage(
          File('$_root/observed_background.png').readAsBytesSync(),
        )!;
    final target = (snapshot['blocks'] as List).singleWhere(
      (b) => b['text'] == annotation['targetSourceText'],
    );
    int ink = 0, oldResidual = 0, residual = 0;
    for (
      int y = (target['top'] as num).floor();
      y < (target['top'] + target['height'] as num).ceil();
      y++
    ) {
      for (
        int x = (target['left'] as num).floor();
        x < (target['left'] + target['width'] as num).ceil();
        x++
      ) {
        if (source.getPixel(x, y).luminance >= 140) continue;
        ink++;
        if (observed.getPixel(x, y).luminance < 235) oldResidual++;
        if (repaired.image.getPixel(x, y).luminance < 235) residual++;
      }
    }
    expect(ink, greaterThan(500));
    expect(oldResidual / ink, greaterThan(.2), reason: '原来的 LaMa 背景存在肉眼可见的残影');
    expect(
      residual / ink,
      lessThan(annotation['maxResidualInkFraction']),
      reason: '原文的位置应恢复为干净的气泡底色',
    );
  });

  test('纯色气泡清理后无需调用 LaMa，擦除区外画面保持原样', () {
    expect(repaired.repairedPixels, greaterThan(0));
    expect(
      repaired.remainingMask.contains(0),
      isFalse,
      reason: '纯色气泡不应每次等待模型初始化和推理',
    );
    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        if (mask[y * source.width + x] == 0) continue;
        final before = source.getPixel(x, y),
            after = repaired.image.getPixel(x, y);
        if (before.r != after.r ||
            before.g != after.g ||
            before.b != after.b ||
            before.a != after.a) {
          fail('擦除区外画面发生改变：($x, $y)');
        }
      }
    }
  });
}
