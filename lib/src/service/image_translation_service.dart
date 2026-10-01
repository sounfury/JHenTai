import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'image_translation/onomatopoeia_filter.dart';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';

import '../model/image_translation.dart';
import '../setting/image_translation_setting.dart';
import 'inference_service.dart';
import 'jh_service.dart';
import 'log.dart';
import 'path_service.dart';
import '../utils/image_text_grouping.dart';
import '../utils/image_translation_colors.dart';
import '../utils/image_translation_renderer.dart';
import '../utils/ocr_artifact_filter.dart';
export '../utils/image_translation_typography.dart';
export '../utils/image_translation_renderer.dart';
import '../utils/image_text_container_detection.dart';
import '../utils/connected_bubble_layout.dart';
import '../utils/bubble_mask_layout.dart';
import '../utils/bubble_detection_refinement.dart';
import '../utils/sound_effect_style.dart';
import '../utils/ocr_layout_protocol.dart';
import '../utils/rgba_raster.dart';
import 'engine/engine.dart';
import 'engine/translation_protocol.dart';
import 'image_translation/translation_configuration.dart';

ImageTranslationService imageTranslationService = ImageTranslationService();

/// Result of the recognition step. `imageWidth`/`imageHeight` are the upright
/// (orientation-applied) pixel dimensions for engines that provide them (Apple
/// Live Text), so the overlay scales blocks in the same space the image is
/// actually displayed in. Tesseract/Paddle return null and the caller falls
/// back to its header-based dimension probe.
typedef _RecognizeResult =
    ({List<RecognizedTextBlock> blocks, int? imageWidth, int? imageHeight});

/// The recognized source of one page, produced by [ImageTranslationService.recognizeImage]
/// and consumed by [ImageTranslationService.translateRecognizedText]. Carrying it
/// between the two stages lets the batch pipeline overlap the next page's OCR
/// with the current page's translation.
class RecognizedImage {
  const RecognizedImage({
    required this.cacheKey,
    required this.persistentKey,
    required this.sourceHash,
    required this.sourcePath,
    required this.sourceText,
    required this.blocks,
    this.containers = const <RecognizedTextContainer>[],
    this.mergeTextBlocks = true,
    required this.imageWidth,
    required this.imageHeight,
    this.ocrArtifactCheckVersion = 0,
  });

  final String cacheKey;
  final String persistentKey;
  final String sourceHash;
  final String sourcePath;
  final String sourceText;
  final List<RecognizedTextBlock> blocks;
  final List<RecognizedTextContainer> containers;
  final bool mergeTextBlocks;
  final int imageWidth;
  final int imageHeight;
  final int ocrArtifactCheckVersion;
}

