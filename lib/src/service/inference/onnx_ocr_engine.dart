import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/utils/oriented_rect.dart';
import 'package:jhentai/src/utils/rgba_raster.dart';

import 'inference_exception.dart';
import 'inference_timings.dart';
import 'inference_task.dart';
import 'inference_safety.dart';
import 'ocr_inference_engine.dart';
import 'onnx_runtime.dart';
import '../../utils/ocr_layout_protocol.dart';
import '../../utils/perspective_crop.dart';

typedef OnnxProviderResolver = List<ort.OrtProvider> Function();

/// Immutable ONNX OCR model-file info. Resolved on the UI isolate and passed
/// to the OCR worker isolate, which cannot touch [OnnxModelStore] (its
/// [GetxController]/pathService wiring is only initialized on the UI isolate).
class OnnxOcrModelInfo {
  const OnnxOcrModelInfo({
    required this.detPath,
    required this.clsPath,
    required this.recPath,
    required this.dictPath,
    required this.fingerprint,
  });

  final String detPath;
  final String clsPath;
  final String recPath;
  final String dictPath;
  final String fingerprint;
}

/// End-to-end PP-OCRv6 small pipeline: DB detection and CTC recognition.
/// The 0/180-degree line classifier is not run: upside-down lines practically
/// never occur in comics, and it cost one native round trip per detected line. The detector uses connected DB regions and conservative
/// rectangle expansion; this avoids native OpenCV while preserving original
/// image coordinates for the translation overlay.
///
/// All work is performed on the calling isolate; the OCR worker isolate owns
/// an [OnnxRuntime] instance and drives this engine off the UI thread.
class OnnxOcrInferenceEngine implements OcrInferenceEngine {
  OnnxOcrInferenceEngine({
    required this.runtime,
    required this.providerResolver,
    required this.model,
    this.safetyConfig,
    this.timings,
  });

  final OnnxRuntime runtime;
  final OnnxProviderResolver providerResolver;
  final OnnxOcrModelInfo model;
  final InferenceSessionSafetyConfig? safetyConfig;
  final InferenceTimings? timings;
  final Map<String, String> _sessionRoles = {};

  static const double _detThreshold = OcrScoringProtocol.detectorPixelThreshold;
  static const double _boxThreshold = OcrScoringProtocol.detectorBoxThreshold;
  static const double _textThreshold =
      OcrScoringProtocol.recognitionConfidenceThreshold;
  static const int _maxInputBytes = 80 * 1024 * 1024;
  static const int _maxDetectedLines = 256;

  /// DB unclip ratio: expands each text box by `area * ratio / perimeter`
  /// along its own axes (matches RapidOCR's `unclip_ratio: 1.6`).
  static const double _unclipRatio = 1.6;

  /// Recognition crops are processed in width-sorted batches to amortize the
  /// ONNX call overhead; the rec model's dynamic-batch profile allows up to 6.
  static const int _recBatchSize = 6;

  @override
  String get displayName => 'ONNX · PP-OCRv6 small';

  @override
  bool get isReady => runtime.isAvailable && providerResolver().isNotEmpty;

