import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';

import '../model/image_translation.dart';
import '../utils/image_text_grouping.dart';
import 'engine/engine.dart';
import 'inference_service.dart';
import 'jh_service.dart';
import 'log.dart';
import 'path_service.dart';

enum InpaintingStatus { idle, queued, running, success, canceled, failed }

class InpaintingResult {
  const InpaintingResult({
    required this.status,
    this.outputPath,
    this.translatedImagePath,
    this.errorCode,
    this.fromCache = false,
    this.fallbackToOverlay = false,
    this.sourceHash,
  });

  const InpaintingResult.idle() : this(status: InpaintingStatus.idle);

  final InpaintingStatus status;
  final String? outputPath;
  final String? translatedImagePath;
  final String? errorCode;
  final bool fromCache;
  final bool fallbackToOverlay;
  final String? sourceHash;

  InpaintingResult copyWith({
    InpaintingStatus? status,
    String? outputPath,
    String? translatedImagePath,
    String? errorCode,
    bool? fromCache,
    bool? fallbackToOverlay,
    String? sourceHash,
  }) => InpaintingResult(
    status: status ?? this.status,
    outputPath: outputPath ?? this.outputPath,
    translatedImagePath: translatedImagePath ?? this.translatedImagePath,
    errorCode: errorCode,
    fromCache: fromCache ?? this.fromCache,
    fallbackToOverlay: fallbackToOverlay ?? this.fallbackToOverlay,
    sourceHash: sourceHash ?? this.sourceHash,
  );
}

/// Keep CTD masks that intersect at least one successfully translated OCR
/// block. Masks covering untranslated glyphs must not be inpainted — that
/// erases Japanese/English and leaves blank speech bubbles.
List<PolygonMask> filterPolygonMasksToTranslatedBlocks({
  required List<PolygonMask> masks,
  required List<RecognizedTextBlock> translatedBlocks,
  double padding = 12,
}) {
  if (masks.isEmpty || translatedBlocks.isEmpty) {
    return const <PolygonMask>[];
  }
  return masks
      .where((PolygonMask mask) {
        final double left = mask.left - padding;
        final double top = mask.top - padding;
        final double right = mask.right + padding;
        final double bottom = mask.bottom + padding;
        for (final RecognizedTextBlock block in translatedBlocks) {
          if (block.width <= 0 || block.height <= 0) {
            continue;
          }
          final double blockRight = block.left + block.width;
          final double blockBottom = block.top + block.height;
          if (left < blockRight &&
              right > block.left &&
              top < blockBottom &&
              bottom > block.top) {
            return true;
          }
        }
        return false;
      })
      .toList(growable: false);
}

/// OCR blocks that actually received a non-empty translation. Used to gate
/// CTD/LaMa Large erase so sparse recognition cannot blank the rest of the page.
List<RecognizedTextBlock> translatedBlocksEligibleForErase(
  ImageTranslationResult result,
) {
  if (result.status != ImageTranslationStatus.success || result.blocks.isEmpty) {
    return const <RecognizedTextBlock>[];
  }
  final List<String> lines =
      const LineSplitter().convert(result.translatedText);
  final Set<int> indices = <int>{};
  for (int index = 0; index < result.blocks.length; index++) {
    if (index < lines.length && lines[index].trim().isNotEmpty) {
      indices.add(index);
    }
  }
  // Group-level translations still mark every member line as covered.
  if (result.translatedGroups.isNotEmpty) {
    final List<RecognizedTextGroup> groups = translationTextGroups(
      result.blocks,
      merge: result.mergeTextBlocks,
      containers: result.containers,
    );
    for (int groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      if (groupIndex < result.translatedGroups.length &&
          result.translatedGroups[groupIndex].trim().isNotEmpty) {
        indices.addAll(groups[groupIndex].blockIndices);
      }
    }
  }
  final List<RecognizedTextGroup> renderGroups = translationTextGroups(
    result.blocks,
    merge: result.mergeTextBlocks,
    containers: result.containers,
  );
  for (int i = 0; i < renderGroups.length; i++) {
    final RecognizedTextGroup group = renderGroups[i];
    final String translation =
        i < result.translatedGroups.length &&
            result.translatedGroups[i].trim().isNotEmpty
        ? result.translatedGroups[i]
        : group.blockIndices
              .map((index) => index < lines.length ? lines[index] : '')
              .join('\n');
    if (translationPreservesSource(group.textOf(result.blocks), translation)) {
      indices.removeAll(group.blockIndices);
    }
  }
  return <RecognizedTextBlock>[
    for (final int index in indices)
      if (index >= 0 && index < result.blocks.length) result.blocks[index],
  ];
}

