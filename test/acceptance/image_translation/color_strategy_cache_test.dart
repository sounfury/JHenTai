// 验收真实第五页的策略缓存隔离及彩漫对白擦除，防止旧黑白背景再次显示。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/utils/inpainting_pixels.dart';
import 'package:jhentai/src/utils/page_processing_strategy.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';
import 'package:jhentai/src/utils/image_translation_renderer.dart';

const _root = 'test/acceptance/image_translation/color_strategy_cache';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());

  test('第五页蓝字与粉字独立分组，乱序 OCR 不串色且按原文顺序排版', () {
    final cached = ImageTranslationResult.fromCacheJson(
      jsonDecode(File('$_root/translation.json').readAsStringSync()),
    );
    final groups = translationTextGroups(cached.blocks);
    final blueIndices = [5, 6, 7, 18, 16, 17, 15];
    final blue = groups.singleWhere((g) => g.blockIndices.contains(5));
    expect(blue.blockIndices, blueIndices);
    for (final group in groups) {
      final colors = group.blockIndices.map((i) => cached.blocks[i].textColor!);
      final hasBlue = colors.any((c) => (c & 255) > (c >> 16 & 255) + 80);
      final hasPink = colors.any((c) => (c >> 16 & 255) > (c & 255) + 25);
      expect(hasBlue && hasPink, isFalse, reason: '蓝字不能与粉色说话人合成同一段');
    }
    final layout = buildTranslationOverlayLayout(
      result: cached.copyWith(
        translatedGroups: List.filled(groups.length, '译文验收'),
      ),
      sourceSize: const Size(1280, 1697),
      visibleImage: const Rect.fromLTWH(0, 0, 1280, 1697),
      textDirection: TextDirection.ltr,
      backgroundColor: const Color(0xffffffff),
      backgroundOpacity: 0,
      strategy: PageProcessingStrategy.color,
    );
    final rendered = layout.texts.where((p) => p.rect.left > 900 && p.rect.top > 150 && p.rect.top < 500);
    expect(rendered, isNotEmpty);
    for (final text in rendered) {
      expect(text.color.b, greaterThan(text.color.r + 80 / 255));
      expect(text.outlineColor, const Color(0xffffffff));
    }
  });

  test('第五页拒绝旧版及黑白修复缓存，并撤下不匹配的内存背景', () async {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    final temp = await Directory.systemTemp.createTemp('jhentai-page5-cache-');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('$_root/source.png');
    final output = await File(
      '$_root/observed.png',
    ).copy(path.join(temp.path, 'legacy.png'));
    final sourceHash = sha256.convert(source.readAsBytesSync()).toString();
    final requestKey = 'online:6ffa45fa984c001df61bc8951c011f7b';
    final requestHash = sha256.convert(utf8.encode(requestKey)).toString();
    final indexDir = Directory('${temp.path}/by-request')..createSync();
    final index = File('${indexDir.path}/$requestHash.json');
    final metadata = <String, dynamic>{
      'schemaVersion': 4,
      'policyVersion': 9,
      'requestKey': requestKey,
      'artifactKey': 'legacy',
      'sourceHash': sourceHash,
    };
    File('${temp.path}/legacy.json').writeAsStringSync(
      jsonEncode({
        'sourceHash': sourceHash,
        'outputPath': output.path,
        'outputHash': sha256.convert(output.readAsBytesSync()).toString(),
      }),
    );
    index.writeAsStringSync(jsonEncode(metadata));
    final service = ImageInpaintingService()..setCacheDirectoryForTesting(temp);
    expect(
      await service.hydrateCachedRepair(
        requestKey: requestKey,
        sourcePath: source.path,
        strategyId: PageProcessingStrategy.color.id,
      ),
      isNull,
      reason: '第五页实际旧索引没有策略字段，不能恢复',
    );

    metadata['strategyId'] = PageProcessingStrategy.monochrome.id;
    index.writeAsStringSync(jsonEncode(metadata));
    final monochrome = await service.hydrateCachedRepair(
      requestKey: requestKey,
      sourcePath: source.path,
      strategyId: PageProcessingStrategy.monochrome.id,
    );
    expect(monochrome?.status, InpaintingStatus.success);
    expect(
      await service.hydrateCachedRepair(
        requestKey: requestKey,
        sourcePath: source.path,
        strategyId: PageProcessingStrategy.color.id,
      ),
      isNull,
    );
    service.setDisplayMode(
      ImageProcessingDisplayMode.repairedBackgroundEmbeddedText,
    );
    expect(service.displayPathFor(requestKey), isNull);
    expect(service.effectiveOverlayBackgroundOpacity(requestKey, 0), 1);
  });

  test('第五页彩漫策略完整覆盖英文彩字和白边，旧黑白策略确实漏擦', () {
    final source =
        img.decodeImage(File('$_root/source.png').readAsBytesSync())!;
    final snapshot = jsonDecode(
      File('$_root/pipeline_snapshot.json').readAsStringSync(),
    );
    final polygons = (snapshot['erasePolygons'] as List).map(
      (m) =>
          (m['points'] as List)
              .map(
                (p) => math.Point<double>(
                  (p['x'] as num).toDouble(),
                  (p['y'] as num).toDouble(),
                ),
              )
              .toList(),
    );
    final coarse = rasterizeInpaintingMask(
      source.width,
      source.height,
      polygons,
    );
    final color = PageProcessingStrategy.color.refineEraseMask(source, coarse);
    final mono = PageProcessingStrategy.monochrome.refineEraseMask(
      source,
      coarse,
    );
    int white = 0,
        blue = 0,
        missedWhite = 0,
        missedBlue = 0,
        oldMissedWhite = 0;
    for (final r in annotation['evaluationRects'] as List) {
      for (int y = r[1]; y < r[1] + r[3]; y++) {
        for (int x = r[0]; x < r[0] + r[2]; x++) {
          final p = source.getPixel(x, y), i = y * source.width + x;
          if (p.r > 245 && p.g > 245 && p.b > 245) {
            white++;
            if (color[i] != 0) missedWhite++;
            if (mono[i] != 0) oldMissedWhite++;
          }
          if (p.b > 110 && p.r < 80 && p.g < 130) {
            blue++;
            if (color[i] != 0) missedBlue++;
          }
        }
      }
    }
    expect(white, greaterThan(6000));
    expect(blue, greaterThan(6000));
    expect(oldMissedWhite / white, greaterThan(.3));
    expect(missedWhite, 0);
    expect(missedBlue, 0);
  });
}
