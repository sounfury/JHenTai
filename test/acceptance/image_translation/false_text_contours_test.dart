import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/ctd_engine_adapter.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/engine/engine_registry.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/utils/ocr_artifact_filter.dart';
import 'package:jhentai/src/utils/rgba_raster.dart';

import '../../support/test_logging.dart';

const _root = 'test/acceptance/image_translation/false_text_contours';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpTestLogging();
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  final recorded = jsonDecode(
    File('$_root/recorded_pages.json').readAsStringSync(),
  );
  final cached = ImageTranslationResult.fromCacheJson(recorded[0]['result']);
  final snapshot = jsonDecode(
    File('$_root/detector_snapshot.json').readAsStringSync(),
  );
  final masks =
      (snapshot['pages'][0]['polygonMasks'] as List)
          .map(
            (mask) => PolygonMask(
              confidence: (mask['confidence'] as num).toDouble(),
              points:
                  (mask['points'] as List)
                      .map(
                        (p) => EnginePoint(
                          x: (p['x'] as num).toDouble(),
                          y: (p['y'] as num).toDouble(),
                        ),
                      )
                      .toList(),
            ),
          )
          .toList();
  final detection = DetectionResult(regions: const [], polygonMasks: masks);
  final source =
      RgbaRaster.decode(File('$_root/source.png').readAsBytesSync())!;

  test('CTD与巨大LET框重叠，但原图没有文字笔画，不允许翻译', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    expect(cached.sourceText, 'LET');
    expect(cached.translatedText, '让');
    expect(cached.ocrArtifactCheckVersion, 2);
    expect(masks, isNotEmpty, reason: '必须覆盖CTD误检区域与OCR框重叠的缺陷');
    expect(
      filterPolygonMasksToTranslatedBlocks(
        masks: masks,
        translatedBlocks: cached.blocks,
      ),
      isNotEmpty,
    );
    final checked = reconcileOversizedOcrPage(
      cached,
      detection,
      source: source,
    );
    expect(checked.status, ImageTranslationStatus.noText);
    expect(checked.translatedText, isEmpty);
    expect(checked.blocks, isEmpty);
    expect(checked.ocrArtifactCheckVersion, currentOcrArtifactCheckVersion);
  });

  test('只有位置支持而缺少原图，或检测不可用时不能冒充无文字', () {
    expect(reconcileOversizedOcrPage(cached, null), same(cached));
    final block = cached.blocks.single;
    final supported = DetectionResult(
      regions: const [],
      polygonMasks: [
        PolygonMask(
          confidence: 1,
          points: [
            EnginePoint(x: block.left + 50, y: block.top + 30),
            EnginePoint(x: block.left + 90, y: block.top + 30),
            EnginePoint(x: block.left + 90, y: block.top + 70),
            EnginePoint(x: block.left + 50, y: block.top + 70),
          ],
        ),
      ],
    );
    final checked = reconcileOversizedOcrPage(cached, supported);
    expect(checked.status, ImageTranslationStatus.success);
    expect(checked.translatedText, cached.translatedText);
    expect(checked.ocrArtifactCheckVersion, cached.ocrArtifactCheckVersion);
  });

  test('真实描边对白有实际字形，不能被误判为无文字', () {
    const positiveRoot = 'test/acceptance/image_translation/white_outline_text';
    final positiveSource =
        RgbaRaster.decode(File('$positiveRoot/source.png').readAsBytesSync())!;
    final raw = jsonDecode(
      File('$positiveRoot/pipeline_snapshot.json').readAsStringSync(),
    );
    final mask =
        (raw['erasePolygons'] as List)
            .map(
              (m) => PolygonMask(
                confidence: (m['confidence'] as num).toDouble(),
                points:
                    (m['points'] as List)
                        .map(
                          (p) => EnginePoint(
                            x: (p['x'] as num).toDouble(),
                            y: (p['y'] as num).toDouble(),
                          ),
                        )
                        .toList(),
              ),
            )
            .first;
    // Replay the same short OCR fragment over a real text region. The source
    // glyph evidence, rather than a blacklist of LET/AR, decides this case.
    final positive = cached.copyWith(
      blocks: [
        RecognizedTextBlock(
          text: 'LET',
          confidence: .53,
          left: mask.left,
          top: mask.top,
          width: mask.right - mask.left,
          height: mask.bottom - mask.top,
        ),
      ],
      imageWidth: positiveSource.width,
      imageHeight: positiveSource.height,
    );
    expect(
      needsOversizedOcrPageCheck(
        positive.blocks,
        positiveSource.width,
        positiveSource.height,
      ),
      isTrue,
    );
    final checked = reconcileOversizedOcrPage(
      positive,
      DetectionResult(regions: const [], polygonMasks: [mask]),
      source: positiveSource,
    );
    expect(checked.status, ImageTranslationStatus.success);
    expect(checked.translatedText, positive.translatedText);
    expect(checked.ocrArtifactCheckVersion, currentOcrArtifactCheckVersion);
  });

  test('版本2错误缓存自动纠正为无文字，重启及翻译调用不恢复错误覆盖层', () async {
    final directory = await Directory.systemTemp.createTemp(
      'contours-acceptance-',
    );
    int detections = 0;
    final registry = EngineRegistry(
      detectionEngine: CtdDetectionEngineAdapter(
        runner: (_, __, ___) async {
          detections++;
          return CtdDetectionOutput(polygonMasks: masks);
        },
      ),
    );
    final service = ImageTranslationService(engineRegistry: registry)
      ..setTranslationCacheDirectoryForTesting(directory);
    const request = ImageTranslationRequest(
      cacheKey: 'false-text-contours',
      imagePath: '$_root/source.png',
    );
    try {
      await service.writePersistentResultForRequest(request, cached);
      service.publishResult(request.cacheKey, cached);
      expect(service.needsCachedArtifactCheck(request.cacheKey), isTrue);
      expect(
        await service.cachedStatusForRequest(request),
        ImageTranslationStatus.noText,
      );
      expect(await service.hydrateResult(request), isTrue);
      expect(service.resultFor(request.cacheKey).blocks, isEmpty);
      expect(service.resultFor(request.cacheKey).translatedText, isEmpty);
      expect(detections, 1);
      final restarted = ImageTranslationService(engineRegistry: registry)
        ..setTranslationCacheDirectoryForTesting(directory);
      expect(
        await restarted.cachedStatusForRequest(request),
        ImageTranslationStatus.noText,
      );
      expect(await restarted.hydrateResult(request), isTrue);
      expect(restarted.needsCachedArtifactCheck(request.cacheKey), isFalse);
      await restarted.translate(request, preprocessNoText: true);
      expect(
        restarted.resultFor(request.cacheKey).status,
        ImageTranslationStatus.noText,
      );
      expect(restarted.resultFor(request.cacheKey).translatedText, isEmpty);
      expect(detections, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