  @override
  Future<OcrInferenceResult> recognize(
    String imagePath, {
    RgbaRaster? image,
    int maxDimension = 2200,
    InferenceCancellationToken? cancellationToken,
    InferenceProgressCallback? onProgress,
  }) async {
    final InferenceCancellationToken token =
        cancellationToken ?? InferenceCancellationToken();
    token.throwIfCancelled();
    if (!isReady) {
      throw const InferenceNotReadyException('onnx-ocr');
    }
    final File inputFile = File(imagePath);
    if (image == null &&
        (!await inputFile.exists() ||
            await inputFile.length() > _maxInputBytes)) {
      throw StateError('OCR input is missing or exceeds 80 MiB');
    }

    final int? sessionStart = timings?.now;
    final List<ort.OrtProvider> providers = providerResolver();
    final List<ort.OrtSession?> sessions =
        await Future.wait(<Future<ort.OrtSession?>>[
          runtime.session(
            model.detPath,
            modelFingerprint: '${model.fingerprint}:det',
            providers: providers,
            safetyConfig: safetyConfig,
          ),
          runtime.session(
            model.recPath,
            modelFingerprint: '${model.fingerprint}:rec',
            providers: providers,
            safetyConfig: safetyConfig,
          ),
        ]);
    final ort.OrtSession? detSession = sessions[0];
    final ort.OrtSession? recSession = sessions[1];
    if (detSession == null || recSession == null) {
      throw const InferenceNotReadyException('onnx-ocr');
    }

    timings?.record('ocr.sessions', sessionStart!, {'providers': providers.map((p) => p.name).join(',')});
    _sessionRoles[detSession.id] = 'det';
    _sessionRoles[recSession.id] = 'rec';
    final int? decodeStart = timings?.now;
    final RgbaRaster? original =
        image ?? RgbaRaster.decode(await inputFile.readAsBytes());
    if (original == null) {
      throw StateError('unsupported OCR image');
    }
    final int originalWidth = original.width;
    final int originalHeight = original.height;
    timings?.record('ocr.decode', decodeStart!, {'width': originalWidth, 'height': originalHeight, 'predecoded': image != null});
    onProgress?.call(0.08);

    token.throwIfCancelled();
    final int? detStart = timings?.now;
    final List<_DetectedBox> boxes = await _detect(
      detSession,
      original,
      maxDimension,
      token,
    );
    timings?.record('ocr.primary_detection', detStart!, {'boxes': boxes.length});
    onProgress?.call(0.42);
    if (boxes.isEmpty) {
      return OcrInferenceResult(
        blocks: const <RecognizedTextBlock>[],
        imageWidth: originalWidth,
        imageHeight: originalHeight,
      );
    }

    // Pass 1: straighten each detected box (min-area rect + unclip) into an
    // axis-aligned crop.
    final int? linesStart = timings?.now;
    final List<String> characters = await _loadCharacters(model.dictPath);
    final List<_RecognizedCandidate> candidates = await _recognizeBoxes(
      source: original,
      boxes: boxes,
      recSession: recSession,
      characters: characters,
      token: token,
    );
    timings?.record('ocr.primary_lines', linesStart!, {'candidates': candidates.length});
    onProgress?.call(0.70);

    // DB detectors commonly fuse adjacent tategaki columns into horizontal
    // strips. The recognizer then sees two columns at once and produces the
    // characteristic high-confidence garbage seen on Japanese margin text.
    // When the first pass finds a vertical margin candidate, rerun only those
    // margins after a 90° image rotation. This turns each vertical column into
    // the horizontal contract expected by PP-OCR, without rotating glyphs in
    // the crop one by one. The mapped boxes remain in the original image space.
    final int? rotatedStart = timings?.now;
    final List<_RecognizedCandidate> rotatedCandidates =
        await _recognizeRotatedMarginsIfNeeded(
          original: original,
          boxes: boxes,
          detSession: detSession,
          recSession: recSession,
          characters: characters,
          token: token,
          maxDimension: maxDimension,
        );
    timings?.record('ocr.rotated_margins', rotatedStart!, {'candidates': rotatedCandidates.length});
    if (candidates.isEmpty && rotatedCandidates.isEmpty) {
      return OcrInferenceResult(
        blocks: const <RecognizedTextBlock>[],
        imageWidth: originalWidth,
        imageHeight: originalHeight,
      );
    }
    if (rotatedCandidates.isNotEmpty) {
      // Keep first-pass margin candidates that the rotated pass did not
      // actually replace. Dropping every margin box whenever the rotated pass
      // returns anything made a sparse/partial rotated result erase most of
      // the page's vertical dialogue (the Blue Archive sauna-page regression).
      final List<_RecognizedCandidate> kept = <_RecognizedCandidate>[];
      for (final _RecognizedCandidate candidate in candidates) {
        final (double left, double _, double width, double _) =
            candidate.box.rect.bbox;
        if (!_isInTextMargin(left, width, originalWidth)) {
          kept.add(candidate);
          continue;
        }
        final bool superseded = rotatedCandidates.any((
          _RecognizedCandidate rotated,
        ) {
          final (double aLeft, double aTop, double aWidth, double aHeight) =
              candidate.box.rect.bbox;
          final (double bLeft, double bTop, double bWidth, double bHeight) =
              rotated.box.rect.bbox;
          return _axisAlignedIoU(
                aLeft,
                aTop,
                aWidth,
                aHeight,
                bLeft,
                bTop,
                bWidth,
                bHeight,
              ) >=
              0.3;
        });
        if (!superseded) {
          kept.add(candidate);
        }
      }
      candidates
        ..clear()
        ..addAll(kept)
        ..addAll(rotatedCandidates);
    }
    final List<RecognizedTextBlock> blocks = candidates
        .map((_RecognizedCandidate candidate) {
          final (double left, double top, double width, double height) =
              candidate.box.rect.bbox;
          return RecognizedTextBlock(
            text: candidate.line.text.trim(),
            confidence: candidate.line.confidence,
            left: left,
            top: top,
            width: width,
            height: height,
          );
        })
        .where((RecognizedTextBlock block) => block.text.isNotEmpty)
        .toList(growable: false);
    onProgress?.call(1);

    return OcrInferenceResult(
      blocks: sortRecognizedTextBlocks(blocks),
      imageWidth: originalWidth,
      imageHeight: originalHeight,
    );
  }

