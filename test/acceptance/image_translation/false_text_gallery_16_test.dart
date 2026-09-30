import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/ctd_engine_adapter.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/engine/engine_registry.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/ocr_artifact_filter.dart';

const _root = 'test/acceptance/image_translation/false_text_gallery_16';

class _SilentLog extends LogService {
  @override
  Future<void> info(Object message, [bool withStack = false]) async {}
}

List<PolygonMask> _polygons(Map row) =>
    (row['polygonMasks'] as List? ?? [])
        .map(
          (p) => PolygonMask(
            confidence: (p['confidence'] as num).toDouble(),
            points:
                (p['points'] as List)
                    .map(
                      (point) => EnginePoint(
                        x: (point['x'] as num).toDouble(),
                        y: (point['y'] as num).toDouble(),
                      ),
                    )
                    .toList(),
          ),
        )
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pages =
      jsonDecode(File('$_root/recorded_pages.json').readAsStringSync()) as List;
  final snapshot =
      jsonDecode(
            File('$_root/detector_snapshot.json').readAsStringSync(),
          )['pages']
          as List;

  test('真实16页缓存复核后为8页完成、8页无文字，保留前8页译文', () {
    final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
    for (final entry in (annotation['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        entry.value,
      );
    }
    int beforeSkipped = 0, afterSkipped = 0;
    for (int i = 0; i < pages.length; i++) {
      final cached = ImageTranslationResult.fromCacheJson(pages[i]['result']);
      if (cached.status == ImageTranslationStatus.noText) beforeSkipped++;
      final row = snapshot[i];
      final checked = reconcileOversizedOcrPage(
        cached,
        row['checked'] == true
            ? DetectionResult(regions: const [], polygonMasks: _polygons(row))
            : null,
      );
      expect(
        checked.status.name,
        pages[i]['expectedStatus'],
        reason: '第${i + 1}页',
      );
      if (checked.status == ImageTranslationStatus.noText) afterSkipped++;
      if (i < 8) expect(checked.translatedText, cached.translatedText);
      if (i >= 8 && i < 14) expect(checked.blocks, isEmpty);
    }
    expect(pages.length, 16);
    expect(beforeSkipped, 2);
    expect(afterSkipped, 8);
  });

  test('监控读取旧缓存会纠正并落盘，重启后不再次调用模型或翻译', () async {
    final previousLog = log;
    log = _SilentLog();
    final directory = await Directory.systemTemp.createTemp(
      'gallery16-acceptance-',
    );
    int detections = 0;
    final registry = EngineRegistry(
      detectionEngine: CtdDetectionEngineAdapter(
        runner: (path, _, __) async {
          detections++;
          final i = pages.indexWhere(
            (page) => path.endsWith(page['sourceFile'] as String),
          );
          return CtdDetectionOutput(polygonMasks: _polygons(snapshot[i]));
        },
      ),
    );
    final service = ImageTranslationService(engineRegistry: registry)
      ..setTranslationCacheDirectoryForTesting(directory);
    final requests = <ImageTranslationRequest>[];
    try {
      final generation = service.beginBatch(16);
      for (int i = 0; i < pages.length; i++) {
        final page = pages[i];
        final request = ImageTranslationRequest(
          cacheKey: 'gallery16:${i + 1}',
          imagePath: '$_root/${page['sourceFile']}',
        );
        requests.add(request);
        final cached = ImageTranslationResult.fromCacheJson(page['result']);
        await service.writePersistentResultForRequest(request, cached);
        service.publishResult(request.cacheKey, cached);
        expect(
          (await service.cachedStatusForRequest(request))?.name,
          page['expectedStatus'],
        );
        await service.hydrateResult(request);
        service.recordBatchResult(request.cacheKey, generation: generation);
      }
      expect(service.batchSucceeded, 8);
      expect(service.batchSkipped, 8);
      expect(service.batchFailed, 0);
      service.endBatch(generation);
      final previousDetections = detections;
      final restarted = ImageTranslationService(engineRegistry: registry)
        ..setTranslationCacheDirectoryForTesting(directory);
      for (int i = 0; i < requests.length; i++) {
        expect(
          (await restarted.cachedStatusForRequest(requests[i]))?.name,
          pages[i]['expectedStatus'],
        );
        expect(await restarted.hydrateResult(requests[i]), isTrue);
        if (i >= 8) {
          await restarted.translate(requests[i], preprocessNoText: true);
          expect(
            restarted.resultFor(requests[i].cacheKey).status,
            ImageTranslationStatus.noText,
          );
        }
      }
      expect(detections, previousDetections);
    } finally {
      log = previousLog;
      await directory.delete(recursive: true);
    }
  });

  test('复核模型不可用时不把可疑结果冒充成无文字', () {
    final cached = ImageTranslationResult.fromCacheJson(pages[8]['result']);
    expect(
      needsOversizedOcrPageCheck(
        cached.blocks,
        cached.imageWidth!,
        cached.imageHeight!,
      ),
      isTrue,
    );
    expect(reconcileOversizedOcrPage(cached, null), same(cached));
  });
}
