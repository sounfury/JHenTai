import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:image/image.dart' as image;

import '../engine/engine_contract.dart';
import '../log.dart';
import '../../utils/inpainting_pixels.dart';
import 'inference_exception.dart';
import 'inference_safety.dart';
import 'inference_task.dart';
import 'onnx_ocr_engine.dart' show OnnxProviderResolver;
import 'onnx_runtime.dart';
import 'lama_directml_model.dart';

void _logLamaTiming(String message) {
  unawaited(log.info(message).catchError((Object _) {}));
}

abstract class InpaintingInferenceEngine {
  String get displayName;
  bool get isReady;

  Future<void> inpaint({
    required String inputPath,
    required String outputPath,
    required List<PolygonMask> polygonMasks,
    InferenceCancellationToken? cancellationToken,
    void Function(double progress)? onProgress,
  });
}

class LamaOnnxModelInfo {
  const LamaOnnxModelInfo({required this.modelPath, required this.fingerprint});

  final String? modelPath;
  final String fingerprint;
}

/// LaMa Large uses normalized float RGB and a binary mask (1 = repair).
/// Refine source glyphs before inference and composite only repaired pixels.
class LamaOnnxInpaintingInferenceEngine implements InpaintingInferenceEngine {
  LamaOnnxInpaintingInferenceEngine({
    required this.runtime,
    required this.providerResolver,
    required this.modelResolver,
    this.safetyConfig,
  });

  final OnnxRuntime runtime;
  final OnnxProviderResolver providerResolver;
  final LamaOnnxModelInfo Function() modelResolver;
  final InferenceSessionSafetyConfig? safetyConfig;

  final InferenceTaskQueue _queue = InferenceTaskQueue();
  final Map<String, Future<String>> _directMlModels = {};
  final Set<String> _failedAccelerators = {};

  static const String modelId = 'lama-large-512px';
  static const int _maxInputBytes = 80 * 1024 * 1024;

  @override
  String get displayName => 'ONNX · LaMa Large';

  LamaOnnxModelInfo get _model => modelResolver();