  Future<List<_RecognizedCandidate>> _recognizeBoxes({
    required RgbaRaster source,
    required List<_DetectedBox> boxes,
    required ort.OrtSession recSession,
    required List<String> characters,
    required InferenceCancellationToken token,
  }) async {
    final List<_DetectedBox> validBoxes = <_DetectedBox>[];
    final List<RgbaRaster> crops = <RgbaRaster>[];
    for (final _DetectedBox box in boxes) {
      token.throwIfCancelled();
      final int? cropStart = timings?.now;
      final RgbaRaster? crop = straightenOcrCrop(source, box.rect);
      if (crop == null) continue;
      // PP-OCR's mobile angle classifier only distinguishes 0°/180°. A
      // tategaki column therefore reaches recognition as a narrow vertical
      // strip and is commonly returned as fragmented or reversed. Rotate tall
      // detector boxes into the recognizer's horizontal contract; the source
      // rectangle remains untouched for layout/overlay.
      final (double _, double _, double boxWidth, double boxHeight) =
          box.rect.bbox;
      final bool vertical =
          boxHeight > boxWidth * OcrScoringProtocol.verticalAspectRatio;
      crops.add(vertical ? crop.rotate90(clockwise: false) : crop);
      timings?.record('ocr.crop', cropStart!);
      validBoxes.add(box);
    }
    if (crops.isEmpty) return const <_RecognizedCandidate>[];

    final List<_RecognizedLine> lines = await _recognizeLines(
      recSession,
      crops,
      characters,
      token,
    );
    final List<_RecognizedCandidate> result = <_RecognizedCandidate>[];
    for (int i = 0; i < validBoxes.length; i++) {
      final _RecognizedLine line = lines[i];
      if (line.text.trim().isNotEmpty && line.confidence >= _textThreshold) {
        result.add(_RecognizedCandidate(validBoxes[i], line));
      }
    }
    return result;
  }

