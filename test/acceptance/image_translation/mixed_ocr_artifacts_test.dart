import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/ctd_engine_adapter.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/engine/engine_registry.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';
import 'package:jhentai/src/utils/ocr_artifact_filter.dart';
import 'package:jhentai/src/utils/rgba_raster.dart';

import '../../support/test_logging.dart';

const _root = 'test/acceptance/image_translation/mixed_ocr_artifacts';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpTestLogging();
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  final recorded = jsonDecode(
    File('$_root/recorded_pages.json').readAsStringSync(),
  );
  final cached = ImageTranslationResult.fromCacheJson(recorded[0]['result']);
  final raw = jsonDecode(
    File('$_root/detector_snapshot.json').readAsStringSync(),
  );
  final masks =
      (raw['pages'][0]['polygonMasks'] as List)
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
          .toList();
  final detection = DetectionResult(regions: const [], polygonMasks: masks);
  final source =
      RgbaRaster.decode(File('$_root/source.png').readAsBytesSync())!;

  void verify(ImageTranslationResult checked) {
    expect(checked.status, ImageTranslationStatus.success);
    expect(checked.ocrArtifactCheckVersion, currentOcrArtifactCheckVersion);
    expect(
      checked.blocks.map((b) => b.text),
      cached.blocks.where((b) => b.text != 'MM').map((b) => b.text),
    );
    expect(checked.sourceText.split('\n'), isNot(contains('MM')));
    expect(checked.translatedText, isNot(contains('嗯嗯')));
    expect(checked.translatedGroups, isNot(contains('嗯嗯')));
    final oldGroups = translationTextGroups(
      cached.blocks,
      containers: cached.containers,
      merge: cached.mergeTextBlocks,
    );
    final oldTranslations = {
      for (int i = 0; i < oldGroups.length; i++)
        oldGroups[i].textOf(cached.blocks): cached.translatedGroups[i],
    };
    final groups = translationTextGroups(
      checked.blocks,
      containers: checked.containers,
      merge: checked.mergeTextBlocks,
    );
    for (int i = 0; i < groups.length; i++) {
      expect(
        checked.translatedGroups[i],
        oldTranslations[groups[i].textOf(checked.blocks)],
      );
    }
    for (int i = 0; i < checked.containers.length; i++) {
      expect(
        checked.containers[i].blockIndices.map(
          (index) => checked.blocks[index].text,
        ),
        cached.containers[i].blockIndices.map(
          (index) => cached.blocks[index].text,
        ),
      );
      expect(
        checked.containers[i].layoutRegions.length,
        cached.containers[i].layoutRegions.length,
      );
    }
  }

  test('真实同页14条对白与头发MM：仅剔除误识别，译文与气泡索引保持对应', () {
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    expect(
      cached.blocks.singleWhere((b) => b.text == 'MM').height,
      lessThan(source.height * .12),
      reason: '复现小尺寸片段绕过旧整页检查',
    );
    expect(cached.blocks.length, 15);
    expect(
      needsOversizedOcrPageCheck(
        cached.blocks,
        source.width,
        source.height,
        containers: cached.containers,
      ),
      isTrue,
    );
    verify(reconcileOversizedOcrPage(cached, detection, source: source));
    expect(reconcileOversizedOcrPage(cached, null), same(cached));
  });

  test('旧缓存读入自动纠正，重启后不恢复嗯嗯，也不改变其余对白译文', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mixed-ocr-acceptance-',
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
    const request = ImageTranslationRequest(
      cacheKey: 'mixed-ocr-artifacts',
      imagePath: '$_root/source.png',
    );
    try {
      final service = ImageTranslationService(engineRegistry: registry)
        ..setTranslationCacheDirectoryForTesting(directory);
      await service.writePersistentResultForRequest(request, cached);
      service.publishResult(request.cacheKey, cached);
      expect(service.needsCachedArtifactCheck(request.cacheKey), isTrue);
      expect(await service.hydrateResult(request), isTrue);
      verify(service.resultFor(request.cacheKey));
      final restarted = ImageTranslationService(engineRegistry: registry)
        ..setTranslationCacheDirectoryForTesting(directory);
      expect(await restarted.hydrateResult(request), isTrue);
      verify(restarted.resultFor(request.cacheKey));
      expect(detections, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
