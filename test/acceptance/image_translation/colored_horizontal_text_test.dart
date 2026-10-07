// 验收真实第二页的横排多行彩字擦除，防止整段漏擦、描边残留和误擦未翻译文字。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/utils/inpainting_pixels.dart';

const _root = 'test/acceptance/image_translation/colored_horizontal_text';

void main() {
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  final source = img.decodeImage(File('$_root/source.png').readAsBytesSync())!;
  final observed =
      img.decodeImage(File('$_root/observed.png').readAsBytesSync())!;
  final blocks =
      (annotation['translatedBlocks'] as List)
          .map((b) => RecognizedTextBlock.fromJson(b))
          .toList();
  final snapshot = jsonDecode(
    File('$_root/pipeline_snapshot.json').readAsStringSync(),
  );
  final masks =
      (snapshot['erasePolygons'] as List)
          .map(
            (p) => PolygonMask(
              points:
                  (p['points'] as List)
                      .map(
                        (v) => EnginePoint(
                          x: (v['x'] as num).toDouble(),
                          y: (v['y'] as num).toDouble(),
                        ),
                      )
                      .toList(),
              confidence: (p['confidence'] as num).toDouble(),
            ),
          )
          .toList();

  test('真实整段横排对白进入擦除，多余检测区域仍被排除', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    final kept = filterPolygonMasksToTranslatedBlocks(
      masks: masks,
      translatedBlocks: blocks,
    );
    expect(kept.length, annotation['expectedSelectedMasks']);
    expect(
      kept.any((m) => m.left > 1070 && m.top < 160 && m.bottom > 510),
      isTrue,
    );
    expect(
      kept.any((m) => m.left < 825 && m.top > 1440 && m.bottom > 1680),
      isTrue,
    );
    expect(kept.where((m) => m.top > 1790).length, 1, reason: '未翻译的相机菜单不应被擦除');
  });

  test('真实彩字及白描边覆盖完整，保留未翻译菜单和周围画面', () {
    final kept = filterPolygonMasksToTranslatedBlocks(
      masks: masks,
      translatedBlocks: blocks,
    );
    final coarse = rasterizeInpaintingMask(
      source.width,
      source.height,
      kept.map(
        (m) => m.points.map((p) => math.Point<double>(p.x, p.y)).toList(),
      ),
    );
    final refined = refineInpaintingMask(source, coarse);
    int white = 0,
        missedWhite = 0,
        colored = 0,
        missedColored = 0,
        oldWhite = 0;
    for (final rect in annotation['evaluationRects'] as List) {
      for (int y = rect[1]; y < rect[1] + rect[3]; y++) {
        for (int x = rect[0]; x < rect[0] + rect[2]; x++) {
          final p = source.getPixel(x, y);
          final i = y * source.width + x;
          if (p.r > 245 && p.g > 245 && p.b > 245) {
            white++;
            if (refined[i] != 0) missedWhite++;
            final old = observed.getPixel(x, y);
            if (old.r > 240 && old.g > 240 && old.b > 240) oldWhite++;
          }
          if (p.r > 150 && p.g < 100 && p.b > 90) {
            colored++;
            if (refined[i] != 0) missedColored++;
          }
        }
      }
    }
    expect(white, greaterThan(30000));
    expect(colored, greaterThan(25000));
    expect(oldWhite / white, greaterThan(.45), reason: '保留真实白描边残留证据');
    expect(missedWhite / white, lessThan(.01));
    expect(missedColored / colored, lessThan(.01));
    for (int y = 1790; y < 1870; y++) {
      for (int x = 20; x < 540; x++) {
        expect(
          refined[y * source.width + x],
          255,
          reason: '未翻译的菜单 ($x,$y) 必须保留',
        );
      }
    }
    for (int y = 150; y < 360; y++) {
      for (int x = 960; x < 1030; x++) {
        expect(refined[y * source.width + x], 255, reason: '对白旁的白色装饰弧线必须保留');
      }
    }
  });

  test('真实多行区域只翻译一行时，重复 OCR 框不能误授权擦除整段', () {
    final top = masks.singleWhere(
      (m) => m.left > 1070 && m.top < 160 && m.bottom > 510,
    );
    expect(
      filterPolygonMasksToTranslatedBlocks(
        masks: [top],
        translatedBlocks: List.filled(8, blocks[1]),
      ),
      isEmpty,
    );
    expect(
      filterPolygonMasksToTranslatedBlocks(
        masks: [top],
        translatedBlocks: blocks.sublist(1, 3),
        protectedBlocks: blocks.sublist(3, 9),
      ),
      isEmpty,
      reason: '其余未翻译行仍应受保护',
    );
  });
}
