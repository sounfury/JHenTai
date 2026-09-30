import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:image/image.dart' as img;
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/inference/inference_safety.dart';
import 'package:jhentai/src/service/inference/inference_task.dart';
import 'package:jhentai/src/service/inference/inpainting_inference_engine.dart';
import 'package:jhentai/src/service/inference/onnx_runtime.dart';

class _Runtime extends OnnxRuntime {
  _Runtime() : super(log: noopOnnxRuntimeLog);
  final List<ort.OrtProvider> attempts = [];
  bool failGpu = true;
  int invalidations = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<ort.OrtSession?> session(
    String modelPath, {
    required String modelFingerprint,
    required List<ort.OrtProvider> providers,
    InferenceSessionSafetyConfig? safetyConfig,
    int? intraOpNumThreads,
    int? interOpNumThreads,
  }) async => ort.OrtSession.fromMap({'sessionId': providers.first.name});

  @override
  Future<Map<String, ort.OrtValue>> run(
    ort.OrtSession session,
    Map<String, ort.OrtValue> inputs,
  ) async {
    final provider = ort.OrtProvider.values.byName(session.id);
    attempts.add(provider);
    if (provider != ort.OrtProvider.CPU && failGpu) {
      throw PlatformException(code: 'ORT_ERROR', message: 'E_INVALIDARG');
    }
    return {
      'result': ort.OrtValue.fromMap({
        'valueId': 'result',
        'dataType': 'float32',
        'shape': inputs['image']!.shape,
      }),
    };
  }

  @override
  Future<T> withPathsInvalidated<T>(
    Iterable<String> paths,
    Future<T> Function() operation,
  ) {
    invalidations++;
    return operation();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Runtime runtime;
  late LamaOnnxInpaintingInferenceEngine engine;
  late String input;
  int tensors = 0;
  int releases = 0;
  final masks = [
    const PolygonMask(
      points: [
        EnginePoint(x: 18, y: 18),
        EnginePoint(x: 30, y: 18),
        EnginePoint(x: 30, y: 32),
        EnginePoint(x: 18, y: 32),
      ],
    ),
  ];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lama-test-');
    input = '${directory.path}/source.png';
    final image = img.Image(width: 128, height: 128);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    // These existing tests exercise native inference/fallback. Use textured
    // context so the flat-background fast path does not bypass that boundary.
    for (int y = 15; y <= 35; y++) {
      for (int x = 15; x <= 33; x++) {
        final shade = 210 + (x % 5) * 10;
        image.setPixelRgb(x, y, shade, shade, shade);
      }
    }
    img.fillRect(
      image,
      x1: 22,
      y1: 22,
      x2: 24,
      y2: 28,
      color: img.ColorRgb8(0, 0, 0),
    );
    await File(input).writeAsBytes(img.encodePng(image));
    runtime = _Runtime();
    engine = LamaOnnxInpaintingInferenceEngine(
      runtime: runtime,
      // CUDA skips the pinned DirectML graph converter while exercising the
      // same create-success / run-failure fallback boundary.
      providerResolver: () => [ort.OrtProvider.CUDA, ort.OrtProvider.CPU],
      modelResolver:
          () => LamaOnnxModelInfo(modelPath: input, fingerprint: 'test'),
    );
    tensors = releases = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_onnxruntime'), (
          call,
        ) async {
          final args = call.arguments as Map;
          switch (call.method) {
            case 'createOrtValue':
              return {
                'valueId': 'input${tensors++}',
                'dataType': 'float32',
                'shape': args['shape'],
              };
            case 'getOrtValueData':
              return {
                'data': Float32List(3 * 128 * 128)
                  ..fillRange(0, 3 * 128 * 128, 0.5),
              };
            case 'releaseOrtValue':
              releases++;
              return null;
            default:
              throw StateError(call.method);
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_onnxruntime'),
          null,
        );
    await directory.delete(recursive: true);
  });

  test(
    'run failure falls back once and later pages avoid failed GPU',
    () async {
      for (int page = 0; page < 2; page++) {
        final output = '${directory.path}/repaired$page.png';
        await engine.inpaint(
          inputPath: input,
          outputPath: output,
          polygonMasks: masks,
        );
        final repaired = img.decodePng(await File(output).readAsBytes())!;
        expect(repaired.getPixel(0, 0).r, 255);
        expect(repaired.getPixel(23, 25).r, closeTo(128, 1));
      }
      expect(runtime.attempts, [
        ort.OrtProvider.CUDA,
        ort.OrtProvider.CPU,
        ort.OrtProvider.CPU,
      ]);
      expect(runtime.invalidations, 1);
      expect(releases, 6);
    },
  );

  test('successful accelerator does not retry CPU', () async {
    runtime.failGpu = false;
    await engine.inpaint(
      inputPath: input,
      outputPath: '${directory.path}/gpu.png',
      polygonMasks: masks,
    );
    expect(runtime.attempts, [ort.OrtProvider.CUDA]);
    expect(releases, 3);
  });

  test(
    'cancellation during background preprocessing prevents inference and publication',
    () async {
      final token = InferenceCancellationToken();
      final output = '${directory.path}/cancelled.png';
      await expectLater(
        engine.inpaint(
          inputPath: input,
          outputPath: output,
          polygonMasks: masks,
          cancellationToken: token,
          onProgress: (_) => token.cancel(),
        ),
        throwsA(isA<InferenceCancelledException>()),
      );
      expect(runtime.attempts, isEmpty);
      expect(await File(output).exists(), isFalse);
      expect(releases, tensors);
    },
  );
}
