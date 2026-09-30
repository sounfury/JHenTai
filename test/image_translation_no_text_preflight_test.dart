import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/bubble_segmentation_engine_adapter.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/engine/engine_registry.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';

class _Ocr implements OcrEngine {
  int calls = 0;
  List<RecognizedTextBlock> blocks = [];
  String? errorCode;
  Completer<void>? started;
  Completer<void>? gate;

  @override
  final descriptor = const EngineDescriptor(
    id: 'onnx-ocr',
    kind: EngineKind.ocr,
    displayName: 'Test OCR',
    platforms: {EnginePlatform.windows},
  );

  @override
  bool get isReady => true;

  @override
  EngineTask<OcrResult> recognize(OcrEngineRequest request) {
    calls++;
    return EngineTask.start(
      operation: (_) async {
        started?.complete();
        await gate?.future;
        if (errorCode != null) {
          throw EngineException(
            code: errorCode!,
            message: 'test error',
            engineId: descriptor.id,
          );
        }
        expect(request.maxDimension, 2200);
        return OcrResult(
          blocks: blocks,
          imageWidth: request.image?.width,
          imageHeight: request.image?.height,
        );
      },
    );
  }
}

class _Registry extends EngineRegistry {
  _Registry(this.ocr, {required super.bubbleDetectionEngine});

  final OcrEngine ocr;

  @override
  OcrEngine get selectedOcr => ocr;
}

class _TestLog extends LogService {
  @override
  Future<void> info(Object msg, [bool withStack = false]) async {}

  @override
  Future<void> warning(
    Object msg, [
    Object? error,
    bool withStack = false,
  ]) async {}

  @override
  Future<void> trace(Object msg, [bool withStack = false]) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File source;
  late ImageTranslationService service;
  late ImageTranslationRequest request;
  late _Ocr ocr;
  late int bubbleCalls;
  late ImageOcrEngine previousOcr;
  late ImageTranslationEngine previousTranslator;
  late bool previousMerge;
  late bool previousBubbles;
  late LogService previousLog;

  setUp(() async {
    previousLog = log;
    log = _TestLog();
    previousOcr = imageTranslationSetting.ocrEngine.value;
    previousTranslator = imageTranslationSetting.translatorEngine.value;
    previousMerge = imageTranslationSetting.autoMergeText.value;
    previousBubbles = imageTranslationSetting.enableBubbleDetection.value;
    imageTranslationSetting.ocrEngine.value = ImageOcrEngine.onnx;
    imageTranslationSetting.translatorEngine.value =
        ImageTranslationEngine.localGguf;
    imageTranslationSetting.autoMergeText.value = true;
    imageTranslationSetting.enableBubbleDetection.value = true;
    directory = await Directory.systemTemp.createTemp('jh-no-text-preflight');
    source = File('${directory.path}/page.png');
    await source.writeAsBytes(
      image.encodePng(image.Image(width: 48, height: 64)),
    );
    request = ImageTranslationRequest(cacheKey: 'page', imagePath: source.path);
    ocr = _Ocr();
    bubbleCalls = 0;
    service = ImageTranslationService(
      engineRegistry: _Registry(
        ocr,
        bubbleDetectionEngine: BubbleSegmentationEngineAdapter(
          ready: () => true,
          runner: (_, __, ___) async {
            bubbleCalls++;
            return const DetectionResult(regions: []);
          },
        ),
      ),
    );
    service.setTranslationCacheDirectoryForTesting(directory);
  });

  tearDown(() async {
    log = previousLog;
    imageTranslationSetting.ocrEngine.value = previousOcr;
    imageTranslationSetting.translatorEngine.value = previousTranslator;
    imageTranslationSetting.autoMergeText.value = previousMerge;
    imageTranslationSetting.enableBubbleDetection.value = previousBubbles;
    await directory.delete(recursive: true);
  });