  Future<List<_RecognizedCandidate>> _recognizeRotatedMarginsIfNeeded({
    required RgbaRaster original,
    required List<_DetectedBox> boxes,
    required ort.OrtSession detSession,
    required ort.OrtSession recSession,
    required List<String> characters,
    required InferenceCancellationToken token,
    required int maxDimension,
  }) async {
    if (!_shouldProbeVerticalMargins(
      boxes,
      original.width,
      original.height,
    )) {
      return const <_RecognizedCandidate>[];
    }
    final int marginWidth = math.min(
      720,
      math.max(192, (original.width * 0.22).round()),
    );
    final List<_VerticalMargin> margins = <_VerticalMargin>[
      _VerticalMargin(left: 0, width: marginWidth),
      _VerticalMargin(
        left: math.max(0, original.width - marginWidth),
        width: marginWidth,
      ),
    ];
    final List<_RecognizedCandidate> result = <_RecognizedCandidate>[];
    for (final _VerticalMargin margin in margins) {
      token.throwIfCancelled();
      final RgbaRaster sourceMargin = original.crop(
        margin.left,
        0,
        margin.width,
        original.height,
      );
      // A counterclockwise rotation maps source (x, y) to rotated
      // (y, width - 1 - x): each top-to-bottom column becomes a left-to-right
      // line, the same contract as the per-box rotation of tall crops. (A
      // clockwise turn would read right-to-left and needs a 180-degree flip.)
      final RgbaRaster rotatedSource = sourceMargin.rotate90(clockwise: false);
      final List<_DetectedBox> rotatedBoxes = await _detect(
        detSession,
        rotatedSource,
        maxDimension,
        token,
      );
      if (rotatedBoxes.isEmpty) continue;
      final List<_RecognizedCandidate> recognized = await _recognizeBoxes(
        source: rotatedSource,
        boxes: rotatedBoxes,
        recSession: recSession,
        characters: characters,
        token: token,
      );
      for (final _RecognizedCandidate candidate in recognized) {
        final OrientedRect mapped = _mapCounterclockwiseRotatedRect(
          candidate.box.rect,
          sourceMargin.width,
          margin.left,
        );
        final (double left, double top, double width, double height) =
            mapped.bbox;
        if (!_isNearVerticalMargin(
          left,
          top,
          width,
          height,
          original.width,
          original.height,
        )) {
          continue;
        }
        result.add(
          _RecognizedCandidate(
            _DetectedBox(mapped, candidate.box.detectionScore),
            candidate.line,
          ),
        );
      }
    }
    return result;
  }

  bool _shouldProbeVerticalMargins(
    List<_DetectedBox> boxes,
    int width,
    int height,
  ) {
    final List<(double, double, double, double)> edgeBoxes = <(
      double,
      double,
      double,
      double
    )>[];
    for (final _DetectedBox box in boxes) {
      final (double left, double top, double boxWidth, double boxHeight) =
          box.rect.bbox;
      if (_isInTextMargin(left, boxWidth, width)) {
        edgeBoxes.add((left, top, boxWidth, boxHeight));
      }
    }
    if (edgeBoxes.length < 2) return false;
    final bool hasTallEdgeBox = edgeBoxes.any(
      ((double _, double _, double boxWidth, double boxHeight) box) =>
          box.$4 > box.$3 * 1.35,
    );
    // When DB has fused two vertical columns into horizontal strips, no one
    // box is tall. Repeated edge boxes are still a useful conservative signal
    // for a margin text run; the rotated pass filters its result back to tall
    // mapped boxes, so ordinary horizontal dialogue does not survive it.
    return hasTallEdgeBox ||
        (edgeBoxes.length >= 4 && width > height * 0.9);
  }

  bool _isNearVerticalMargin(
    double left,
    double top,
    double width,
    double height,
    int sourceWidth,
    int sourceHeight,
  ) =>
      _isInTextMargin(left, width, sourceWidth) &&
      height > width * 1.2 &&
      top < sourceHeight;


  double _axisAlignedIoU(
    double aLeft,
    double aTop,
    double aWidth,
    double aHeight,
    double bLeft,
    double bTop,
    double bWidth,
    double bHeight,
  ) {
    final double aRight = aLeft + aWidth;
    final double aBottom = aTop + aHeight;
    final double bRight = bLeft + bWidth;
    final double bBottom = bTop + bHeight;
    final double interLeft = math.max(aLeft, bLeft);
    final double interTop = math.max(aTop, bTop);
    final double interRight = math.min(aRight, bRight);
    final double interBottom = math.min(aBottom, bBottom);
    final double interW = interRight - interLeft;
    final double interH = interBottom - interTop;
    if (interW <= 0 || interH <= 0) {
      return 0;
    }
    final double inter = interW * interH;
    final double union = aWidth * aHeight + bWidth * bHeight - inter;
    return union <= 0 ? 0 : inter / union;
  }