class ImageTranslationService extends GetxController
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  ImageTranslationService({EngineRegistry? engineRegistry})
    : engineRegistry = engineRegistry ?? EngineRegistry();

  static const String taskIdPrefix = 'imageTranslation';
  static const String batchProgressId = 'imageTranslationBatchProgress';
  static const String readerStateId = 'imageTranslationReaderState';

  final Map<String, ImageTranslationResult> _results = {};

  /// Batch translation progress shown by the read-page top banner.
  bool isBatchTranslating = false;
  int batchTotal = 0;
  int batchCompleted = 0;
  int batchSucceeded = 0;
  int batchFailed = 0;
  int batchCanceled = 0;
  int batchSkipped = 0;
  final List<String> batchFailedKeys = <String>[];
  ImageTranslationStage currentStage = ImageTranslationStage.idle;
  bool _cancelRequested = false;

  /// Monotonic batch generation. Bumped every time a batch starts; a stale
  /// batch still unwinding after a cancel can only write shared progress state
  /// when its captured generation is still current, so it can never clobber a
  /// newer batch's banner/progress.
  int _batchGeneration = 0;

  // Cancellation stays observable even after a new batch resets the latch.
  int _cancelGeneration = 0;
  final Set<String> _batchRecordedKeys = <String>{};
  final Map<EngineTask<dynamic>, String?> _activeEngineTasks = {};
  final Set<EngineTask<DetectionResult>> _activeBubbleTasks = {};
  final Set<String> _activeCacheKeys = {};
  final Map<String, Future<bool>> _hydrateTasks = <String, Future<bool>>{};
  final Map<String, Future<ImageTranslationResult>> _artifactCacheChecks = {};
  Directory? _translationCacheDirectoryOverride;
  final EngineRegistry engineRegistry;

  void _logSoundEffectDecision(String message) {
    unawaited(log.info(message).catchError((Object _) {}));
  }

  int beginBatch(int total) {
    _batchGeneration++;
    _cancelRequested = false;
    isBatchTranslating = true;
    batchTotal = total;
    batchCompleted = 0;
    batchSucceeded = 0;
    batchFailed = 0;
    batchCanceled = 0;
    batchSkipped = 0;
    batchFailedKeys.clear();
    _batchRecordedKeys.clear();
    currentStage = ImageTranslationStage.idle;
    update([batchProgressId, readerStateId]);
    return _batchGeneration;
  }

  void endBatch(int generation) {
    // A cancelled batch still unwinding after a newer batch started must not
    // reset the newer batch's shared progress state.
    if (generation != _batchGeneration) {
      return;
    }
    isBatchTranslating = false;
    currentStage = ImageTranslationStage.done;
    _cancelRequested = false;
    update([batchProgressId, readerStateId]);
  }

  void cancelBatch() {
    _cancelGeneration++;
    _cancelRequested = true;
    for (final EngineTask<DetectionResult> task
        in _activeBubbleTasks.toList()) {
      task.cancel('image translation cancelled');
    }
    for (final String activeCacheKey in _activeCacheKeys.toList()) {
      _set(
        activeCacheKey,
        resultFor(activeCacheKey).copyWith(
          status: ImageTranslationStatus.canceled,
          errorMessage: 'CANCELED',
        ),
      );
    }
    for (final EngineTask<dynamic> task in _activeEngineTasks.keys.toList()) {
      task.cancel('image translation cancelled');
    }
    update([batchProgressId, readerStateId]);
  }

  bool get isCancelRequested => _cancelRequested;

  /// Whether [generation] is the currently running batch. Batch loops guard
  /// their shared progress writes with this so an unwinding stale batch cannot
  /// clobber a newer one.
  bool isCurrentBatch(int generation) => generation == _batchGeneration;

  /// Clears the one-shot cancel latch before a single-page (non-batch)
  /// translation. cancelBatch() arms _cancelRequested and only the batch
  /// lifecycle (beginBatch/endBatch) clears it; single-page translations have
  /// no batch lifecycle of their own, so without this a single cancel (the
  /// status-chip X, or leaving the read page) would permanently disable every
  /// later context-menu translate.
  void resetCancelFlag() {
    _cancelRequested = false;
  }

  void queue(String cacheKey) {
    final ImageTranslationResult current = resultFor(cacheKey);
    if (!current.isTerminal ||
        current.status == ImageTranslationStatus.canceled) {
      _set(cacheKey, current.copyWith(status: ImageTranslationStatus.queued));
    }
  }

  void markDownloading(String cacheKey) {
    _set(
      cacheKey,
      resultFor(cacheKey).copyWith(status: ImageTranslationStatus.downloading),
    );
    _setStage(ImageTranslationStage.downloading);
  }

  void markDownloadError(String cacheKey, String errorMessage) {
    _set(
      cacheKey,
      resultFor(cacheKey).copyWith(
        status: ImageTranslationStatus.downloadError,
        errorMessage: errorMessage,
      ),
    );
  }

  void markOcrError(String cacheKey, String errorMessage) {
    _set(
      cacheKey,
      resultFor(cacheKey).copyWith(
        status: ImageTranslationStatus.ocrError,
        errorMessage: errorMessage,
      ),
    );
  }

  void markNoText(String cacheKey, {int? imageWidth, int? imageHeight}) {
    _set(
      cacheKey,
      resultFor(cacheKey).copyWith(
        status: ImageTranslationStatus.noText,
        errorMessage: 'NO_TEXT',
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      ),
    );
  }

  void markCanceled(String cacheKey, [String errorMessage = 'CANCELED']) {
    _set(
      cacheKey,
      resultFor(cacheKey).copyWith(
        status: ImageTranslationStatus.canceled,
        errorMessage: errorMessage,
      ),
    );
  }

  /// Records a page only after its OCR/translation future has unwound. This
  /// prevents an exception that is logged by a batch caller from looking like
  /// a successful completion.
  void recordBatchResult(String cacheKey, {int? generation}) {
    if (!isBatchTranslating ||
        (generation != null && !isCurrentBatch(generation)) ||
        !_batchRecordedKeys.add(cacheKey)) {
      return;
    }
    final ImageTranslationResult result = resultFor(cacheKey);
    batchCompleted++;
    if (result.status == ImageTranslationStatus.success) {
      batchSucceeded++;
    } else if (result.status == ImageTranslationStatus.canceled) {
      batchCanceled++;
    } else if (result.status == ImageTranslationStatus.noText) {
      batchSkipped++;
    } else if (result.isFailure) {
      batchFailed++;
      if (!batchFailedKeys.contains(cacheKey)) batchFailedKeys.add(cacheKey);
    } else if (result.status == ImageTranslationStatus.idle ||
        result.status == ImageTranslationStatus.queued ||
        result.status == ImageTranslationStatus.downloading ||
        result.status == ImageTranslationStatus.recognizing ||
        result.status == ImageTranslationStatus.translating) {
      batchFailed++;
      if (!batchFailedKeys.contains(cacheKey)) batchFailedKeys.add(cacheKey);
    }
    update([batchProgressId, readerStateId]);
  }

  /// Removes an in-memory result. Used when the source image is reloaded so a
  /// stale overlay is not drawn over the new image.
  void removeResult(String cacheKey) => _removeResult(cacheKey);

  /// Releases only the decoded/paintable in-memory result. Persistent result
  /// files are deliberately untouched so a later viewport entry, a reopened
  /// gallery, or an app restart can hydrate the overlay again.
  void releaseInMemoryResult(String cacheKey) {
    final ImageTranslationResult? current = _results[cacheKey];
    if (current != null && current.isTerminal) {
      _removeResult(cacheKey);
    }
  }

  void _setStage(ImageTranslationStage stage) {
    currentStage = stage;
    update([batchProgressId, readerStateId]);
  }

  String taskId(String cacheKey) => '$taskIdPrefix::$cacheKey';

  Directory get _translationCacheDirectory =>
      _translationCacheDirectoryOverride ??
      Directory(join(pathService.jhOcrModelDir.path, 'cache'));

  ImageTranslationResult resultFor(String cacheKey) =>
      _results[cacheKey] ?? const ImageTranslationResult.idle();

  bool needsCachedArtifactCheck(String cacheKey) {
    final result = resultFor(cacheKey);
    return result.status == ImageTranslationStatus.success &&
        result.ocrArtifactCheckVersion < currentOcrArtifactCheckVersion &&
        needsOversizedOcrPageCheck(
          result.blocks,
          result.imageWidth ?? 0,
          result.imageHeight ?? 0,
          containers: result.containers,
        );
  }

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies
        ..add(imageTranslationSetting)
        ..add(inferenceService);

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  @visibleForTesting
  Future<String?> persistentKeyForRequest(
    ImageTranslationRequest request,
  ) async {
    final String? imagePath = request.imagePath;
    if (imagePath == null) {
      return null;
    }
    try {
      final List<int> sourceBytes = await File(imagePath).readAsBytes();
      final String imageHash = await compute(_sha256Hex, sourceBytes);
      return _persistentCacheKey(request, imageHash);
    } on FileSystemException {
      return null;
    }
  }

  @visibleForTesting
  void setTranslationCacheDirectoryForTesting(Directory? directory) {
    _translationCacheDirectoryOverride = directory;
  }

  @visibleForTesting
  Future<void> writePersistentResultForRequest(
    ImageTranslationRequest request,
    ImageTranslationResult result,
  ) async {
    final String? key = await persistentKeyForRequest(request);
    if (key == null) {
      throw ArgumentError.value(
        request.imagePath,
        'request.imagePath',
        'Image path is required to persist a translation result.',
      );
    }
    await _writePersistentResult(key, result);
  }

  @visibleForTesting
  Future<void> writePersistentResultForKeyForTesting(
    String key,
    ImageTranslationResult result,
  ) => _writePersistentResult(key, result);

  @visibleForTesting
  void setResultForTesting(String cacheKey, ImageTranslationResult result) {
    _set(cacheKey, result);
  }

  /// Publishes a result produced by an independent pipeline while keeping the
  /// existing overlay/GetX notification path. Context translation uses this
  /// instead of reaching into the service's result map.
  void publishResult(String cacheKey, ImageTranslationResult result) {
    _set(cacheKey, result);
  }

  /// Context batches use a cache key that is different from the ordinary
  /// single-page key. These narrow methods keep the existing gzip cache and
  /// hydrate behavior as the single persistence implementation.
  Future<ImageTranslationResult?> readPersistentResultForKey(String key) =>
      _readPersistentResult(key);

  Future<void> writePersistentResultForKey(
    String key,
    ImageTranslationResult result,
  ) => _writePersistentResult(key, result);

  Future<bool> hydratePersistentResult({
    required String displayCacheKey,
    required String persistentKey,
  }) async {
    final ImageTranslationResult? result = await _readPersistentResult(
      persistentKey,
    );
    if (result == null) return false;
    _set(displayCacheKey, result.copyWith(fromCache: true));
    return true;
  }

  /// Allows an independent batch orchestrator to participate in the existing
  /// cancel button. The concrete engine remains owned by its adapter.
  void attachExternalBatchTask(
    EngineTask<dynamic> task, {
    String? activeCacheKey,
  }) {
    _activeEngineTasks[task] = activeCacheKey;
    if (activeCacheKey != null) {
      _activeCacheKeys.add(activeCacheKey);
    }
  }

  void detachExternalBatchTask(EngineTask<dynamic> task) {
    final String? cacheKey = _activeEngineTasks.remove(task);
    if (cacheKey != null) {
      _activeCacheKeys.remove(cacheKey);
    }
  }

  void setBatchStage(ImageTranslationStage stage) => _setStage(stage);

  Future<bool> hydrateResult(ImageTranslationRequest request) {
    final ImageTranslationResult current = resultFor(request.cacheKey);
    if ((current.status == ImageTranslationStatus.success &&
            !needsCachedArtifactCheck(request.cacheKey)) ||
        current.status == ImageTranslationStatus.recognizing ||
        current.status == ImageTranslationStatus.translating) {
      return Future.value(current.status == ImageTranslationStatus.success);
    }
    final Future<bool>? existing = _hydrateTasks[request.cacheKey];
    if (existing != null) {
      return existing;
    }
    final Future<bool> task = _hydrateResultInternal(request);
    _hydrateTasks[request.cacheKey] = task;
    return task.whenComplete(() {
      if (identical(_hydrateTasks[request.cacheKey], task)) {
        _hydrateTasks.remove(request.cacheKey);
      }
    });
  }

  /// Checks the current translation cache without decoding or publishing a
  /// result. The monitor can count cached pages before a batch starts.
  Future<bool> hasCachedTranslation(ImageTranslationRequest request) async {
    return await cachedStatusForRequest(request) ==
        ImageTranslationStatus.success;
  }

  /// Includes persistent no-text decisions so pre-translation can count them
  /// as skipped pages. The source hash and OCR configuration invalidate them.
  Future<ImageTranslationStatus?> cachedStatusForRequest(
    ImageTranslationRequest request,
  ) async {
    if (resultFor(request.cacheKey).status == ImageTranslationStatus.success &&
        !needsCachedArtifactCheck(request.cacheKey)) {
      return ImageTranslationStatus.success;
    }
    final String? imagePath = request.imagePath;
    if (imagePath == null) {
      return null;
    }
    try {
      final Uint8List bytes = await File(imagePath).readAsBytes();
      final String hash = await compute(_sha256Hex, bytes);
      final ImageTranslationResult? cached = await _readPersistentResultForHash(
        request,
        hash,
      );
      return cached?.status;
    } on FileSystemException {
      return null;
    }
  }

  /// OCR stage of a translation: reads the image, runs recognition and returns
  /// the recognized source for the translation stage. Returns null when the
  /// page should be skipped (already translated / image unavailable / no text).
  /// Split from [translate] so the batch pipeline can overlap the next page's
  /// OCR with the current page's translation.
  Future<RecognizedImage?> recognizeImage(
    ImageTranslationRequest request, {
    bool force = false,
    bool preprocessNoText = false,
  }) async {
    final String? imagePath = request.imagePath;
    if (imagePath == null) {
      if (resultFor(request.cacheKey).status !=
          ImageTranslationStatus.downloadError) {
        markDownloadError(request.cacheKey, 'IMAGE_SOURCE_UNAVAILABLE');
      }
      return null;
    }
    final ImageTranslationResult existing = resultFor(request.cacheKey);
    if (!force &&
        (existing.status == ImageTranslationStatus.recognizing ||
            existing.status == ImageTranslationStatus.translating ||
            (existing.status == ImageTranslationStatus.success &&
                !needsCachedArtifactCheck(request.cacheKey)))) {
      return null;
    }

    _set(
      request.cacheKey,
      const ImageTranslationResult(status: ImageTranslationStatus.recognizing),
    );
    _setStage(ImageTranslationStage.recognizing);
    _activeCacheKeys.add(request.cacheKey);

    late final Uint8List sourceBytes;
    try {
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      // Read the image bytes exactly once: they feed the persistent-cache
      // hash and the image-dimension fallback probe.
      sourceBytes = await File(imagePath).readAsBytes();

      // Hashing the full image on the UI isolate drops frames on every page
      // (SHA-256 over a few MB is tens of ms); run it off-isolate. The single
      // hash names the persistent cache entry as well.
      final String imageHash = await compute(_sha256Hex, sourceBytes);
      final String persistentKey = _persistentCacheKey(request, imageHash);
      final ImageTranslationResult? cached = await _readPersistentResultForHash(
        request,
        imageHash,
      );
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      if (!force && cached != null) {
        _logSoundEffectDecision(
          '[拟声词过滤] page=${request.cacheKey} '
          'cache_status=${cached.status.name}; '
          'OCR and sound-effect classification skipped',
        );
        final restored = await _restoreCachedResult(
          persistentKey,
          sourceBytes,
          cached,
        );
        if (_cancelRequested) {
          markCanceled(request.cacheKey);
        } else {
          _set(request.cacheKey, restored);
        }
        return null;
      }

      // Decode the page once for every pixel stage below. A decode failure
      // leaves each stage to read the file itself, as before.
      final RgbaRaster? page = await _decodePage(sourceBytes);

      // Batch preflight uses the selected OCR at its normal resolution, never
      // page order or a thumbnail similarity heuristic. Reuse recognition on
      // text pages; empty pages never start bubble/layout/inpainting work.
      final _RecognizeResult? preflight =
          preprocessNoText || isBatchTranslating
              ? await _recognize(imagePath, page)
              : null;
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      if (preflight != null &&
          preflight.blocks.every((block) => block.text.trim().isEmpty)) {
        await _persistNoText(
          request.cacheKey,
          persistentKey,
          imageWidth: preflight.imageWidth ?? page?.width,
          imageHeight: preflight.imageHeight ?? page?.height,
        );
        return null;
      }

      // Single-page bubble detection overlaps OCR; batch preflight has already
      // recognized the complete page. The resulting boxes join OCR lines below. The
      // detector never throws, leaving a safe full-page OCR fallback when the
      // optional model is unavailable.
      final bool useBubbleDetection =
          imageTranslationSetting.autoMergeText.value &&
          imageTranslationSetting.enableBubbleDetection.value;
      final Future<DetectionResult?> pendingBubbles =
          useBubbleDetection
              ? _detectBubbleRegions(imagePath, page)
              : Future<DetectionResult?>.value();
      final _RecognizeResult recognized =
          preflight ?? await _recognize(imagePath, page);
      DetectionResult? bubbleDetection = await pendingBubbles;
      List<RecognizedTextBlock> blocks = recognized.blocks;
      final bool mergeTextBlocks = imageTranslationSetting.autoMergeText.value;
      // Resolve the source dimensions before accepting detector rectangles so
      // a page-sized false positive can never become a layout container.
      final int imageWidth;
      final int imageHeight;
      if (recognized.imageWidth != null && recognized.imageHeight != null) {
        imageWidth = recognized.imageWidth!;
        imageHeight = recognized.imageHeight!;
      } else {
        final (int width, int height) = await _probeImageDimensions(
          sourceBytes,
        );
        imageWidth = width;
        imageHeight = height;
      }
      blocks = await _detectColors(
        sourceBytes,
        blocks,
        imageWidth,
        imageHeight,
        page: page,
      );
      blocks = sortRecognizedTextBlocks(mergeOverlappingOcrArtifacts(blocks));
      final checked = await _validateOversizedOcrPage(
        ImageTranslationResult(
          status: ImageTranslationStatus.success,
          blocks: blocks,
          containers: containersFromBubbleDetection(
            blocks,
            bubbleDetection,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
          ),
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ),
        imagePath,
        page,
      );
      if (checked.status == ImageTranslationStatus.noText) {
        await _persistNoText(
          request.cacheKey,
          persistentKey,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          ocrArtifactCheckVersion: checked.ocrArtifactCheckVersion,
        );
        return null;
      }
      blocks = checked.blocks;
      if (bubbleDetection != null && page != null && !_cancelRequested) {
        bubbleDetection = await refineBubbleDetection(
          source: page,
          initial: bubbleDetection,
          blocks: blocks,
          detect: (crop) => _detectBubbleRegions(imagePath, crop),
          isCanceled: () => _cancelRequested,
        );
      }
      // Preserve only sound effects outside detected bubbles. Exclamations and
      // sound words inside bubbles must reach the translator and renderer.
      final List<RecognizedTextBlock> retainedBlocks = [];
      final List<String> soundEffectDecisions = [];
      final styledEffects =
          page == null || bubbleDetection == null
              ? <int>{}
              : styleMatchedSoundEffects(page, blocks, bubbleDetection.regions);
      final outlinedEffects =
          page == null
              ? <int>{}
              : outlinedArtworkSoundEffects(
                page,
                blocks,
                bubbleDetection?.regions,
              );
      for (int index = 0; index < blocks.length; index++) {
        final RecognizedTextBlock block = blocks[index];
        final bool? insideBubble =
            bubbleDetection == null
                ? null
                : isBlockInsideAnyRegion(block, bubbleDetection.regions);
        final bool preserve = shouldPreserveSoundEffect(
          block.text,
          insideBubble: insideBubble,
          confidence: block.confidence,
          width: block.width,
          height: block.height,
          matchesSoundEffectStyle: styledEffects.contains(index),
          matchesSoundEffectOutline: outlinedEffects.contains(index),
        );
        if (!preserve) {
          retainedBlocks.add(block);
        }
        soundEffectDecisions.add(
          '[$index] ${preserve ? 'preserve' : 'translate'} '
          'bubble=${insideBubble == null
              ? 'unknown'
              : insideBubble
              ? 'inside'
              : 'outside'} '
          'sfx=${isOnomatopoeia(block.text, insideBubble: insideBubble)} '
          'style=${styledEffects.contains(index)} outline=${outlinedEffects.contains(index)} '
          'confidence=${block.confidence.toStringAsFixed(2)} '
          'box=(${block.left.toStringAsFixed(0)},${block.top.toStringAsFixed(0)},'
          '${block.width.toStringAsFixed(0)},${block.height.toStringAsFixed(0)}) '
          'text=${jsonEncode(block.text)}',
        );
      }
      _logSoundEffectDecision(
        '[拟声词过滤] page=${request.cacheKey} '
        'bubbleDetection=${bubbleDetection == null ? 'unavailable' : '${bubbleDetection.regions.length} regions'} '
        'blocks=${blocks.length} preserved=${blocks.length - retainedBlocks.length}\n'
        '${soundEffectDecisions.join('\n')}',
      );
      blocks = retainedBlocks;
      List<RecognizedTextContainer> containers =
          useBubbleDetection
              ? await _containersFromBubbleDetection(
                blocks,
                bubbleDetection,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
              )
              : const <RecognizedTextContainer>[];
      if (useBubbleDetection && containers.isEmpty) {
        containers = await _detectTextContainers(
          sourceBytes,
          blocks,
          page: page,
        );
      }
      containers = await _refineBubbleLayouts(
        sourceBytes,
        containers,
        page: page,
      );
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      final String sourceText = blocks
          .map((block) => block.text)
          .where((text) => text.isNotEmpty)
          .join('\n');
      if (sourceText.isEmpty) {
        await _persistNoText(
          request.cacheKey,
          persistentKey,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );
        return null;
      }

      final bool usesLocalTranslation =
          imageTranslationSetting.translatorEngine.value ==
          ImageTranslationEngine.localGguf;
      if (!imageTranslationSetting.usesAppleOnDeviceTranslation &&
          !usesLocalTranslation &&
          !imageTranslationSetting.isTranslatorConfigured) {
        _set(
          request.cacheKey,
          ImageTranslationResult(
            status: ImageTranslationStatus.failed,
            sourceText: sourceText,
            blocks: blocks,
            containers: containers,
            mergeTextBlocks: mergeTextBlocks,
            errorMessage: 'TRANSLATOR_NOT_CONFIGURED',
            needsConfiguration: true,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
          ),
        );
        return null;
      }

      _set(
        request.cacheKey,
        ImageTranslationResult(
          status: ImageTranslationStatus.translating,
          sourceText: sourceText,
          blocks: blocks,
          containers: containers,
          mergeTextBlocks: mergeTextBlocks,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ),
      );
      _setStage(ImageTranslationStage.translating);
      return RecognizedImage(
        cacheKey: request.cacheKey,
        persistentKey: persistentKey,
        sourceHash: imageHash,
        sourcePath: imagePath,
        sourceText: sourceText,
        blocks: blocks,
        containers: containers,
        mergeTextBlocks: mergeTextBlocks,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        ocrArtifactCheckVersion: checked.ocrArtifactCheckVersion,
      );
    } on ImageTranslationException catch (e, stack) {
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      log.warning('Image translation failed: ${e.code}');
      if (e.code == 'OCR_CANCELLED') {
        markCanceled(request.cacheKey, e.code);
      } else if (e.code == 'NO_TEXT') {
        markNoText(request.cacheKey);
      } else if (e.code.startsWith('OCR_')) {
        markOcrError(request.cacheKey, e.code);
      } else {
        _set(
          request.cacheKey,
          resultFor(request.cacheKey).copyWith(
            status: ImageTranslationStatus.failed,
            errorMessage: e.code,
          ),
        );
      }
      log.trace(stack);
    } on ProcessException catch (e, stack) {
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      log.warning('Image OCR executable is unavailable: ${e.executable}');
      markOcrError(request.cacheKey, 'OCR_UNAVAILABLE');
      log.trace(stack);
    } on TimeoutException catch (e, stack) {
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      markOcrError(request.cacheKey, 'OCR_TIMEOUT');
      log.warning('Image OCR timed out: $e');
      log.trace(stack);
    } on FileSystemException catch (e, stack) {
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      markDownloadError(request.cacheKey, 'IMAGE_SOURCE_UNAVAILABLE');
      log.warning('Image source is unavailable: $e');
      log.trace(stack);
    } catch (e, stack) {
      if (_cancelRequested) {
        markCanceled(request.cacheKey);
        return null;
      }
      log.error('Image translation failed', e, stack);
      markOcrError(request.cacheKey, 'OCR_FAILED');
    } finally {
      // The source buffer is method-scoped and is never stored in the result or
      // read-page state, so it becomes collectible when this attempt unwinds.
      _activeCacheKeys.remove(request.cacheKey);
    }
    return null;
  }

  /// Translation stage: translates the recognized source text and finalizes
  /// the result. Called after [recognizeImage] so the batch pipeline can run
  /// the next page's OCR while this translation is in flight.
  Future<void> translateRecognizedText(
    ImageTranslationRequest request,
    RecognizedImage recognized,
  ) async {
    final int cancelGeneration = _cancelGeneration;
    bool wasCanceled() =>
        _cancelRequested || cancelGeneration != _cancelGeneration;
    _activeCacheKeys.add(request.cacheKey);
    final TranslationEngine engine = engineRegistry.selectedTranslation;
    EngineTask<TranslationResult>? task;
    final Stopwatch clock = Stopwatch()..start();
    int readyMs = 0;
    int engineMs = 0;
    try {
      await engine.ensureReady();
      if (wasCanceled()) {
        markCanceled(request.cacheKey);
        return;
      }
      readyMs = clock.elapsedMilliseconds;
      final EngineCapabilityDecision capability =
          engineRegistry.evaluateSelected();
      if (!capability.supported) {
        throw ImageTranslationException(
          capability.reason.contains('not ready')
              ? 'ENGINE_NOT_READY'
              : 'UNSUPPORTED_COMBINATION',
        );
      }
      final EngineTask<TranslationResult> activeTask = engine.translate(
        TranslationEngineRequest(
          blocks: recognized.blocks,
          imagePath: recognized.sourcePath,
          targetLanguage:
              engine.descriptor.id == 'apple-translation'
                  ? _appleTargetLanguage()
                  : imageTranslationSetting.targetLanguage.value,
          sourceLanguage: _appleSourceLanguage(),
          mergeTextBlocks: recognized.mergeTextBlocks,
          containers: recognized.containers,
          configuration: <String, dynamic>{
            'provider': imageTranslationSetting.translatorProvider.value.name,
            'model':
                imageTranslationSetting.translatorEngine.value ==
                        ImageTranslationEngine.localGguf
                    ? imageTranslationSetting.localModelId.value
                    : imageTranslationSetting.translatorModel.value,
            'thinking': imageTranslationSetting.enableThinking.value,
          },
          promptVersion: imageTranslationPromptVersion,
        ),
      );
      task = activeTask;
      _activeEngineTasks[activeTask] = request.cacheKey;
      _setStage(ImageTranslationStage.translating);
      final TranslationResult translation = await activeTask.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          activeTask.cancel('translation timeout');
          throw const ImageTranslationException('TRANSLATION_TIMEOUT');
        },
      );
      engineMs = clock.elapsedMilliseconds - readyMs;
      final String translatedText = translation.translatedText;
      if (wasCanceled()) {
        markCanceled(request.cacheKey);
        return;
      }
      _set(
        request.cacheKey,
        ImageTranslationResult(
          status: ImageTranslationStatus.success,
          sourceText: recognized.sourceText,
          translatedText: translatedText,
          translatedGroups: translation.groupTranslations,
          blocks: recognized.blocks,
          containers: recognized.containers,
          mergeTextBlocks: recognized.mergeTextBlocks,
          imageWidth: recognized.imageWidth,
          imageHeight: recognized.imageHeight,
          ocrArtifactCheckVersion: recognized.ocrArtifactCheckVersion,
        ),
      );
      try {
        await _writePersistentResult(
          recognized.persistentKey,
          resultFor(request.cacheKey),
        );
      } on FileSystemException catch (e, stack) {
        // The visible result is already complete. A cache write failure must
        // be reported in logs without converting a successful translation
        // into a false translation failure.
        log.warning('Failed to persist image translation: $e');
        log.trace(stack);
      }
      if (wasCanceled()) {
        markCanceled(request.cacheKey);
        return;
      }
      _setStage(ImageTranslationStage.done);
      log.info(
        '[翻译计时] page ${request.cacheKey} engine=${engine.descriptor.id} '
        '${recognized.blocks.length} blocks / ${recognized.sourceText.length}chars: '
        'ensureReady ${readyMs}ms, engine ${engineMs}ms, '
        'finish ${clock.elapsedMilliseconds - readyMs - engineMs}ms, '
        'total ${clock.elapsedMilliseconds}ms',
      );
    } on ImageTranslationException catch (e, stack) {
      if (wasCanceled()) {
        markCanceled(request.cacheKey);
        return;
      }
      log.warning('Image translation failed: ${e.code}');
      _set(
        request.cacheKey,
        resultFor(
          request.cacheKey,
        ).copyWith(status: ImageTranslationStatus.failed, errorMessage: e.code),
      );
      log.trace(stack);
    } on EngineTaskCancelledException {
      markCanceled(request.cacheKey);
    } on EngineException catch (e, stack) {
      if (wasCanceled()) {
        markCanceled(request.cacheKey);
        return;
      }
      final String code = switch (e.code) {
        'not_ready' => 'ENGINE_NOT_READY',
        'unsupported_platform' => 'UNSUPPORTED_COMBINATION',
        'invalid_response' => 'TRANSLATION_INVALID_RESPONSE',
        'request_failed' => 'TRANSLATION_REQUEST_FAILED',
        'timeout' => 'TRANSLATION_TIMEOUT',
        'translation_unavailable' => 'TRANSLATION_UNAVAILABLE',
        'translation_not_installed' => 'TRANSLATION_NOT_INSTALLED',
        _ => 'TRANSLATION_FAILED',
      };
      _set(
        request.cacheKey,
        resultFor(
          request.cacheKey,
        ).copyWith(status: ImageTranslationStatus.failed, errorMessage: code),
      );
      log.warning('Image translation engine failed: $e');
      log.trace(stack);
    } catch (e, stack) {
      if (wasCanceled()) {
        markCanceled(request.cacheKey);
        return;
      }
      log.error('Image translation failed', e, stack);
      _set(
        request.cacheKey,
        resultFor(request.cacheKey).copyWith(
          status: ImageTranslationStatus.failed,
          errorMessage: 'TRANSLATION_FAILED',
        ),
      );
    } finally {
      if (task != null) {
        _activeEngineTasks.remove(task);
      }
      _activeCacheKeys.remove(request.cacheKey);
    }
  }

  /// Shared single-page OCR and translation path for direct and pre-translation.
  /// Context batches use the two stages separately to assemble their prompt.
  Future<void> translate(
    ImageTranslationRequest request, {
    bool force = false,
    bool preprocessNoText = false,
  }) async {
    // Single-page retry/translate: clear any stale cancel latch so a previous
    // cancelled translate (which never went through the batch lifecycle) does
    // not silently disable this one.
    if (!isBatchTranslating) {
      _cancelRequested = false;
    }
    final RecognizedImage? recognized = await recognizeImage(
      request,
      force: force,
      preprocessNoText: preprocessNoText,
    );
    if (recognized == null) {
      return;
    }
    await translateRecognizedText(request, recognized);
  }

  void _removeResult(String cacheKey) {
    _results.remove(cacheKey);
    update([taskId(cacheKey), readerStateId]);
  }

  String _persistentCacheKey(
    ImageTranslationRequest request,
    String imageHash, {
    int promptVersion = imageTranslationPromptVersion,
  }) {
    final configuration = captureImageTranslationConfiguration();
    return EngineCacheKey(
      sourceHash: imageHash,
      ocrModel: configuration.ocrModel,
      ocrConfiguration: configuration.ocr,
      translationModel: configuration.modelVersion,
      translationConfiguration: configuration.translation,
      promptVersion: promptVersion,
      pipelineVersion: 'image-translation-v3',
    ).value;
  }

  Future<ImageTranslationResult?> _readPersistentResultForHash(
    ImageTranslationRequest request,
    String imageHash,
  ) async {
    // The cache key includes the current inside/outside sound-effect policy.
    final key = _persistentCacheKey(request, imageHash);
    final cached = await _readPersistentResult(key);
    if (cached == null ||
        request.imagePath == null ||
        cached.ocrArtifactCheckVersion >= currentOcrArtifactCheckVersion ||
        !needsOversizedOcrPageCheck(
          cached.blocks,
          cached.imageWidth ?? 0,
          cached.imageHeight ?? 0,
          containers: cached.containers,
        )) {
      return cached;
    }
    final pending =
        _artifactCacheChecks[key] ??= () async {
          final checked = await _validateOversizedOcrPage(
            cached,
            request.imagePath!,
            null,
          );
          if (!identical(checked, cached)) {
            await _writePersistentResult(key, checked);
            _set(request.cacheKey, checked.copyWith(fromCache: true));
          }
          return checked;
        }();
    try {
      return await pending;
    } finally {
      if (identical(_artifactCacheChecks[key], pending))
        _artifactCacheChecks.remove(key);
    }
  }

  Future<bool> _hydrateResultInternal(ImageTranslationRequest request) async {
    final String? imagePath = request.imagePath;
    if (imagePath == null) {
      return false;
    }
    final Uint8List sourceBytes;
    try {
      sourceBytes = await File(imagePath).readAsBytes();
    } on FileSystemException {
      return false;
    }
    final String imageHash = await compute(_sha256Hex, sourceBytes);
    final ImageTranslationResult? cached = await _readPersistentResultForHash(
      request,
      imageHash,
    );
    if (cached == null) {
      return false;
    }
    _set(
      request.cacheKey,
      await _restoreCachedResult(
        _persistentCacheKey(request, imageHash),
        sourceBytes,
        cached,
      ),
    );
    return true;
  }

  /// Upgrade old geometry/colors once and persist even an empty layout result.
  /// Viewport eviction must not turn every return to a page into image analysis.
  Future<ImageTranslationResult> _restoreCachedResult(
    String persistentKey,
    Uint8List sourceBytes,
    ImageTranslationResult cached,
  ) async {
    if (cached.status == ImageTranslationStatus.noText) {
      return cached.copyWith(fromCache: true);
    }
    final containers = await _refineBubbleLayouts(
      sourceBytes,
      cached.containers,
    );
    final blocks = await _detectColors(
      sourceBytes,
      cached.blocks,
      cached.imageWidth ?? 0,
      cached.imageHeight ?? 0,
    );
    final restored = cached.copyWith(
      fromCache: true,
      containers: containers,
      blocks: blocks,
    );
    if (!identical(containers, cached.containers) ||
        !identical(blocks, cached.blocks)) {
      try {
        await _writePersistentResult(persistentKey, restored);
      } catch (error) {
        log.warning('Failed to persist upgraded translation layout: $error');
      }
    }
    return restored;
  }

  /// Probes the encoded image dimensions from its header. Only used as a
  /// fallback when an OCR engine reports no dimensions (both on-device engines
  /// always do), so the per-page hot path stays free of full-buffer copies.
  Future<(int, int)> _probeImageDimensions(List<int> sourceBytes) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      Uint8List.fromList(sourceBytes),
    );
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
      buffer,
    );
    final (int, int) dims = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return dims;
  }

  Future<ImageTranslationResult?> _readPersistentResult(String key) async {
    final File cacheFile = File(
      join(_translationCacheDirectory.path, '$key.json'),
    );
    if (!await cacheFile.exists()) return null;
    try {
      final dynamic content = jsonDecode(
        utf8.decode(
          await compute(_decompressJson, await cacheFile.readAsBytes()),
        ),
      );
      if (content is! Map) return null;
      final ImageTranslationResult result =
          ImageTranslationResult.fromCacheJson(
            Map<String, dynamic>.from(content),
          );
      if (result.status == ImageTranslationStatus.noText) {
        return result;
      }
      final String cleaned = stripTranslationReasoning(result.translatedText);
      return cleaned.isEmpty ? null : result.copyWith(translatedText: cleaned);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePersistentResult(
    String key,
    ImageTranslationResult result,
  ) async {
    if (result.status != ImageTranslationStatus.success &&
        result.status != ImageTranslationStatus.noText) {
      return;
    }
    await _translationCacheDirectory.create(recursive: true);
    final File cacheFile = File(
      join(_translationCacheDirectory.path, '$key.json'),
    );
    // gzip-compress off the UI isolate so batch translation never blocks it.
    await cacheFile.writeAsBytes(
      await compute(_compressJson, jsonEncode(result.toJson())),
      flush: true,
    );
  }

  Future<void> _persistNoText(
    String cacheKey,
    String persistentKey, {
    int? imageWidth,
    int? imageHeight,
    int ocrArtifactCheckVersion = 0,
  }) async {
    if (_cancelRequested) {
      markCanceled(cacheKey);
      return;
    }
    // A fresh result clears any overlay left by a previous forced translation.
    final result = ImageTranslationResult(
      status: ImageTranslationStatus.noText,
      errorMessage: 'NO_TEXT',
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      ocrArtifactCheckVersion: ocrArtifactCheckVersion,
    );
    _set(cacheKey, result);
    try {
      await _writePersistentResult(persistentKey, result);
    } catch (error) {
      log.warning('Failed to persist no-text decision: $error');
    }
    if (_cancelRequested) {
      markCanceled(cacheKey);
    }
  }

  /// Compresses persistent-translation JSON with gzip on a background isolate
  /// via [compute] (see [_writePersistentResult]).
  static Uint8List _compressJson(String content) =>
      Uint8List.fromList(gzip.encode(utf8.encode(content)));

  /// Decompresses persistent-translation JSON; falls back to the raw bytes for
  /// backward compatibility with cache files written before gzip compression.
  static Uint8List _decompressJson(Uint8List data) {
    try {
      return Uint8List.fromList(gzip.decode(data));
    } on FormatException {
      return data;
    }
  }

  /// SHA-256 hex of the source image bytes. Runs off the UI isolate via
  /// [compute] so hashing a multi-MB page never blocks frame production.
  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static RgbaRaster? _decodeRaster(Uint8List bytes) => RgbaRaster.decode(bytes);

  Future<RgbaRaster?> _decodePage(Uint8List sourceBytes) async {
    try {
      return await compute(_decodeRaster, sourceBytes);
    } catch (error) {
      log.warning('Shared page decode skipped: $error');
      return null;
    }
  }

  /// Isolate payload carrying the decoded [page], or the encoded [bytes] for
  /// the worker to decode when no shared decode is available.
  static Map<String, dynamic> _pagePayload(Uint8List bytes, RgbaRaster? page) =>
      page == null
          ? <String, dynamic>{'bytes': bytes}
          : <String, dynamic>{'image': page};

  Future<_RecognizeResult> _recognize(
    String imagePath,
    RgbaRaster? page,
  ) async {
    final OcrEngine engine = engineRegistry.selectedOcr;
    final EngineTask<OcrResult> task = engine.recognize(
      OcrEngineRequest(
        imagePath: imagePath,
        image: page,
        configuration: <String, dynamic>{
          'language': imageTranslationSetting.appleLiveTextLanguage.value,
        },
      ),
    );
    _activeEngineTasks[task] = null;
    try {
      _setStage(ImageTranslationStage.recognizing);
      final OcrResult result = await task.future.timeout(
        const Duration(minutes: 2),
      );
      return (
        blocks: result.blocks,
        imageWidth: result.imageWidth,
        imageHeight: result.imageHeight,
      );
    } on EngineTaskCancelledException {
      throw const ImageTranslationException('OCR_CANCELLED');
    } on EngineException catch (error) {
      if (error.code == 'not_ready') {
        throw const ImageTranslationException('OCR_NOT_CONFIGURED');
      }
      if (error.code == 'no_text') {
        return (
          blocks: const <RecognizedTextBlock>[],
          imageWidth: page?.width,
          imageHeight: page?.height,
        );
      }
      throw ImageTranslationException(
        error.code == 'unsupported_platform'
            ? 'OCR_UNSUPPORTED_PLATFORM'
            : 'OCR_FAILED',
      );
    } on TimeoutException {
      task.cancel('image translation OCR timeout');
      throw const ImageTranslationException('OCR_TIMEOUT');
    } finally {
      _activeEngineTasks.remove(task);
    }
  }

  Future<List<RecognizedTextBlock>> _detectColors(
    Uint8List bytes,
    List<RecognizedTextBlock> blocks,
    int width,
    int height, {
    RgbaRaster? page,
  }) async {
    if (width <= 0 ||
        height <= 0 ||
        blocks.isEmpty ||
        blocks.every(
          (block) =>
              block.backgroundColor != null &&
              block.sourceGlyphWidth != null &&
              block.sourceGlyphHeight != null,
        )) {
      return blocks;
    }
    try {
      return await compute(detectTranslationColors, <String, dynamic>{
        ..._pagePayload(bytes, page),
        'blocks': blocks,
        'width': width,
        'height': height,
      });
    } catch (error) {
      log.warning('Translation color detection skipped: $error');
      return blocks;
    }
  }

  Future<List<RecognizedTextContainer>> _refineBubbleLayouts(
    Uint8List sourceBytes,
    List<RecognizedTextContainer> containers, {
    RgbaRaster? page,
  }) async {
    if (containers.isEmpty || containers.every((c) => c.hasAnalyzedLayout)) {
      return containers;
    }
    try {
      final refined =
          await compute(refineBubbleLayoutsFromBytes, <String, dynamic>{
            ..._pagePayload(sourceBytes, page),
            'containers':
                containers.map((container) => container.toJson()).toList(),
          });
      return refined.map(RecognizedTextContainer.fromJson).toList();
    } catch (error) {
      log.warning('Bubble interior layout skipped: $error');
      return containers;
    }
  }

  Future<List<RecognizedTextContainer>> _detectTextContainers(
    Uint8List sourceBytes,
    List<RecognizedTextBlock> blocks, {
    RgbaRaster? page,
  }) async {
    if (blocks.length < 2) {
      return const <RecognizedTextContainer>[];
    }
    try {
      final List<Map<String, dynamic>> raw =
          await compute(detectTextContainersFromBytes, <String, dynamic>{
            ..._pagePayload(sourceBytes, page),
            'blocks':
                blocks
                    .map((RecognizedTextBlock block) => block.toJson())
                    .toList(),
          });
      return raw
          .map(
            (Map<String, dynamic> json) =>
                RecognizedTextContainer.fromJson(json),
          )
          .toList(growable: false);
    } catch (error, stack) {
      log.warning('Text-container detection skipped: $error');
      log.trace(stack);
      return const <RecognizedTextContainer>[];
    }
  }

  Future<ImageTranslationResult> _validateOversizedOcrPage(
    ImageTranslationResult result,
    String imagePath,
    RgbaRaster? page,
  ) async {
    if (result.ocrArtifactCheckVersion >= currentOcrArtifactCheckVersion ||
        !needsOversizedOcrPageCheck(
          result.blocks,
          result.imageWidth ?? 0,
          result.imageHeight ?? 0,
          containers: result.containers,
        ))
      return result;
    final detector = engineRegistry.findDetection('ctd-detection');
    if (detector == null || !detector.isReady) return result;
    final task = detector.detect(
      EngineImageRequest(imagePath: imagePath, image: page),
    );
    _activeBubbleTasks.add(task);
    try {
      final detection = await task.future.timeout(const Duration(minutes: 2));
      final source =
          page ?? await _decodePage(await File(imagePath).readAsBytes());
      final checked = await compute(reconcileOversizedOcrPageWithPixels, (
        result,
        detection,
        source,
      ));
      final retained =
          checked.blocks
              .map((b) => (b.text, b.left, b.top, b.width, b.height))
              .toSet();
      final removed = result.blocks.where(
        (b) => !retained.contains((b.text, b.left, b.top, b.width, b.height)),
      );
      _logSoundEffectDecision(
        '[OCR 画面误识别复核] image=$imagePath '
        'blocks=${result.blocks.length} ctd=${detection.polygonMasks.length} '
        'status=${checked.status.name} retained=${checked.blocks.length} '
        'removed=${removed.map((b) => b.text).join(" | ")}',
      );
      return checked;
    } catch (error) {
      task.cancel('OCR artifact verification failed or timed out');
      _logSoundEffectDecision('[OCR 画面误识别复核] unavailable: $error');
      return result;
    } finally {
      _activeBubbleTasks.remove(task);
    }
  }

  Future<DetectionResult?> _detectBubbleRegions(
    String imagePath,
    RgbaRaster? page,
  ) async {
    if (_cancelRequested) {
      return null;
    }
    final DetectionEngine? detector = engineRegistry.findDetection(
      'manga109-bubble-segmentation',
    );
    if (detector == null || !detector.isReady) {
      return null;
    }
    final EngineTask<DetectionResult> task = detector.detect(
      EngineImageRequest(imagePath: imagePath, image: page),
    );
    _activeBubbleTasks.add(task);
    try {
      return await task.future.timeout(const Duration(minutes: 2));
    } catch (error, stack) {
      task.cancel('bubble detection failed or timed out');
      log.warning('Manga109 bubble detection skipped: $error');
      log.trace(stack);
      return null;
    } finally {
      _activeBubbleTasks.remove(task);
    }
  }

  Future<List<RecognizedTextContainer>> _containersFromBubbleDetection(
    List<RecognizedTextBlock> blocks,
    DetectionResult? detection, {
    required int imageWidth,
    required int imageHeight,
  }) => compute(_buildBubbleContainers, (
    blocks,
    detection,
    imageWidth,
    imageHeight,
  ));

  Future<File> exportOverlay(ImageTranslationRequest request) async {
    final String? imagePath = request.imagePath;
    if (imagePath == null) {
      throw const ImageTranslationException('IMAGE_SOURCE_UNAVAILABLE');
    }
    final ImageTranslationResult result = resultFor(request.cacheKey);
    if (!result.hasDisplayableTranslation) {
      throw const ImageTranslationException('OVERLAY_NOT_READY');
    }
    final Uint8List source = Uint8List.fromList(
      await File(imagePath).readAsBytes(),
    );
    final ui.Codec codec = await ui.instantiateImageCodec(source);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder)
      ..drawImage(frame.image, Offset.zero, Paint());
    final Size sourceSize = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    final layout = buildTranslationOverlayLayout(
      result: result,
      sourceSize: sourceSize,
      visibleImage: Offset.zero & sourceSize,
      textDirection: TextDirection.ltr,
      backgroundColor: imageTranslationSetting.translationBackgroundColor.value,
      backgroundOpacity:
          imageTranslationSetting.translationBackgroundOpacity.value,
    );
    paintTranslationOverlay(
      canvas,
      layout,
      textDirection: TextDirection.ltr,
      backgroundOpacity:
          imageTranslationSetting.translationBackgroundOpacity.value,
    );
    final ui.Image image = await recorder.endRecording().toImage(
      frame.image.width,
      frame.image.height,
    );
    final int width = frame.image.width;
    final int height = frame.image.height;
    // ui.Image cannot cross isolate boundaries, so rasterization (drawImage +
    // toImage, GPU-backed Canvas work) must stay on the UI isolate. The cheap
    // raw-RGBA copy happens here as well; the expensive PNG compression runs
    // on a background isolate so large exports don't jank the UI.
    final ByteData? raw = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    image.dispose();
    if (raw == null)
      throw const ImageTranslationException('OVERLAY_ENCODE_FAILED');
    final Uint8List pngBytes =
        await compute<(Uint8List rgba, int width, int height), Uint8List>(
          _encodePngOverlay,
          (
            raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
            width,
            height,
          ),
        );
    final Directory directory = Directory(
      join(pathService.jhOcrModelDir.path, 'overlays'),
    );
    await directory.create(recursive: true);
    final File output = File(
      join(
        directory.path,
        'translation_${sha256.convert(source).toString().substring(0, 16)}.png',
      ),
    );
    await output.writeAsBytes(pngBytes, flush: true);
    return output;
  }

  /// PNG-encodes raw RGBA pixels on a background isolate (see [exportOverlay]).
  /// The payload is a (rgba, width, height) record; input and output are plain
  /// byte lists so they can cross the isolate boundary. Implements the minimal
  /// PNG container by hand (signature + IHDR + zlib-compressed IDAT + IEND) to
  /// avoid pulling a codec package into the dependency graph.
  static Uint8List _encodePngOverlay(
    (Uint8List rgba, int width, int height) payload,
  ) {
    final (Uint8List rgba, int width, int height) = payload;
    final BytesBuilder builder = BytesBuilder(copy: false);
    builder.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final ByteData ihdr =
        ByteData(13)
          ..setUint32(0, width)
          ..setUint32(4, height)
          ..setUint8(8, 8) // bit depth
          ..setUint8(9, 6) // color type: truecolor with alpha
          ..setUint8(10, 0) // compression: deflate
          ..setUint8(11, 0) // filter method
          ..setUint8(12, 0); // interlace: none
    _addPngChunk(builder, 'IHDR', ihdr.buffer.asUint8List());

    // Each scanline is prefixed with filter type 0 (None) and the whole
    // payload is zlib-compressed (the format PNG requires for IDAT).
    final int stride = width * 4;
    final Uint8List scanlines = Uint8List(rgba.length + height);
    int src = 0;
    int dst = 0;
    for (int y = 0; y < height; y++) {
      scanlines[dst++] = 0;
      for (int x = 0; x < stride; x++) {
        scanlines[dst++] = rgba[src++];
      }
    }
    _addPngChunk(builder, 'IDAT', zlib.encode(scanlines));
    _addPngChunk(builder, 'IEND', const []);
    return builder.takeBytes();
  }

  static void _addPngChunk(BytesBuilder builder, String type, List<int> data) {
    final Uint8List typeBytes = ascii.encode(type);
    final Uint8List chunk =
        Uint8List(typeBytes.length + data.length)
          ..setRange(0, typeBytes.length, typeBytes)
          ..setRange(typeBytes.length, typeBytes.length + data.length, data);
    final ByteData length = ByteData(4)..setUint32(0, data.length);
    final ByteData crc = ByteData(4)..setUint32(0, _pngCrc32(chunk));
    builder.add(length.buffer.asUint8List());
    builder.add(chunk);
    builder.add(crc.buffer.asUint8List());
  }

  static int _pngCrc32(List<int> data) {
    const int polynomial = 0xEDB88320;
    int crc = 0xFFFFFFFF;
    for (final int byte in data) {
      crc ^= byte;
      for (int bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ polynomial : crc >> 1;
      }
    }
    return crc ^ 0xFFFFFFFF;
  }

  /// On-device translation through Apple's Translation framework. Only used in
  /// Apple Live Text mode with the third-party API toggle off; on systems that
  /// do not support it the native side reports TRANSLATION_UNAVAILABLE.
  ///
  /// The OCR reports one block per visual line, so a speech bubble that spans
  /// several lines arrives as several blocks. Apple's framework has no
  /// cross-request context, so each multi-line utterance is folded into ONE
  /// request (its lines joined by newlines) to be translated as a coherent
  /// whole instead of as isolated fragments. Each group's output is then
  /// re-split back into the group's line count so the read-page overlay keeps
  /// a 1:1 mapping between recognized blocks and translated lines; when the
  /// framework cannot translate a group it returns the source unchanged, which
  /// re-splits back into the original lines.
  Future<List<String>> _translateAppleLines(List<String> lines) async {
    final TranslationEngine engine =
        engineRegistry.findTranslation('apple-translation')!;
    final List<RecognizedTextBlock> blocks = lines
        .map(
          (String line) => RecognizedTextBlock(
            text: line,
            confidence: 1,
            width: 1,
            height: 1,
          ),
        )
        .toList(growable: false);
    try {
      final TranslationResult result =
          await engine
              .translate(
                TranslationEngineRequest(
                  blocks: blocks,
                  targetLanguage: _appleTargetLanguage(),
                  // Gallery title/comment auto-translation always lets the native
                  // side auto-detect the source language. The Apple Live Text
                  // recognition-language picker is an OCR/translation hint for the
                  // image path, not a hard constraint for free-text translation.
                  sourceLanguage: null,
                ),
              )
              .future;
      return result.lines;
    } on EngineException catch (error) {
      throw ImageTranslationException(switch (error.code) {
        'translation_unavailable' => 'TRANSLATION_UNAVAILABLE',
        'translation_not_installed' => 'TRANSLATION_NOT_INSTALLED',
        _ => 'TRANSLATION_FAILED',
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Gallery title / comment auto-translation (Apple on-device only)
  // ---------------------------------------------------------------------------

  static const int maxGalleryTextCacheEntries = 2000;
  static const int _galleryTextConcurrency = 4;

  /// LRU cache (insertion-ordered map) keyed by [String _galleryTextKey].
  final Map<String, String> _galleryTextCache = {};

  /// Keys whose translation failed this session, so a visible burst of titles
  /// does not retry the same unavailable text on every rebuild.
  final Set<String> _galleryTextFailed = {};
  final Map<String, Completer<String>> _galleryTextCompleters = {};
  final List<Future<void> Function()> _galleryTextQueue = [];
  int _galleryTextActive = 0;
  Timer? _galleryTextSaveTimer;

  /// Single in-flight cache load, shared by concurrent callers so the first
  /// visible burst waits for the persisted entries instead of re-translating.
  Future<void>? _galleryTextCacheLoadFuture;

  File get _galleryTextCacheFile =>
      File(join(_translationCacheDirectory.path, 'gallery_text_cache.json'));

  bool get _galleryTextEnabled =>
      (Platform.isIOS || Platform.isMacOS) &&
      imageTranslationSetting.autoTranslateGalleryText.value &&
      imageTranslationSetting.usesAppleOnDeviceTranslation;

  String _galleryTextKey(String text) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'text': text,
                'target': imageTranslationSetting.targetLanguage.value,
                'source': imageTranslationSetting.appleLiveTextLanguage.value,
              }),
            ),
          )
          .toString();

  /// The current translation of [text] if cached, or null when the feature is
  /// off or the text has not been translated yet. Synchronous so widgets can
  /// read the cache directly in build.
  String? galleryTextTranslationFor(String text) {
    if (!_galleryTextEnabled) return null;
    return _galleryTextCache[_galleryTextKey(text)];
  }

  /// Translates a gallery title or a comment text run on-device, returning
  /// [text] unchanged when the feature is disabled, unavailable, or the native
  /// translation fails — callers can always render the returned string. A
  /// modest worker queue keeps bursts of visible titles from spawning parallel
  /// TranslationSessions, and in-flight requests share one Future per key.
  Future<String> translateGalleryText(String text) async {
    if (!_galleryTextEnabled) return text;
    if (text.trim().isEmpty) return text;
    final String key = _galleryTextKey(text);
    // Fast paths so cached, failed, or in-flight texts never occupy a queue
    // slot or hit the native translation again.
    final String? cached = _galleryTextCache[key];
    if (cached != null) return cached;
    if (_galleryTextFailed.contains(key)) return text;
    final Completer<String>? existing = _galleryTextCompleters[key];
    if (existing != null) {
      return existing.future;
    }
    final Completer<String> completer = Completer<String>();
    _galleryTextCompleters[key] = completer;
    _enqueueGalleryTextTranslation(
      () => _runGalleryTextTranslation(key, text, completer),
    );
    return completer.future;
  }

  void _enqueueGalleryTextTranslation(Future<void> Function() task) {
    _galleryTextQueue.add(task);
    _pumpGalleryTextQueue();
  }

  void _pumpGalleryTextQueue() {
    while (_galleryTextActive < _galleryTextConcurrency &&
        _galleryTextQueue.isNotEmpty) {
      final Future<void> Function() task = _galleryTextQueue.removeAt(0);
      _galleryTextActive++;
      task().whenComplete(() {
        _galleryTextActive--;
        _pumpGalleryTextQueue();
      });
    }
  }

  Future<void> _runGalleryTextTranslation(
    String key,
    String text,
    Completer<String> completer,
  ) async {
    String result = text;
    try {
      await _ensureGalleryTextCacheLoaded();
      final String? cached = _galleryTextCache[key];
      if (cached != null) {
        result = cached;
      } else if (!_galleryTextFailed.contains(key)) {
        final String translated =
            (await _translateAppleLines(<String>[text])).first;
        if (translated.trim().isNotEmpty) {
          result = translated;
          _galleryTextCache[key] = translated;
          _evictGalleryTextCache();
          _scheduleGalleryTextCacheSave();
        }
      }
    } on ImageTranslationException {
      _galleryTextFailed.add(key);
    } on Exception {
      _galleryTextFailed.add(key);
    } finally {
      _galleryTextCompleters.remove(key);
      if (!completer.isCompleted) completer.complete(result);
    }
  }

  void _evictGalleryTextCache() {
    while (_galleryTextCache.length > maxGalleryTextCacheEntries) {
      _galleryTextCache.remove(_galleryTextCache.keys.first);
    }
  }

  Future<void> _ensureGalleryTextCacheLoaded() =>
      _galleryTextCacheLoadFuture ??= _loadGalleryTextCache();

  Future<void> _loadGalleryTextCache() async {
    try {
      if (!await _galleryTextCacheFile.exists()) return;
      final Uint8List bytes = await _galleryTextCacheFile.readAsBytes();
      // Decompress off the UI isolate; jsonDecode of the (capped) map is light.
      final Uint8List decompressed = await compute(_decompressJson, bytes);
      final dynamic content = jsonDecode(utf8.decode(decompressed));
      if (content is! Map) return;
      content.forEach((key, value) {
        if (key is String && value is String) {
          _galleryTextCache[key] = value;
        }
      });
      _evictGalleryTextCache();
    } catch (_) {
      // Corrupt cache: ignore and rebuild from scratch.
    }
  }

  void _scheduleGalleryTextCacheSave() {
    _galleryTextSaveTimer?.cancel();
    _galleryTextSaveTimer = Timer(const Duration(seconds: 1), () async {
      try {
        await _galleryTextCacheFile.parent.create(recursive: true);
        // Serialize + gzip off the UI isolate so scroll-heavy bursts don't jank.
        final Uint8List compressed = await compute(
          _compressJson,
          jsonEncode(_galleryTextCache),
        );
        await _galleryTextCacheFile.writeAsBytes(compressed, flush: true);
      } catch (e) {
        log.warning('Failed to save gallery text translation cache: $e');
      }
    });
  }

  /// Maps the [ImageTranslationSetting.targetLanguage] display string to a
  /// BCP-47 language code understood by Apple's Translation framework.
  String _appleTargetLanguage() {
    switch (imageTranslationSetting.targetLanguage.value) {
      case '简体中文':
        return 'zh-Hans';
      case '繁體中文':
        return 'zh-Hant';
      case 'English':
        return 'en';
      case '日本語':
        return 'ja';
      case '한국어':
        return 'ko';
      case 'Português':
        return 'pt';
      case 'Русский':
        return 'ru';
      default:
        return 'zh-Hans';
    }
  }

  /// Optional BCP-47 source language for Apple on-device translation, taken
  /// from the Apple Live Text recognition language. Null lets the native side
  /// auto-detect the source language.
  String? _appleSourceLanguage() {
    final String value = imageTranslationSetting.appleLiveTextLanguage.value;
    if (value.trim().isEmpty || value.trim() == 'auto') {
      return null;
    }
    return value.split(',').first.trim();
  }

  Future<List<String>> fetchModels({
    required ImageTranslationProvider provider,
    required String apiBaseUrl,
    required String apiKey,
  }) async {
    try {
      return await ApiTranslationEngine().fetchModels(
        provider: provider,
        apiBaseUrl: apiBaseUrl,
        apiKey: apiKey,
      );
    } on EngineException catch (error) {
      throw ImageTranslationException(switch (error.code) {
        'configuration_required' => 'API_CONFIGURATION_REQUIRED',
        'invalid_response' => 'MODELS_INVALID_RESPONSE',
        'empty_models' => 'MODELS_EMPTY',
        _ => error.code,
      });
    }
  }

  /// Upper bound on in-memory translation results. Batch-translating a long
  /// gallery used to accumulate one entry per page forever; evicting the
  /// least-recently-used entry keeps memory bounded. The on-disk persistent
  /// cache is untouched, so an evicted page is re-read from disk on demand.
  static const int maxCachedResults = 200;

  void _set(String cacheKey, ImageTranslationResult result) {
    // Remove-then-reinsert so a re-used key counts as most-recently-used
    // (Dart maps keep insertion order).
    _results.remove(cacheKey);
    _results[cacheKey] = result;
    if (_results.length > maxCachedResults) {
      final String evicted = _results.keys.first;
      _results.remove(evicted);
      log.warning(
        'Image translation result cache exceeded $maxCachedResults entries, '
        'evicted oldest: $evicted',
      );
      update([taskId(evicted)]);
    }
    update([taskId(cacheKey), readerStateId]);
  }
}

