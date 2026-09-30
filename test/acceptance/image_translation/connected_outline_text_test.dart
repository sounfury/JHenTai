import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/utils/inpainting_pixels.dart';

const _root = 'test/acceptance/image_translation/connected_outline_text';

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
              (p) => math.Point<double>(
                (p['x'] as num).toDouble(),
                (p['y'] as num).toDouble(),
              ),
            )
            .toList(),
  );
  final mask = refineInpaintingMask(
    source,
    rasterizeInpaintingMask(source.width, source.height, polygons),
  );
  final flat = repairFlatInpaintingRegions(source, mask);

  test('相连灰色气泡的弯斜文字区域按实际轮廓采样，完整恢复灰底', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    expect(
      flat.remainingMask.contains(0),
      isFalse,
      reason: '均匀灰底不应因外接矩形中的气泡边框及褐色画面而进入 LaMa',
    );
    final background = annotation['uniformBackgroundColor'] as List;
    bool residual(img.Pixel p) =>
        (p.r - background[0]).abs() > 12 ||
        (p.g - background[1]).abs() > 12 ||
        (p.b - background[2]).abs() > 12;
    final rects = annotation['evaluationRects'] as List;
    int foreground = 0, oldResidual = 0, newResidual = 0;
    for (int y = 41; y < 285; y++) {
      for (int x = 669; x < 780; x++) {
        if (!rects.any(
          (r) => x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3],
        ))
          continue;
        final before = source.getPixel(x, y).luminance;
        if (before >= 80 && before <= 235) continue;
        foreground++;
        if (residual(observed.getPixel(x, y))) oldResidual++;
        if (residual(flat.image.getPixel(x, y))) newResidual++;
      }
    }
    expect(foreground, greaterThan(4000));
    expect(
      oldResidual / foreground,
      greaterThan(.02),
      reason: '捕捉淡灰色字形残影，不能仅以黑白阈值判断成图干净',
    );
    expect(newResidual / foreground, lessThan(.01));
    final output = Directory('.dart_tool/acceptance/connected_outline_text');
    output.createSync(recursive: true);
    File(
      '${output.path}/flat_preview.png',
    ).writeAsBytesSync(img.encodePng(flat.image));
  });

  test('恢复底色不能改变边框、拟声词及其他未翻译区域', () {
    int changedOutsideMask = 0;
    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        if (mask[y * source.width + x] == 0) continue;
        final a = source.getPixel(x, y), b = flat.image.getPixel(x, y);
        if (a.r != b.r || a.g != b.g || a.b != b.b || a.a != b.a) {
          changedOutsideMask++;
        }
      }
    }
    expect(changedOutsideMask, 0);
    // The mask itself must also stay away from the balloon's outline and SFX.
    for (int y = 0; y < 320; y++) {
      for (int x = 640; x < 820; x++) {
        final textVicinity =
            (x >= 726 && x < 783 && y >= 40 && y < 192) ||
            (x >= 666 && x < 723 && y >= 116 && y < 287);
        if (!textVicinity) expect(mask[y * source.width + x], 255);
      }
    }
  });
}