  bool _isInTextMargin(double left, double width, int sourceWidth) {
    final double right = left + width;
    return left <= sourceWidth * 0.22 || right >= sourceWidth * 0.78;
  }

  /// Maps a rect detected on the counterclockwise-rotated margin back to
  /// page coordinates: rotated (x, y) is margin (width - 1 - y, x).
  OrientedRect _mapCounterclockwiseRotatedRect(
    OrientedRect rect,
    int sourceMarginWidth,
    int marginLeft,
  ) {
    final List<OcrPoint> mappedCorners = rect.corners
        .map(
          (OcrPoint point) => (
            marginLeft + sourceMarginWidth - 1 - point.$2,
            point.$1,
          ),
        )
        .toList(growable: false);
    return minAreaRect(mappedCorners);
  }

  /// Detector input size: the longer side capped at [maxDimension], both
  /// sides aligned to 32 and bounded by the session's pixel budget.
  InferencePixelSize _detectionSize(RgbaRaster source, int maxDimension) {
    final int safeMax = maxDimension.clamp(640, 2600);
    double scale = math.min(1, safeMax / math.max(source.width, source.height));
    int width = math.max(32, (source.width * scale / 32).round() * 32);
    int height = math.max(32, (source.height * scale / 32).round() * 32);
    width = math.min(width, 2624);
    height = math.min(height, 2624);
    final InferencePixelSize bounded = InferencePixelBudget(
      safetyConfig?.maxInputPixels ?? 4 * 1024 * 1024,
    ).fit(width, height, alignment: 32);
    return bounded;
  }

  /// Runs DB detection on [source] and returns boxes in its pixel space.
  Future<List<_DetectedBox>> _detect(
    ort.OrtSession session,
    RgbaRaster source,
    int maxDimension,
    InferenceCancellationToken token,
  ) async {
    final int? prepStart = timings?.now;
    final InferencePixelSize size = _detectionSize(source, maxDimension);
    final int mapWidth = size.width;
    final int mapHeight = size.height;
    final Float32List input = Float32List(mapWidth * mapHeight * 3);
    source.writeResizedNchw(
      input,
      targetWidth: mapWidth,
      targetHeight: mapHeight,
      rowStride: mapWidth,
      planeSize: mapWidth * mapHeight,
      scale: 2,
      offset: -1,
    );
    timings?.record('det.normalize', prepStart!, {'width': mapWidth, 'height': mapHeight});
    final List<dynamic> output = await _runSingleOutput(
      session,
      input,
      <int>[1, 3, mapHeight, mapWidth],
      token,
      expectedRank: 4,
      expectedChannels: 1,
    );
    final int? postStart = timings?.now;
    final int originalWidth = source.width;
    final int originalHeight = source.height;
    if (output.length != mapWidth * mapHeight) {
      throw StateError(
        'unexpected PP-OCR detector output: ${output.length} != ${mapWidth * mapHeight}',
      );
    }
    final Uint8List mask = Uint8List(output.length);
    for (int y = 0; y < mapHeight; y++) {
      final int row = y * mapWidth;
      for (int x = 0; x < mapWidth; x++) {
        final int index = row + x;
        if ((output[index] as num).toDouble() <= _detThreshold) {
          continue;
        }
        mask[index] = 1;
        if (x + 1 < mapWidth) mask[index + 1] = 1;
        if (y + 1 < mapHeight) mask[index + mapWidth] = 1;
        if (x + 1 < mapWidth && y + 1 < mapHeight) {
          mask[index + mapWidth + 1] = 1;
        }
      }
    }

    final Uint8List visited = Uint8List(mask.length);
    final Int32List queue = Int32List(mask.length);
    final List<_DetectedBox> result = <_DetectedBox>[];
    final double sx = originalWidth / mapWidth;
    final double sy = originalHeight / mapHeight;
    for (int seed = 0; seed < mask.length; seed++) {
      if (mask[seed] == 0 || visited[seed] != 0) continue;
      token.throwIfCancelled();
      int head = 0;
      int tail = 0;
      queue[tail++] = seed;
      visited[seed] = 1;
      int count = 0;
      double scoreSum = 0;
      final List<OcrPoint> pixels = <OcrPoint>[];
      while (head < tail) {
        final int index = queue[head++];
        final int x = index % mapWidth;
        final int y = index ~/ mapWidth;
        pixels.add((x * sx, y * sy));
        scoreSum += (output[index] as num).toDouble();
        count++;
        for (int dy = -1; dy <= 1; dy++) {
          final int ny = y + dy;
          if (ny < 0 || ny >= mapHeight) continue;
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final int nx = x + dx;
            if (nx < 0 || nx >= mapWidth) continue;
            final int next = ny * mapWidth + nx;
            if (mask[next] != 0 && visited[next] == 0) {
              visited[next] = 1;
              queue[tail++] = next;
            }
          }
        }
      }
      final double score = scoreSum / math.max(1, count);
      if (count < 6 || score < _boxThreshold) {
        continue;
      }
      // Minimal-area oriented rect around the component — the text direction
      // and thickness — expanded by the DB unclip distance along its axes.
      final OrientedRect rect = unclipOrientedRect(
        minAreaRect(pixels),
        ratio: _unclipRatio,
      );
      final (double _, double _, double width, double height) = rect.bbox;
      if (width < 4 || height < 4) {
        continue;
      }
      result.add(_DetectedBox(rect, score));
    }