/// Maps Manga109 speech-bubble regions onto OCR lines. Oversized page-like
/// boxes are ignored. When one detector box contains disconnected OCR clusters
/// (large inter-line / inter-column gaps), each cluster becomes its own
/// container so distant bubbles are not violently merged into one utterance.
bool isBlockInsideAnyRegion(
  RecognizedTextBlock block,
  List<DetectedTextRegion> regions,
) {
  return regions.any((region) => bubbleBlockCoverage(block, region) >= .55);
}

double bubbleBlockCoverage(
  RecognizedTextBlock block,
  DetectedTextRegion region,
) {
  return bubbleRegionCoverage(block, region);
}

List<RecognizedTextContainer> _buildBubbleContainers(
  (List<RecognizedTextBlock>, DetectionResult?, int, int) args,
) => containersFromBubbleDetection(
  args.$1,
  args.$2,
  imageWidth: args.$3,
  imageHeight: args.$4,
);

List<RecognizedTextContainer> containersFromBubbleDetection(
  List<RecognizedTextBlock> blocks,
  DetectionResult? detection, {
  required int imageWidth,
  required int imageHeight,
}) {
  if (blocks.isEmpty || detection == null) {
    return const <RecognizedTextContainer>[];
  }
  final List<RecognizedTextContainer> containers = <RecognizedTextContainer>[];
  final regions =
      detection.regions
          .where(
            (region) =>
                imageWidth > 0 &&
                imageHeight > 0 &&
                region.width < imageWidth * 0.95 &&
                region.height < imageHeight * 0.95 &&
                region.width * region.height < imageWidth * imageHeight * 0.8,
          )
          .toList();
  // Assign once to the best supporting instance. Overlapping detector boxes
  // used to discard a whole later container, including its unique dialogue.
  final assignments = <DetectedTextRegion, List<int>>{};
  for (int i = 0; i < blocks.length; i++) {
    DetectedTextRegion? best;
    double bestScore = 0;
    for (final region in regions) {
      final coverage = bubbleBlockCoverage(blocks[i], region);
      if (coverage < .55) {
        continue;
      }
      final score =
          coverage +
          (region.bubbleInterior == null ? 0 : 1) +
          region.confidence * .01;
      if (score > bestScore) {
        best = region;
        bestScore = score;
      }
    }
    if (best != null) {
      (assignments[best] ??= []).add(i);
    }
  }
  for (final region in regions) {
    final List<int> indices = <int>[];
    indices.addAll(assignments[region] ?? []);
    if (indices.isEmpty) {
      continue;
    }
    if (region.bubbleInterior != null) {
      final layout = layoutBubbleInterior(region.bubbleInterior!);
      if (layout.isNotEmpty) {
        containers.add(
          RecognizedTextContainer(
            blockIndices: indices,
            left: region.left,
            top: region.top,
            width: region.width,
            height: region.height,
            confidence: region.confidence,
            layoutRegions: layout,
            layoutAnalysisVersion: 2,
          ),
        );
        continue;
      }
    }
    final List<RecognizedTextBlock> members = <RecognizedTextBlock>[
      for (final int index in indices) blocks[index],
    ];
    final List<RecognizedTextGroup> clusters =
        mergeTouchingRecognizedTextGroups(groupRecognizedTextBlocks(members));
    if (clusters.length <= 1) {
      containers.add(
        RecognizedTextContainer(
          blockIndices: indices,
          left: region.left,
          top: region.top,
          width: region.width,
          height: region.height,
          confidence: region.confidence,
        ),
      );
      continue;
    }
    for (final RecognizedTextGroup cluster in clusters) {
      final List<int> clusterIndices = <int>[
        for (final int local in cluster.blockIndices) indices[local],
      ];
      containers.add(
        RecognizedTextContainer(
          blockIndices: clusterIndices,
          left: cluster.left,
          top: cluster.top,
          width: math.max(0, cluster.right - cluster.left),
          height: math.max(0, cluster.bottom - cluster.top),
          confidence: region.confidence,
        ),
      );
    }
  }
  return containers;
}

class ImageTranslationException implements Exception {
  final String code;

  const ImageTranslationException(this.code);
}
