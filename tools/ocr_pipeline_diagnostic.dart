// Build with Flutter Windows --release -t tools/ocr_pipeline_diagnostic.dart.
// Run: jhentai.exe <image> <onnx-model-directory> <report.json> [cpu|directml]
// This headless entrypoint never initializes account/network services or sends
// translations. It uses production inference and pixel/layout implementations.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_translation/onomatopoeia_filter.dart';
import 'package:jhentai/src/service/image_translation_service.dart'
    show containersFromBubbleDetection, isBlockInsideAnyRegion;
import 'package:jhentai/src/service/inference/bubble_segmentation_inference_engine.dart';
import 'package:jhentai/src/service/inference/inference_safety.dart';
import 'package:jhentai/src/service/inference/inference_task.dart';
import 'package:jhentai/src/service/inference/inference_timings.dart';
import 'package:jhentai/src/service/inference/onnx_ocr_engine.dart';
import 'package:jhentai/src/service/inference/onnx_runtime.dart';
import 'package:jhentai/src/utils/connected_bubble_layout.dart';
import 'package:jhentai/src/utils/image_text_container_detection.dart';
import 'package:jhentai/src/utils/image_translation_colors.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.length < 3) {
    exit(2);
  }
  final report = File(args[2]);
  final runs = <Map<String, Object>>[];
  final runtime = OnnxRuntime(log: noopOnnxRuntimeLog);
  try {
    await runtime.initialize();
    final backend = args.length > 3 ? args[3] : 'directml';
    final providers = [
      if (backend == 'directml') ort.OrtProvider.DIRECT_ML,
      ort.OrtProvider.CPU,
    ];
    final root = args[1];
    final ocrRoot = '$root/rapidocr-ppocrv6-small-multilingual';
    for (int run = 0; run < 3; run++) {
      final timings = InferenceTimings();
      final start = timings.now;
      final bytes = await File(args[0]).readAsBytes();
      await compute(_hash, bytes);
      timings.record('pipeline.read_hash', start);
      final bubble = BubbleSegmentationInferenceEngine(
        runtime: runtime,
        providerResolver: () => providers,
        timings: timings,
        modelResolver:
            () => BubbleSegmentationModelInfo(
              modelPath: '$root/manga109-segmentation-bubble-onnx/best.onnx',
              fingerprint: 'diagnostic-bubble',
            ),
      );
      final bubbleStart = timings.now;
      final DetectionResult detection = await bubble.detect(
        args[0],
        cancellationToken: InferenceCancellationToken(),
      );
      timings.record('pipeline.bubble_total', bubbleStart, {
        'regions': detection.regions.length,
      });
      final engine = OnnxOcrInferenceEngine(
        runtime: runtime,
        providerResolver: () => providers,
        timings: timings,
        safetyConfig: InferenceProviderPolicy.sessionConfig(
          backend: backend,
          maxInputPixels: 6 * 1024 * 1024,
          memoryBudgetBytes: 256 * 1024 * 1024,
        ),
        model: OnnxOcrModelInfo(
          detPath: '$ocrRoot/PP-OCRv6_det_small.onnx',
          clsPath: '$ocrRoot/ch_ppocr_mobile_v2.0_cls_mobile.onnx',
          recPath: '$ocrRoot/PP-OCRv6_rec_small.onnx',
          dictPath: '$ocrRoot/ppocrv6_dict.txt',
          fingerprint: 'diagnostic-ocr',
        ),
      );
      final ocrStart = timings.now;
      final recognized = await engine.recognize(args[0]);
      timings.record('pipeline.ocr_total', ocrStart, {
        'blocks': recognized.blocks.length,
      });
      final colorStart = timings.now;
      var blocks = await compute(detectTranslationColors, <String, dynamic>{
        'bytes': bytes,
        'blocks': recognized.blocks,
        'width': recognized.imageWidth!,
        'height': recognized.imageHeight!,
      });
      timings.record('pipeline.colors', colorStart);
      final layoutStart = timings.now;
      blocks =
          blocks
              .where(
                (block) =>
                    !isOnomatopoeia(
                      block.text,
                      insideBubble: isBlockInsideAnyRegion(
                        block,
                        detection.regions,
                      ),
                    ),
              )
              .toList();
      var containers = containersFromBubbleDetection(
        blocks,
        detection,
        imageWidth: recognized.imageWidth!,
        imageHeight: recognized.imageHeight!,
      );
      if (containers.isEmpty && blocks.length >= 2) {
        final raw = await compute(
          detectTextContainersFromBytes,
          <String, dynamic>{
            'bytes': bytes,
            'blocks': blocks.map((b) => b.toJson()).toList(),
          },
        );
        containers = raw.map(RecognizedTextContainer.fromJson).toList();
      }
      final refined = await compute(
        refineBubbleLayoutsFromBytes,
        <String, dynamic>{
          'bytes': bytes,
          'containers': containers.map((c) => c.toJson()).toList(),
        },
      );
      timings.record('pipeline.layout', layoutStart, {
        'containers': refined.length,
      });
      timings.record('pipeline.total', start);
      runs.add({
        'run': run,
        'backend': backend,
        'mode': kReleaseMode ? 'release' : 'non-release',
        ...timings.toJson(),
      });
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'runtime': runtime.runtimeVersion,
          'availableProviders':
              runtime.availableProviders.map((p) => p.name).toList(),
          'runs': runs,
        }),
        flush: true,
      );
    }
    await runtime.dispose();
    exit(0);
  } catch (error, stack) {
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'error': error.toString(),
        'stack': stack.toString(),
        'runs': runs,
      }),
      flush: true,
    );
    exit(1);
  }
}

String _hash(Uint8List bytes) => sha256.convert(bytes).toString();