/// Owns only derived inpainting artifacts. It never replaces or writes the
/// source image, so switching display modes cannot destroy the original page.
class ImageInpaintingService extends GetxController
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  ImageInpaintingService({EngineRegistry? registry})
    : engineRegistry = registry ?? EngineRegistry();

  final EngineRegistry engineRegistry;
  final Map<String, InpaintingResult> _results = <String, InpaintingResult>{};
  final Map<String, String> _artifactKeys = <String, String>{};
  final Map<String, EngineTask<String>> _activeTasks =
      <String, EngineTask<String>>{};
  final Map<String, EngineTask<DetectionResult>> _activeDetectionTasks =
      <String, EngineTask<DetectionResult>>{};
  final Map<String, String> _translatedImagePaths = <String, String>{};
  Directory? _cacheDirectoryOverride;

  ImageProcessingDisplayMode displayMode = ImageProcessingDisplayMode.overlay;

  Directory get _cacheDirectory =>
      _cacheDirectoryOverride ??
      Directory(join(pathService.jhOcrModelDir.path, 'inpainting-cache'));

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..add(inferenceService);

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  InpaintingResult resultFor(String requestKey) =>
      _results[requestKey] ?? const InpaintingResult.idle();

  @visibleForTesting
  void setCacheDirectoryForTesting(Directory? directory) {
    _cacheDirectoryOverride = directory;
  }

  void setDisplayMode(ImageProcessingDisplayMode mode) {
    displayMode = mode;
    update();
  }

  /// Whether the current display mode expects a repaired/translated derivative
  /// instead of painting onto the original page glyphs.
  bool get requiresRepairedBackground =>
      displayMode == ImageProcessingDisplayMode.repairedBackgroundEmbeddedText ||
      displayMode == ImageProcessingDisplayMode.translatedImage;

  /// Cold-start / viewport hydrate: restore a previously written repair
  /// artifact for [requestKey] without re-running CTD/LaMa Large when the
  /// request-keyed disk index still matches the source file.
  Future<InpaintingResult?> hydrateCachedRepair({
    required String requestKey,
    required String sourcePath,
  }) async {
    final InpaintingResult current = resultFor(requestKey);
    if (current.status == InpaintingStatus.success &&
        current.outputPath != null &&
        File(current.outputPath!).existsSync()) {
      return current;
    }
    final File source = File(sourcePath);
    if (!await source.exists()) {
      return null;
    }
    final String sourceHash = await _sha256(source);
    final File indexFile = _requestIndexFile(requestKey);
    if (!await indexFile.exists()) {
      return null;
    }
    try {
      final dynamic decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is! Map ||
          decoded['schemaVersion'] != 4 ||
          decoded['sourceHash'] != sourceHash ||
          decoded['artifactKey'] is! String) {
        return null;
      }
      final String artifactKey = decoded['artifactKey'] as String;
      final File output = File(join(_cacheDirectory.path, '$artifactKey.png'));
      final File metadata = File(join(_cacheDirectory.path, '$artifactKey.json'));
      if (!await output.exists() || !await metadata.exists()) {
        return null;
      }
      final dynamic meta = jsonDecode(await metadata.readAsString());
      if (meta is! Map ||
          meta['sourceHash'] != sourceHash ||
          meta['outputPath'] != output.path ||
          meta['outputHash'] != await _sha256(output)) {
        return null;
      }
      _artifactKeys[requestKey] = artifactKey;
      final InpaintingResult restored = InpaintingResult(
        status: InpaintingStatus.success,
        outputPath: output.path,
        fromCache: true,
        sourceHash: sourceHash,
        translatedImagePath:
            decoded['translatedImagePath'] is String
                ? decoded['translatedImagePath'] as String
                : null,
      );
      if (restored.translatedImagePath != null &&
          File(restored.translatedImagePath!).existsSync()) {
        _translatedImagePaths[requestKey] = restored.translatedImagePath!;
      }
      _set(requestKey, restored);
      return restored;
    } catch (_) {
      return null;
    }
  }

  /// While a repaired-background mode is selected but the cleaned image is not
  /// yet available (including failure fallback), keep an opaque
  /// backing plate so hydrated translation text cannot float over original
  /// glyphs after a cold start.
  double effectiveOverlayBackgroundOpacity(
    String requestKey,
    double userOpacity, {
    ImageProcessingDisplayMode? displayModeOverride,
  }) {
    final ImageProcessingDisplayMode mode = displayModeOverride ?? displayMode;
    final bool needsRepair =
        mode == ImageProcessingDisplayMode.repairedBackgroundEmbeddedText ||
        mode == ImageProcessingDisplayMode.translatedImage;
    if (!needsRepair) {
      return userOpacity;
    }
    if (_usableDisplayPath(requestKey, mode) != null) {
      return userOpacity;
    }
    return 1.0;
  }

  String? _usableDisplayPath(
    String requestKey,
    ImageProcessingDisplayMode mode,
  ) {
    final InpaintingResult result = resultFor(requestKey);
    if (mode == ImageProcessingDisplayMode.overlay) {
      return null;
    }
    if (mode == ImageProcessingDisplayMode.translatedImage) {
      final String? translated =
          _translatedImagePaths[requestKey] ?? result.translatedImagePath;
      if (translated != null && File(translated).existsSync()) {
        return translated;
      }
    }
    final String? repaired = result.outputPath;
    return result.status == InpaintingStatus.success &&
            repaired != null &&
            File(repaired).existsSync()
        ? repaired
        : null;
  }

  /// Returns the derived image for the selected display mode, or null when
  /// normal overlay rendering must remain the fallback.
  String? displayPathFor(String requestKey) {
    final InpaintingResult result = resultFor(requestKey);
    if (displayMode == ImageProcessingDisplayMode.overlay) {
      return null;
    }
    if (displayMode == ImageProcessingDisplayMode.translatedImage) {
      final String? translated =
          _translatedImagePaths[requestKey] ?? result.translatedImagePath;
      if (translated != null && File(translated).existsSync()) {
        return translated;
      }
    }
    final String? repaired = result.outputPath;
    return result.status == InpaintingStatus.success &&
            repaired != null &&
            File(repaired).existsSync()
        ? repaired
        : null;
  }

  bool shouldDrawTranslationOverlay(String requestKey) =>
      !(displayMode == ImageProcessingDisplayMode.translatedImage &&
          displayPathFor(requestKey) != null &&
          _translatedImagePaths[requestKey] != null);

  void publishTranslatedImage(String requestKey, String path) {
    if (!File(path).existsSync()) {
      return;
    }
    _translatedImagePaths[requestKey] = path;
    final InpaintingResult current = resultFor(requestKey);
    _results[requestKey] = current.copyWith(translatedImagePath: path);
    update([requestKey]);
  }

  /// Runs the complete optional CTD -> LaMa Large pipeline. CTD polygons are the
  /// only accepted masks: OCR rectangles are never substituted because that
  /// would erase artwork outside the actual text glyphs.
  Future<InpaintingResult> detectAndRepair({
    required String requestKey,
    required String sourcePath,
    bool force = false,
    List<RecognizedTextBlock> eraseOnlyBlocks = const <RecognizedTextBlock>[],
  }) async {
    _set(requestKey, const InpaintingResult(status: InpaintingStatus.queued));
    final File source = File(sourcePath);
    if (!await source.exists()) {
      return _fail(requestKey, 'source_unavailable');
    }
    // Never run a full-page CTD erase without translation geometry. Sparse OCR
    // followed by unrestricted masks blanks every speech bubble that was not
    // translated.
    if (eraseOnlyBlocks.isEmpty) {
      return _fail(requestKey, 'translation_geometry_required');
    }
    final DetectionEngine? detector = engineRegistry.findDetection(
      'ctd-detection',
    );
    if (detector == null || !detector.isReady) {
      return _fail(requestKey, 'ctd_not_ready');
    }
    final EngineTask<DetectionResult> task = detector.detect(
      EngineImageRequest(imagePath: sourcePath),
    );
    _activeDetectionTasks[requestKey] = task;
    _set(requestKey, const InpaintingResult(status: InpaintingStatus.running));
    try {
      final DetectionResult detection = await task.future;
      if (detection.polygonMasks.isEmpty) {
        return _fail(requestKey, 'ctd_no_text');
      }
      final List<PolygonMask> masks = filterPolygonMasksToTranslatedBlocks(
        masks: detection.polygonMasks,
        translatedBlocks: eraseOnlyBlocks,
      );
      if (masks.isEmpty) {
        return _fail(requestKey, 'no_translated_masks');
      }
      return repair(
        requestKey: requestKey,
        sourcePath: sourcePath,
        polygonMasks: masks,
        force: force,
      );
    } on EngineTaskCancelledException {
      const InpaintingResult result = InpaintingResult(
        status: InpaintingStatus.canceled,
        errorCode: 'canceled',
        fallbackToOverlay: true,
      );
      _set(requestKey, result);
      return result;
    } on EngineException catch (error) {
      return _fail(requestKey, error.code);
    } catch (_) {
      return _fail(requestKey, 'ctd_failed');
    } finally {
      if (identical(_activeDetectionTasks[requestKey], task)) {
        _activeDetectionTasks.remove(requestKey);
      }
    }
  }

  Future<InpaintingResult> repair({
    required String requestKey,
    required String sourcePath,
    required List<PolygonMask> polygonMasks,
    bool force = false,
  }) async {
    _set(requestKey, const InpaintingResult(status: InpaintingStatus.queued));
    final File source = File(sourcePath);
    if (!await source.exists()) {
      return _fail(requestKey, 'source_unavailable');
    }
    if (polygonMasks.isEmpty ||
        polygonMasks.any((PolygonMask mask) => !mask.isValid)) {
      return _fail(requestKey, 'polygon_mask_required');
    }

    final String sourceHash = await _sha256(source);
    final String maskHash = _maskHash(polygonMasks);
    final ModelDescriptor? descriptor = engineRegistry.modelCatalog.find(
      'lama-large-512px',
    );
    final String modelFingerprint = descriptor?.fingerprint ?? 'unverified';
    final String artifactKey = _artifactKey(
      sourceHash,
      maskHash,
      modelFingerprint,
    );
    _artifactKeys[requestKey] = artifactKey;
    final File output = File(join(_cacheDirectory.path, '$artifactKey.png'));
    final File metadata = File(join(_cacheDirectory.path, '$artifactKey.json'));

    if (!force) {
      final InpaintingResult? cached = await _readCache(
        metadata,
        output,
        sourceHash: sourceHash,
        maskHash: maskHash,
        modelFingerprint: modelFingerprint,
      );
      if (cached != null) {
        _artifactKeys[requestKey] = artifactKey;
        await _writeRequestIndex(
          requestKey: requestKey,
          artifactKey: artifactKey,
          sourceHash: sourceHash,
        );
        _set(requestKey, cached);
        return cached;
      }
    }

    final InpaintEngine? engine = engineRegistry.findInpaint(
      'onnx-lama-inpaint',
    );
    if (engine == null || !engine.isReady) {
      return _fail(requestKey, 'model_missing', sourceHash: sourceHash);
    }
    final EngineTask<String> task = engine.inpaint(
      ImageProcessingRequest(
        imagePath: sourcePath,
        outputPath: output.path,
        polygonMasks: polygonMasks,
        configuration: <String, dynamic>{
          'modelFingerprint': modelFingerprint,
          'maskFingerprint': maskHash,
        },
      ),
    );
    _activeTasks[requestKey] = task;
    _set(
      requestKey,
      InpaintingResult(
        status: InpaintingStatus.running,
        sourceHash: sourceHash,
      ),
    );
    try {
      final String outputPath = await task.future;
      if (!await File(outputPath).exists()) {
        return _fail(requestKey, 'output_missing', sourceHash: sourceHash);
      }
      final String outputHash = await _sha256(File(outputPath));
      await _writeMetadata(metadata, <String, dynamic>{
        'schemaVersion': 4,
        'sourceHash': sourceHash,
        'maskHash': maskHash,
        'modelFingerprint': modelFingerprint,
        'outputHash': outputHash,
        'outputPath': outputPath,
      });
      final InpaintingResult result = InpaintingResult(
        status: InpaintingStatus.success,
        outputPath: outputPath,
        sourceHash: sourceHash,
      );
      await _writeRequestIndex(
        requestKey: requestKey,
        artifactKey: artifactKey,
        sourceHash: sourceHash,
      );
      _set(requestKey, result);
      return result;
    } on EngineTaskCancelledException {
      final InpaintingResult result = InpaintingResult(
        status: InpaintingStatus.canceled,
        sourceHash: sourceHash,
        errorCode: 'canceled',
        fallbackToOverlay: true,
      );
      _set(requestKey, result);
      return result;
    } on EngineException catch (error) {
      return _fail(requestKey, error.code, sourceHash: sourceHash);
    } catch (_) {
      return _fail(requestKey, 'inpaint_failed', sourceHash: sourceHash);
    } finally {
      if (identical(_activeTasks[requestKey], task)) {
        _activeTasks.remove(requestKey);
      }
    }
  }

  void cancel(String requestKey) {
    _activeDetectionTasks[requestKey]?.cancel('detection cancelled');
    _activeTasks[requestKey]?.cancel('inpainting cancelled');
  }

  /// Drop the in-memory repaired/translated display for [requestKey] so the
  /// reader shows the original page again (e.g. before a force re-OCR). Does
  /// not delete on-disk artifacts.
  void clearDisplayResult(String requestKey) {
    cancel(requestKey);
    _results.remove(requestKey);
    _translatedImagePaths.remove(requestKey);
    update([requestKey]);
  }

  Future<void> clearCache({String? requestKey}) async {
    if (requestKey == null) {
      if (await _cacheDirectory.exists()) {
        await for (final FileSystemEntity entity in _cacheDirectory.list(
          recursive: true,
        )) {
          if (entity is File &&
              (entity.path.endsWith('.png') || entity.path.endsWith('.json'))) {
            await entity.delete();
          }
        }
      }
      _results.clear();
      _artifactKeys.clear();
      _translatedImagePaths.clear();
      update();
      return;
    }
    final String? artifactKey = _artifactKeys.remove(requestKey);
    if (artifactKey != null) {
      for (final String suffix in const <String>['.png', '.json']) {
        final File file = File(
          join(_cacheDirectory.path, '$artifactKey$suffix'),
        );
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    final File indexFile = _requestIndexFile(requestKey);
    if (await indexFile.exists()) {
      await indexFile.delete();
    }
    _results.remove(requestKey);
    _translatedImagePaths.remove(requestKey);
    update([requestKey]);
  }

  InpaintingResult _fail(String requestKey, String code, {String? sourceHash}) {
    final String normalized = _normalizeFailureCode(code);
    // warning() is async; swallow init failures so unit tests without
    // PathService still exercise detectAndRepair fallbacks.
    unawaited(
      log
          .warning(
            'CTD/LaMa Large background repair unavailable; falling back to overlay boxes '
            '($normalized)',
          )
          .catchError((Object _) {}),
    );
    final InpaintingResult result = InpaintingResult(
      status: InpaintingStatus.failed,
      errorCode: normalized,
      sourceHash: sourceHash,
      fallbackToOverlay: true,
    );
    _set(requestKey, result);
    return result;
  }

  /// Maps engine-level codes onto the stable reasons shown in UI/logs.
  String _normalizeFailureCode(String code) {
    switch (code) {
      case 'model_unavailable':
      case 'inpaint_not_ready':
      case 'lama_not_ready':
      case 'migan_not_ready':
        return 'model_missing';
      default:
        return code;
    }
  }

  void _set(String requestKey, InpaintingResult result) {
    _results[requestKey] = result;
    update([requestKey]);
  }

  Future<InpaintingResult?> _readCache(
    File metadata,
    File output, {
    required String sourceHash,
    required String maskHash,
    required String modelFingerprint,
  }) async {
    if (!await metadata.exists() || !await output.exists()) {
      return null;
    }
    try {
      final dynamic decoded = jsonDecode(await metadata.readAsString());
      if (decoded is! Map ||
          decoded['schemaVersion'] != 4 ||
          decoded['sourceHash'] != sourceHash ||
          decoded['maskHash'] != maskHash ||
          decoded['modelFingerprint'] != modelFingerprint ||
          decoded['outputPath'] != output.path) {
        return null;
      }
      if (decoded['outputHash'] != await _sha256(output)) {
        return null;
      }
      return InpaintingResult(
        status: InpaintingStatus.success,
        outputPath: output.path,
        fromCache: true,
        sourceHash: sourceHash,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMetadata(File file, Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  File _requestIndexFile(String requestKey) => File(
    join(
      _cacheDirectory.path,
      'by-request',
      '${sha256.convert(utf8.encode(requestKey)).toString()}.json',
    ),
  );

  Future<void> _writeRequestIndex({
    required String requestKey,
    required String artifactKey,
    required String sourceHash,
  }) async {
    final File indexFile = _requestIndexFile(requestKey);
    final String? translated = _translatedImagePaths[requestKey];
    await _writeMetadata(indexFile, <String, dynamic>{
      'schemaVersion': 4,
      'requestKey': requestKey,
      'artifactKey': artifactKey,
      'sourceHash': sourceHash,
      if (translated != null) 'translatedImagePath': translated,
    });
  }

  Future<String> _sha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  String _maskHash(List<PolygonMask> masks) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode(
                masks.map((PolygonMask mask) => mask.toJson()).toList(),
              ),
            ),
          )
          .toString();

  String _artifactKey(String sourceHash, String maskHash, String modelHash) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode(<String, String>{
                'sourceHash': sourceHash,
                'maskHash': maskHash,
                'modelHash': modelHash,
                'pipeline': 'lama-refined-v1',
              }),
            ),
          )
          .toString();
}

ImageInpaintingService imageInpaintingService = ImageInpaintingService();