    final List<OcrLayoutBox> layout = <OcrLayoutBox>[
      for (int i = 0; i < result.length; i++)
        OcrLayoutBox(
          sourceIndex: i,
          left: result[i].rect.bbox.$1,
          top: result[i].rect.bbox.$2,
          width: result[i].rect.bbox.$3,
          height: result[i].rect.bbox.$4,
        ),
    ];
    timings?.record('det.postprocess', postStart!, {'boxes': result.length});
    return sortOcrReadingOrder(layout)
        .take(_maxDetectedLines)
        .map((_layout) => result[_layout.sourceIndex])
        .toList(growable: false);
  }

  /// Recognizes [crops] with a single dynamic-batch ONNX call per group of
  /// similar-width lines (width-sorted so each batch's right-padding stays
  /// small), returning one [RecognizedLine] per crop in input order.
  Future<List<_RecognizedLine>> _recognizeLines(
    ort.OrtSession session,
    List<RgbaRaster> crops,
    List<String> characters,
    InferenceCancellationToken token,
  ) async {
    final List<_RecognizedLine> results = List<_RecognizedLine>.filled(
      crops.length,
      const _RecognizedLine('', 0),
    );
    final List<int> order = List<int>.generate(crops.length, (int i) => i)
      ..sort((int a, int b) => crops[a].width.compareTo(crops[b].width));
    for (int start = 0; start < order.length; start += _recBatchSize) {
      token.throwIfCancelled();
      final List<int> batch = order.sublist(
        start,
        math.min(start + _recBatchSize, order.length),
      );
      int maxTargetWidth = 0;
      for (final int index in batch) {
        maxTargetWidth = math.max(
          maxTargetWidth,
          _recTargetWidth(crops[index]),
        );
      }
      final int? prepStart = timings?.now;
      final Float32List input = _normalizedBatchNchw(<RgbaRaster>[
        for (final int index in batch) crops[index],
      ], maxTargetWidth);
      timings?.record('rec.normalize', prepStart!);
      try {
        final _TensorOutput output = await _runOutput(
          session,
          input,
          <int>[batch.length, 3, 48, maxTargetWidth],
          token,
          expectedRank: 3,
        );
        final int timeSteps = output.shape[1];
        final int classes = output.shape[2];
        if (classes != characters.length ||
            output.values.length != batch.length * timeSteps * classes) {
          throw StateError(
            'PP-OCR dictionary/model mismatch: $classes != ${characters.length}',
          );
        }
        for (int j = 0; j < batch.length; j++) {
          results[batch[j]] = _ctcDecode(
            output.values,
            j,
            timeSteps,
            classes,
            characters,
          );
        }
      } catch (error) {
        timings?.record('rec.batch_fallback', timings!.now, {'error': error.toString(), 'batch': batch.length});
        // The exported model may not accept a dynamic batch dimension; fall
        // back to one inference call per line for this group.
        for (final int index in batch) {
          results[index] = await _recognizeSingle(
            session,
            crops[index],
            characters,
            token,
          );
        }
      }
    }
    return results;
  }

  /// Single-line recognition (batch of one), used as a fallback when a group's
  /// batched call fails — e.g. a model export with a fixed batch dimension.
  Future<_RecognizedLine> _recognizeSingle(
    ort.OrtSession session,
    RgbaRaster crop,
    List<String> characters,
    InferenceCancellationToken token,
  ) async {
    final int targetWidth = _recTargetWidth(crop);
    final Float32List input = _normalizedBatchNchw(<RgbaRaster>[
      crop,
    ], targetWidth);
    final _TensorOutput output = await _runOutput(
      session,
      input,
      <int>[1, 3, 48, targetWidth],
      token,
      expectedRank: 3,
    );
    final int timeSteps = output.shape[1];
    final int classes = output.shape[2];
    if (classes != characters.length ||
        output.values.length != timeSteps * classes) {
      throw StateError(
        'PP-OCR dictionary/model mismatch: $classes != ${characters.length}',
      );
    }
    return _ctcDecode(output.values, 0, timeSteps, classes, characters);
  }

  /// The recognition input width for [crop]: height 48, width from the aspect
  /// ratio rounded up to a multiple of 8, bounded to [320, 2048].
  int _recTargetWidth(RgbaRaster crop) {
    const int targetHeight = 48;
    final double ratio = crop.width / math.max(1, crop.height);
    final int targetWidth =
        (math.max(320, (targetHeight * ratio).ceil()) / 8).ceil() * 8;
    return targetWidth.clamp(320, 2048);
  }

  /// Greedy CTC decode of one batch row into text plus mean frame confidence.
  _RecognizedLine _ctcDecode(
    List<dynamic> values,
    int batchIndex,
    int timeSteps,
    int classes,
    List<String> characters,
  ) {
    final int? decodeStart = timings?.now;
    final StringBuffer text = StringBuffer();
    int previous = -1;
    double confidence = 0;
    int selected = 0;
    final int row = batchIndex * timeSteps * classes;
    for (int t = 0; t < timeSteps; t++) {
      final int offset = row + t * classes;
      int bestIndex = 0;
      double bestScore = double.negativeInfinity;
      for (int c = 0; c < classes; c++) {
        final double score = (values[offset + c] as num).toDouble();
        if (score > bestScore) {
          bestScore = score;
          bestIndex = c;
        }
      }
      if (bestIndex != 0 && bestIndex != previous) {
        text.write(characters[bestIndex]);
        confidence += bestScore;
        selected++;
      }
      previous = bestIndex;
    }
    timings?.record('rec.ctc_decode', decodeStart!, {'timeSteps': timeSteps, 'classes': classes});
    return _RecognizedLine(
      text.toString(),
      selected == 0 ? 0 : confidence / selected,
    );
  }

  Future<List<String>> _loadCharacters(String path) async {
    final List<String> dictionary = await File(path).readAsLines();
    return <String>['blank', ...dictionary, ' '];
  }

  /// Batch [C, H, W] normalization for recognition: every crop resized to
  /// height 48 at its own aspect-preserving width, then right-padded to
  /// [targetWidth] so the batch shares one dynamic-width input tensor.
  Float32List _normalizedBatchNchw(List<RgbaRaster> crops, int targetWidth) {
    const int targetHeight = 48;
    final int pixels = targetHeight * targetWidth;
    final Float32List output = Float32List(crops.length * 3 * pixels);
    for (int b = 0; b < crops.length; b++) {
      final RgbaRaster crop = crops[b];
      final double ratio = crop.width / math.max(1, crop.height);
      crop.writeResizedNchw(
        output,
        targetWidth: math.min(
          targetWidth,
          math.max(1, (targetHeight * ratio).ceil()),
        ),
        targetHeight: targetHeight,
        rowStride: targetWidth,
        planeSize: pixels,
        start: b * 3 * pixels,
        scale: 2,
        offset: -1,
      );
    }
    return output;
  }

  Future<List<dynamic>> _runSingleOutput(
    ort.OrtSession session,
    Float32List input,
    List<int> shape,
    InferenceCancellationToken token, {
    required int expectedRank,
    int? expectedChannels,
  }) async =>
      (await _runOutput(
        session,
        input,
        shape,
        token,
        expectedRank: expectedRank,
        expectedChannels: expectedChannels,
      )).values;

  Future<_TensorOutput> _runOutput(
    ort.OrtSession session,
    Float32List input,
    List<int> shape,
    InferenceCancellationToken token, {
    required int expectedRank,
    int? expectedChannels,
  }) async {
    token.throwIfCancelled();
    final String role = _sessionRoles[session.id] ?? 'unknown';
    final int? tensorStart = timings?.now;
    final ort.OrtValue tensor = await ort.OrtValue.fromList(input, shape);
    timings?.record('$role.tensor_upload', tensorStart!, {'shape': shape.join('x')});
    Map<String, ort.OrtValue>? outputs;
    try {
      final String inputName = session.inputNames.first;
      final int? runStart = timings?.now;
      outputs = await runtime.run(session, <String, ort.OrtValue>{
        inputName: tensor,
      });
      timings?.record('$role.native_run', runStart!);
      token.throwIfCancelled();
      final ort.OrtValue output = outputs[session.outputNames.first]!;
      if (output.shape.length != expectedRank ||
          output.shape.any((int dimension) => dimension <= 0) ||
          (expectedChannels != null && output.shape[1] != expectedChannels)) {
        throw StateError('unexpected ONNX output shape: ${output.shape}');
      }
      final int elements = output.shape.fold<int>(
        1,
        (int product, int dimension) => product * dimension,
      );
      if (elements > 64 * 1024 * 1024) {
        throw StateError('OCR output exceeds tensor budget');
      }
      final int? readStart = timings?.now;
      final List<dynamic> values = await output.asFlattenedList();
      timings?.record('$role.tensor_download', readStart!, {'elements': elements, 'shape': output.shape.join('x')});
      if (values.length != elements) {
        throw StateError('ONNX output data/shape mismatch');
      }
      return _TensorOutput(output.shape, values);
    } finally {
      if (outputs != null) {
        for (final ort.OrtValue output in outputs.values) {
          await output.dispose();
        }
      }
      await tensor.dispose();
    }
  }
}

class _TensorOutput {
  const _TensorOutput(this.shape, this.values);

  final List<int> shape;
  final List<dynamic> values;
}

class _DetectedBox {
  const _DetectedBox(this.rect, this.detectionScore);

  /// The unclipped minimal-area oriented rect in original image coordinates.
  final OrientedRect rect;
  final double detectionScore;
}

class _RecognizedLine {
  const _RecognizedLine(this.text, this.confidence);

  final String text;
  final double confidence;
}

class _RecognizedCandidate {
  const _RecognizedCandidate(this.box, this.line);

  final _DetectedBox box;
  final _RecognizedLine line;
}

class _VerticalMargin {
  const _VerticalMargin({required this.left, required this.width});

  final int left;
  final int width;
}

/// Straigtens a detected text box into an axis-aligned crop by rotating its
/// enclosing region around the box center so the text direction becomes
/// horizontal, then cropping the inner box. Slanted text that an axis-aligned
/// crop would feed to the recognizer on a tilt now arrives upright.
RgbaRaster? straightenOcrCrop(RgbaRaster source, OrientedRect rect) =>
    perspectiveStraightenOcrCrop(source, rect.corners);