  test(
    'batch skips bubbles and translation and counts the empty page',
    () async {
      final generation = service.beginBatch(1);
      await service.translate(request);
      service.recordBatchResult(request.cacheKey, generation: generation);
      expect(ocr.calls, 1);
      expect(bubbleCalls, 0);
      expect(
        service.resultFor(request.cacheKey).status,
        ImageTranslationStatus.noText,
      );
      expect(service.batchCompleted, 1);
      expect(service.batchSkipped, 1);
      expect(service.batchFailed, 0);
      service.endBatch(generation);
    },
  );

  test(
    'no-text cache survives restart and source changes invalidate it',
    () async {
      await service.translate(request, preprocessNoText: true);
      final restarted = ImageTranslationService();
      restarted.setTranslationCacheDirectoryForTesting(directory);
      expect(
        await restarted.cachedStatusForRequest(request),
        ImageTranslationStatus.noText,
      );
      expect(await restarted.hasCachedTranslation(request), isFalse);
      expect(await restarted.hydrateResult(request), isTrue);
      expect(restarted.resultFor(request.cacheKey).fromCache, isTrue);
      expect(restarted.resultFor(request.cacheKey).imageWidth, 48);
      expect(restarted.resultFor(request.cacheKey).imageHeight, 64);
      await service.translate(request, preprocessNoText: true);
      expect(ocr.calls, 1);
      await source.writeAsBytes(
        image.encodePng(image.Image(width: 49, height: 64)),
      );
      expect(await restarted.cachedStatusForRequest(request), isNull);
      await service.translate(request, preprocessNoText: true);
      expect(ocr.calls, 2);
    },
  );

  test('OCR configuration change invalidates no-text cache', () async {
    await service.translate(request, preprocessNoText: true);
    imageTranslationSetting.ocrEngine.value = ImageOcrEngine.mangaOcr;
    expect(await service.cachedStatusForRequest(request), isNull);
  });

  test('force retries recognition after a no-text result', () async {
    await service.translate(request, preprocessNoText: true);
    await service.translate(request, force: true, preprocessNoText: true);
    expect(ocr.calls, 2);
  });

  test(
    'text page reuses preflight OCR and continues to bubble analysis',
    () async {
      ocr.blocks = const [
        RecognizedTextBlock(
          text: 'これは小さな文字です',
          confidence: 0.99,
          left: 8,
          top: 8,
          width: 24,
          height: 32,
        ),
      ];
      final recognized = await service.recognizeImage(
        request,
        preprocessNoText: true,
      );
      expect(recognized, isNotNull);
      expect(recognized!.sourceText, 'これは小さな文字です');
      expect(ocr.calls, 1);
      expect(bubbleCalls, 1);
      expect(await service.cachedStatusForRequest(request), isNull);
    },
  );

  test('OCR error never becomes a cached no-text decision', () async {
    ocr.errorCode = 'not_ready';
    await service.translate(request, preprocessNoText: true);
    expect(
      service.resultFor(request.cacheKey).status,
      ImageTranslationStatus.ocrError,
    );
    expect(await service.cachedStatusForRequest(request), isNull);
    expect(bubbleCalls, 0);
  });

  test('native no_text result is skipped and cached', () async {
    ocr.errorCode = 'no_text';
    await service.translate(request, preprocessNoText: true);
    expect(
      await service.cachedStatusForRequest(request),
      ImageTranslationStatus.noText,
    );
    expect(bubbleCalls, 0);
  });

  test('cancel during preflight never caches an empty page', () async {
    ocr.started = Completer<void>();
    ocr.gate = Completer<void>();
    final generation = service.beginBatch(1);
    final pending = service.translate(request);
    await ocr.started!.future;
    service.cancelBatch();
    ocr.gate!.complete();
    await pending;
    expect(
      service.resultFor(request.cacheKey).status,
      ImageTranslationStatus.canceled,
    );
    expect(await service.cachedStatusForRequest(request), isNull);
    expect(bubbleCalls, 0);
    service.endBatch(generation);
  });
}
