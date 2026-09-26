import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:image/image.dart' as image;

import '../engine/engine_contract.dart';
import '../../utils/inpainting_pixels.dart';
import 'inference_exception.dart';
import 'inference_safety.dart';
import 'inference_task.dart';
import 'onnx_ocr_engine.dart' show OnnxProviderResolver;
import 'onnx_runtime.dart';
import 'lama_directml_model.dart';

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
  }) => _queue.run(
    () => _inpaint(
      inputPath: inputPath,
      outputPath: outputPath,
      polygonMasks: polygonMasks,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    ),
  );

  Future<void> _inpaint({
    required String inputPath,
    required String outputPath,
    required List<PolygonMask> polygonMasks,
    InferenceCancellationToken? cancellationToken,
    void Function(double progress)? onProgress,
  }) async {
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

    // Pure pixel work must not occupy the Flutter UI isolate.
    final _PreparedRepair repair = await compute(
      _prepareRepair,
      _RepairRequest(inputPath, polygonMasks),
    );
    final LamaInput prepared = repair.input;
    token.throwIfCancelled();
    onProgress?.call(0.12);

    final int pixels = prepared.width * prepared.height;
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
      final List<dynamic> values = await result.asFlattenedList();
      if (values.length != pixels * 3) {
        throw StateError('LaMa Large output data/shape mismatch');
      }
      final Uint8List png = await compute(
        _finishRepair,
        _RepairOutput(repair, values),
      );
      token.throwIfCancelled();
      await _writeAtomically(outputPath, png, token);
      onProgress?.call(1);
    } finally {
      if (outputs != null) {
        for (final ort.OrtValue output in outputs.values) {
          await output.dispose();
        }
      }
      await imageTensor.dispose();
      await maskTensor?.dispose();
    }
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
        acceleratedPath =
            providers.contains(ort.OrtProvider.DIRECT_ML)
                ? await (_directMlModels[key] ??= compute(
                  prepareLamaDirectMlModel,
                  model.modelPath!,
                ))
                : model.modelPath!;
        token.throwIfCancelled();
        final session = await runtime.session(
          acceleratedPath,
          modelFingerprint: '${model.fingerprint}|dml-rank4-v1',
          providers: providers,
          safetyConfig: safetyConfig,
          intraOpNumThreads: 2,
          interOpNumThreads: 1,
        );
        if (session == null) {
          throw const InferenceNotReadyException(modelId);
        }
        token.throwIfCancelled();
        return await runtime.run(session, inputs);
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
    final session = await runtime.session(
      model.modelPath!,
      modelFingerprint: model.fingerprint,
      providers: const [ort.OrtProvider.CPU],
      safetyConfig: safetyConfig,
      intraOpNumThreads: 2,
      interOpNumThreads: 1,
    );
    if (session == null) {
      throw const InferenceNotReadyException(modelId);
    }
    token.throwIfCancelled();
    return runtime.run(session, inputs);
  }

  static _PreparedRepair _prepareRepair(_RepairRequest request) {
    final Uint8List encoded = File(request.inputPath).readAsBytesSync();
    final image.Image? decoded = image.decodeImage(encoded);
    if (decoded == null) {
      throw StateError('unsupported inpainting image');
    }
    final image.Image source = image.bakeOrientation(decoded);
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
    final Uint8List coarseMask = _rasterizePolygonMask(
      source.width,
      source.height,
      request.polygons,
    );
    final Uint8List mask = refineInpaintingMask(source, coarseMask);
    if (!mask.contains(0)) {
      throw StateError('no text pixels remain after mask refinement');
    }
    // Bound feature-map memory independently of the execution provider.
    final LamaInput prepared = prepareLamaInput(
      source,
      mask,
      maxSide:
          Platform.isAndroid || Platform.isIOS || Platform.isWindows
              ? 1024
              : 2048,
    );
    return _PreparedRepair(source, mask, prepared);
  }

  static Uint8List _finishRepair(_RepairOutput request) {
    final LamaInput prepared = request.repair.input;
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
    return Uint8List.fromList(image.encodePng(repaired, level: 3));
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
  ) {
    final Uint8List result = Uint8List.fromList(
      List<int>.filled(width * height, 255),
    );
    bool painted = false;
    for (final PolygonMask polygon in polygons) {
      final int left = math.max(0, polygon.left.floor());
      final int top = math.max(0, polygon.top.floor());
      final int right = math.min(width - 1, polygon.right.ceil());
      final int bottom = math.min(height - 1, polygon.bottom.ceil());
      for (int y = top; y <= bottom; y++) {
        for (int x = left; x <= right; x++) {
          if (_contains(polygon.points, x + 0.5, y + 0.5)) {
            result[y * width + x] = 0;
            painted = true;
          }
        }
      }
    }
    if (!painted) {
      throw StateError('polygon masks do not cover any source pixels');
    }
    return result;
  }

  static bool _contains(List<EnginePoint> points, double x, double y) {
    bool inside = false;
    for (
      int index = 0, previous = points.length - 1;
      index < points.length;
      previous = index++
    ) {
      final EnginePoint current = points[index];
      final EnginePoint prior = points[previous];
      final bool crosses = (current.y > y) != (prior.y > y);
      if (crosses &&
          x <
              (prior.x - current.x) * (y - current.y) / (prior.y - current.y) +
                  current.x) {
        inside = !inside;
      }
    }
    return inside;
  }

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
  const _PreparedRepair(this.source, this.mask, this.input);
  final image.Image source;
  final Uint8List mask;
  final LamaInput input;
}

class _RepairOutput {
  const _RepairOutput(this.repair, this.values);
  final _PreparedRepair repair;
  final List<dynamic> values;
}