  @override
  bool get isReady {
    try {
      final LamaOnnxModelInfo model = _model;
      final String? path = model.modelPath;
      return runtime.isAvailable &&
          providerResolver().isNotEmpty &&
          model.fingerprint.isNotEmpty &&
          path != null &&
          File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> inpaint({
    required String inputPath,
    required String outputPath,
    required List<PolygonMask> polygonMasks,
    InferenceCancellationToken? cancellationToken,
    void Function(double progress)? onProgress,
  }) {
    final Stopwatch queueClock = Stopwatch()..start();
    return _queue.run(() {
      _logLamaTiming(
        '[背景融合/LaMa] queue_wait=${_ms(queueClock.elapsedMicroseconds)}ms '
        'masks=${polygonMasks.length}',
      );
      return _inpaint(
        inputPath: inputPath,
        outputPath: outputPath,
        polygonMasks: polygonMasks,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      );
    });
  }

  Future<void> _inpaint({
    required String inputPath,
    required String outputPath,
    required List<PolygonMask> polygonMasks,
    InferenceCancellationToken? cancellationToken,
    void Function(double progress)? onProgress,
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    int stageStart = clock.elapsedMicroseconds;
    bool completed = false;
    try {
      final InferenceCancellationToken token =
          cancellationToken ?? InferenceCancellationToken();
      token.throwIfCancelled();
      if (polygonMasks.isEmpty ||
          polygonMasks.any((PolygonMask mask) => !mask.isValid)) {
        throw StateError('inpainting requires valid polygon masks');
      }
      if (!isReady) {
        throw const InferenceNotReadyException(modelId);
      }

      final LamaOnnxModelInfo model = _model;
      final File inputFile = File(inputPath);
      if (!await inputFile.exists() ||
          await inputFile.length() > _maxInputBytes) {
        throw StateError('inpainting input is missing or exceeds 80 MiB');
      }
      _logStage('validate', clock, stageStart);

      // Pure pixel work must not occupy the Flutter UI isolate.
      stageStart = clock.elapsedMicroseconds;
      final _PreparedRepair repair = await compute(
        _prepareRepair,
        _RepairRequest(inputPath, polygonMasks),
      );
      _logStage(
        'preprocess',
        clock,
        stageStart,
        'image=${repair.source.width}x${repair.source.height} '
            'tensor=${repair.input == null ? 'none' : '${repair.input!.width}x${repair.input!.height}'} '
            'flat_pixels=${repair.flatPixels}',
      );
      for (final MapEntry<String, double> entry in repair.timingsMs.entries) {
        _logLamaTiming(
          '[背景融合/LaMa] preprocess.${entry.key}=${entry.value.toStringAsFixed(1)}ms',
        );
      }
      final LamaInput? modelInput = repair.input;
      token.throwIfCancelled();
      onProgress?.call(0.12);
      token.throwIfCancelled();
      if (modelInput == null) {
        final png = await compute(_encodeFlatRepair, repair.source);
        await _writeAtomically(outputPath, png, token);
        _logLamaTiming(
          '[背景融合/LaMa] flat_fill=${repair.flatPixels} pixels; model skipped',
        );
        onProgress?.call(1);
        completed = true;
        return;
      }
      final LamaInput prepared = modelInput;

      final int pixels = prepared.width * prepared.height;
      stageStart = clock.elapsedMicroseconds;
      final ort.OrtValue imageTensor = await ort.OrtValue.fromList(
        prepared.rgb,
        <int>[1, 3, prepared.height, prepared.width],
      );
      ort.OrtValue? maskTensor;
      Map<String, ort.OrtValue>? outputs;
      try {
        maskTensor = await ort.OrtValue.fromList(prepared.mask, <int>[
          1,
          1,
          prepared.height,
          prepared.width,
        ]);
        _logStage('tensor_upload', clock, stageStart);
        token.throwIfCancelled();
        onProgress?.call(0.25);
        outputs = await _runModel(model, <String, ort.OrtValue>{
          'image': imageTensor,
          'mask': maskTensor,
        }, token);
        token.throwIfCancelled();
        onProgress?.call(0.82);
        final ort.OrtValue? result =
            outputs['result'] ??
            (outputs.length == 1 ? outputs.values.first : null);
        if (result == null ||
            result.shape.length != 4 ||
            result.shape[0] != 1 ||
            result.shape[1] != 3 ||
            result.shape[2] != prepared.height ||
            result.shape[3] != prepared.width) {
          throw StateError(
            'unexpected LaMa Large output shape: ${result?.shape}',
          );
        }
        stageStart = clock.elapsedMicroseconds;
        final List<dynamic> values = await result.asFlattenedList();
        _logStage('tensor_download', clock, stageStart);
        if (values.length != pixels * 3) {
          throw StateError('LaMa Large output data/shape mismatch');
        }
        stageStart = clock.elapsedMicroseconds;
        final _FinishedRepair finished = await compute(
          _finishRepair,
          _RepairOutput(repair, values),
        );
        _logStage(
          'postprocess',
          clock,
          stageStart,
          'png_bytes=${finished.png.length}',
        );
        for (final MapEntry<String, double> entry
            in finished.timingsMs.entries) {
          _logLamaTiming(
            '[背景融合/LaMa] postprocess.${entry.key}=${entry.value.toStringAsFixed(1)}ms',
          );
        }
        token.throwIfCancelled();
        stageStart = clock.elapsedMicroseconds;
        await _writeAtomically(outputPath, finished.png, token);
        _logStage('write', clock, stageStart);
        onProgress?.call(1);
        completed = true;
      } finally {
        if (outputs != null) {
          for (final ort.OrtValue output in outputs.values) {
            await output.dispose();
          }
        }
        await imageTensor.dispose();
        await maskTensor?.dispose();
      }
    } finally {
      _logLamaTiming(
        '[背景融合/LaMa] total=${_ms(clock.elapsedMicroseconds)}ms '
        'status=${completed ? 'success' : 'interrupted_or_failed'}',
      );
    }
  }

  static String _ms(int microseconds) =>
      (microseconds / 1000).toStringAsFixed(1);

  static void _logStage(
    String stage,
    Stopwatch clock,
    int since, [
    String details = '',
  ]) {
    _logLamaTiming(
      '[背景融合/LaMa] $stage=${_ms(clock.elapsedMicroseconds - since)}ms'
      '${details.isEmpty ? '' : ' $details'}',
    );
  }

  Future<Map<String, ort.OrtValue>> _runModel(
    LamaOnnxModelInfo model,
    Map<String, ort.OrtValue> inputs,
    InferenceCancellationToken token,
  ) async {
    final List<ort.OrtProvider> providers = providerResolver();
    final String key =
        '${model.modelPath}|${model.fingerprint}|${providers.join(',')}';
    final bool accelerated =
        providers.isNotEmpty &&
        providers.first != ort.OrtProvider.CPU &&
        !_failedAccelerators.contains(key);
    if (accelerated) {
      String? acceleratedPath;
      try {
        final Stopwatch modelClock = Stopwatch()..start();
        acceleratedPath =
            providers.contains(ort.OrtProvider.DIRECT_ML)
                ? await (_directMlModels[key] ??= compute(
                  prepareLamaDirectMlModel,
                  model.modelPath!,
                ))
                : model.modelPath!;
        _logLamaTiming(
          '[背景融合/LaMa] accelerated_model_prepare='
          '${_ms(modelClock.elapsedMicroseconds)}ms provider=${providers.first.name}',
        );
        token.throwIfCancelled();
        final Stopwatch sessionClock = Stopwatch()..start();
        final session = await runtime.session(
          acceleratedPath,
          modelFingerprint: '${model.fingerprint}|dml-rank4-v1',
          providers: providers,
          safetyConfig: safetyConfig,
          intraOpNumThreads: 2,
          interOpNumThreads: 1,
        );
        _logLamaTiming(
          '[背景融合/LaMa] session=${_ms(sessionClock.elapsedMicroseconds)}ms '
          'provider=${providers.first.name}',
        );
        if (session == null) {
          throw const InferenceNotReadyException(modelId);
        }
        token.throwIfCancelled();
        final Stopwatch runClock = Stopwatch()..start();
        try {
          return await runtime.run(session, inputs);
        } finally {
          _logLamaTiming(
            '[背景融合/LaMa] native_run=${_ms(runClock.elapsedMicroseconds)}ms '
            'provider=${providers.first.name}',
          );
        }
      } on InferenceCancelledException {
        rethrow;
      } catch (error) {
        if (!providers.contains(ort.OrtProvider.CPU)) {
          rethrow;
        }
        _failedAccelerators.add(key);
        runtime.reportProviderFallback(model.modelPath!, error);
        if (acceleratedPath != null) {
          await runtime.withPathsInvalidated([acceleratedPath], () async {});
        }
      }
    }
    token.throwIfCancelled();
    final Stopwatch sessionClock = Stopwatch()..start();
    final session = await runtime.session(
      model.modelPath!,
      modelFingerprint: model.fingerprint,
      providers: const [ort.OrtProvider.CPU],
      safetyConfig: safetyConfig,
      intraOpNumThreads: 2,
      interOpNumThreads: 1,
    );
    _logLamaTiming(
      '[背景融合/LaMa] session=${_ms(sessionClock.elapsedMicroseconds)}ms provider=CPU',
    );
    if (session == null) {
      throw const InferenceNotReadyException(modelId);
    }
    token.throwIfCancelled();
    final Stopwatch runClock = Stopwatch()..start();
    try {
      return await runtime.run(session, inputs);
    } finally {
      _logLamaTiming(
        '[背景融合/LaMa] native_run=${_ms(runClock.elapsedMicroseconds)}ms provider=CPU',
      );
    }
  }

  static _PreparedRepair _prepareRepair(_RepairRequest request) {
    final Stopwatch clock = Stopwatch()..start();
    final Map<String, double> timingsMs = {};
    int stageStart = clock.elapsedMicroseconds;
    final Uint8List encoded = File(request.inputPath).readAsBytesSync();
    final image.Image? decoded = image.decodeImage(encoded);
    if (decoded == null) {
      throw StateError('unsupported inpainting image');
    }
    final image.Image source = image.bakeOrientation(decoded);
    timingsMs['decode'] = (clock.elapsedMicroseconds - stageStart) / 1000;
    final int maxPixels =
        Platform.isAndroid || Platform.isIOS
            ? 12 * 1024 * 1024
            : 24 * 1024 * 1024;
    if (source.width * source.height > maxPixels) {
      throw StateError(
        'inpainting image ${source.width}x${source.height} exceeds the '
        '$maxPixels pixel budget',
      );
    }
    stageStart = clock.elapsedMicroseconds;
    final Uint8List coarseMask = _rasterizePolygonMask(
      source.width,
      source.height,
      request.polygons,
    );
    timingsMs['polygon_mask'] = (clock.elapsedMicroseconds - stageStart) / 1000;
    stageStart = clock.elapsedMicroseconds;
    final Uint8List mask = refineInpaintingMask(source, coarseMask);
    timingsMs['mask_refine'] = (clock.elapsedMicroseconds - stageStart) / 1000;
    if (!mask.contains(0)) {
      throw StateError('no text pixels remain after mask refinement');
    }
    stageStart = clock.elapsedMicroseconds;
    final flat = repairFlatInpaintingRegions(source, mask);
    timingsMs['flat_fill'] = (clock.elapsedMicroseconds - stageStart) / 1000;
    if (!flat.remainingMask.contains(0)) {
      return _PreparedRepair(
        flat.image,
        flat.remainingMask,
        null,
        timingsMs,
        flat.repairedPixels,
      );
    }
    // Bound feature-map memory independently of the execution provider.
    stageStart = clock.elapsedMicroseconds;
    final LamaInput prepared = prepareLamaInput(
      flat.image,
      flat.remainingMask,
      maxSide:
          Platform.isAndroid || Platform.isIOS || Platform.isWindows
              ? 1024
              : 2048,
    );
    timingsMs['resize_tensor'] =
        (clock.elapsedMicroseconds - stageStart) / 1000;
    return _PreparedRepair(
      flat.image,
      flat.remainingMask,
      prepared,
      timingsMs,
      flat.repairedPixels,
    );
  }

  static Uint8List _encodeFlatRepair(image.Image source) =>
      Uint8List.fromList(image.encodePng(source, level: 3));

  static _FinishedRepair _finishRepair(_RepairOutput request) {
    final Stopwatch clock = Stopwatch()..start();
    final LamaInput prepared = request.repair.input!;
    final image.Image predicted = _fromNchw(
      request.values,
      prepared.width,
      prepared.height,
    );
    final image.Image cropped = image.copyCrop(
      predicted,
      x: 0,
      y: 0,
      width: prepared.contentWidth,
      height: prepared.contentHeight,
    );
    final image.Image repaired = compositeLamaOutput(
      request.repair.source,
      request.repair.mask,
      cropped,
    );
    final double compositeMs = clock.elapsedMicroseconds / 1000;
    final Uint8List png = Uint8List.fromList(
      image.encodePng(repaired, level: 3),
    );
    return _FinishedRepair(png, {
      'composite': compositeMs,
      'png_encode': clock.elapsedMicroseconds / 1000 - compositeMs,
    });
  }

  static image.Image _fromNchw(List<dynamic> values, int width, int height) {
    final int plane = width * height;
    final image.Image result = image.Image(
      width: width,
      height: height,
      numChannels: 4,
    );
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int index = y * width + x;
        result.setPixelRgba(
          x,
          y,
          _clamp((values[index] as num) * 255),
          _clamp((values[plane + index] as num) * 255),
          _clamp((values[plane * 2 + index] as num) * 255),
          255,
        );
      }
    }
    return result;
  }

  static Uint8List _rasterizePolygonMask(
    int width,
    int height,
    List<PolygonMask> polygons,
  ) => rasterizeInpaintingMask(
    width,
    height,
    polygons.map(
      (polygon) =>
          polygon.points.map((p) => math.Point<double>(p.x, p.y)).toList(),
    ),
  );

  Future<void> _writeAtomically(
    String outputPath,
    List<int> bytes,
    InferenceCancellationToken token,
  ) async {
    final File destination = File(outputPath);
    final File temporary = File('$outputPath.lama.tmp');
    await destination.parent.create(recursive: true);
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      token.throwIfCancelled();
      if (await destination.exists()) {
        await destination.delete();
      }
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  static int _clamp(Object value) =>
      (value is num ? value.toDouble() : 0).round().clamp(0, 255);
}

class _RepairRequest {
  const _RepairRequest(this.inputPath, this.polygons);
  final String inputPath;
  final List<PolygonMask> polygons;
}

class _PreparedRepair {
  const _PreparedRepair(
    this.source,
    this.mask,
    this.input,
    this.timingsMs,
    this.flatPixels,
  );
  final image.Image source;
  final Uint8List mask;
  final LamaInput? input;
  final int flatPixels;
  final Map<String, double> timingsMs;
}

class _RepairOutput {
  const _RepairOutput(this.repair, this.values);
  final _PreparedRepair repair;
  final List<dynamic> values;
}

class _FinishedRepair {
  const _FinishedRepair(this.png, this.timingsMs);
  final Uint8List png;
  final Map<String, double> timingsMs;
}
