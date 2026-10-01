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

import '../../support/test_logging.dart';

const _root = 'test/acceptance/image_translation/false_text_arm';

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

  test('无字原页的手臂被读成AR，别处CTD区域不能证明它是文字', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    expect(cached.sourceText, 'AR');
    expect(cached.translatedText, '啊');
    expect(cached.ocrArtifactCheckVersion, 1);
    expect(masks, isNotEmpty, reason: '必须覆盖CTD有输出但与OCR框无关的缺陷');
    expect(
      filterPolygonMasksToTranslatedBlocks(
        masks: masks,
        translatedBlocks: cached.blocks,
      ),
      isEmpty,
    );
    final checked = reconcileOversizedOcrPage(cached, detection);
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

  test('旧复核版本的错误缓存自动纠正并落盘，重启不重复调用模型', () async {
    final directory = await Directory.systemTemp.createTemp('arm-acceptance-');
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
      cacheKey: 'false-text-arm',
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
