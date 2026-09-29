// Build with Flutter Windows --release -t tools/ocr_pipeline_diagnostic.dart.
// Run: jhentai.exe <image> <onnx-model-directory> <report.json> [cpu|directml]
// This headless entrypoint never initializes account/network services or sends
// translations. It uses production inference and pixel/layout implementations.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
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
import 'package:jhentai/src/utils/rgba_raster.dart';
import 'package:jhentai/src/utils/bubble_detection_refinement.dart';
import 'package:jhentai/src/utils/ocr_artifact_filter.dart';
import 'package:jhentai/src/utils/sound_effect_style.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';

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
    final iterations = args.length > 4 ? int.parse(args[4]) : 3;
    for (int run = 0; run < iterations; run++) {
      final timings = InferenceTimings();
      final start = timings.now;
      final bytes = await File(args[0]).readAsBytes();
      await compute(_hash, bytes);
      timings.record('pipeline.read_hash', start);
      final decodeStart = timings.now;
      final RgbaRaster? page = await compute(_decode, bytes);
      timings.record('pipeline.decode', decodeStart);
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
      // Bubble detection and OCR run concurrently, as in the service.
      final bubbleStart = timings.now;
      final Future<DetectionResult> pendingDetection = bubble
          .detect(
            args[0],
            image: page,
            cancellationToken: InferenceCancellationToken(),
          )
          .then((DetectionResult detection) {
            timings.record('pipeline.bubble_total', bubbleStart, {
              'regions': detection.regions.length,
            });
            return detection;
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
      final recognized = await engine.recognize(args[0], image: page);
      timings.record('pipeline.ocr_total', ocrStart, {
        'blocks': recognized.blocks.length,
      });
      DetectionResult detection = await pendingDetection;
      final pagePayload = <String, dynamic>{'image': page};
      final colorStart = timings.now;
      var blocks = await compute(detectTranslationColors, <String, dynamic>{
        ...pagePayload,
        'blocks': recognized.blocks,
        'width': recognized.imageWidth!,
        'height': recognized.imageHeight!,
      });
      timings.record('pipeline.colors', colorStart);
      final layoutStart = timings.now;
      blocks = mergeOverlappingOcrArtifacts(blocks);
      final originalDetection = detection;
      if (page != null) {
        detection = await refineBubbleDetection(
          source: page,
          initial: detection,
          blocks: blocks,
          detect:
              (crop) => bubble.detect(
                args[0],
                image: crop,
                cancellationToken: InferenceCancellationToken(),
              ),
          isCanceled: () => false,
        );
      }
      final unfilteredBlocks = blocks;
      final styledEffects =
          page == null
              ? <RecognizedTextBlock>{}
              : {
                for (final i in styleMatchedSoundEffects(
                  page,
                  blocks,
                  detection.regions,
                ))
                  blocks[i],
              };
      blocks =
          blocks
              .where(
                (block) =>
                    !shouldPreserveSoundEffect(
                      block.text,
                      insideBubble: isBlockInsideAnyRegion(
                        block,
                        detection.regions,
                      ),
                      confidence: block.confidence,
                      width: block.width,
                      height: block.height,
                      matchesSoundEffectStyle: styledEffects.contains(block),
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
            ...pagePayload,
            'blocks': blocks.map((b) => b.toJson()).toList(),
          },
        );
        containers = raw.map(RecognizedTextContainer.fromJson).toList();
      }
      final refined = await compute(
        refineBubbleLayoutsFromBytes,
        <String, dynamic>{
          ...pagePayload,
          'containers': containers.map((c) => c.toJson()).toList(),
        },
      );
      timings.record('pipeline.layout', layoutStart, {
        'containers': refined.length,
      });
      timings.record('pipeline.total', start);
      if (page != null) {
        final preview = page.toImage();
        for (final region in detection.regions) {
          final mask = region.bubbleInterior;
          if (mask == null) continue;
          for (
            int y = mask.bounds.top.floor();
            y < mask.bounds.bottom.ceil();
            y++
          ) {
            for (
              int x = mask.bounds.left.floor();
              x < mask.bounds.right.ceil();
              x++
            ) {
              if (x < 0 || y < 0 || x >= page.width || y >= page.height)
                continue;
              final mx = ((x - mask.bounds.left) *
                      mask.width /
                      mask.bounds.width)
                  .floor()
                  .clamp(0, mask.width - 1);
              final my = ((y - mask.bounds.top) *
                      mask.height /
                      mask.bounds.height)
                  .floor()
                  .clamp(0, mask.height - 1);
              if (mask.pixels[my * mask.width + mx] == 0) continue;
              final p = preview.getPixel(x, y);
              preview.setPixelRgb(
                x,
                y,
                (p.r * .7).round(),
                (p.g * .7 + 76).round(),
                (p.b * .7).round(),
              );
            }
          }
        }
        final resolved = refined.map(RecognizedTextContainer.fromJson).toList();
        for (final group in translationTextGroups(
          blocks,
          containers: resolved,
        )) {
          var areas = layoutRegionsForRecognizedTextGroup(
            group,
            resolved,
            blocks: blocks,
          );
          if (areas.isEmpty) {
            areas = [
              TranslationLayoutRegion(
                group.left,
                group.top,
                group.width,
                group.height,
              ),
            ];
          }
          for (final area in areas) {
            img.drawRect(
              preview,
              x1: area.left.round(),
              y1: area.top.round(),
              x2: (area.left + area.width).round(),
              y2: (area.top + area.height).round(),
              color: img.ColorRgb8(255, 0, 0),
              thickness: 2,
            );
          }
        }
        await File('${report.path}.png').writeAsBytes(img.encodePng(preview));
      }
      runs.add({
        'run': run,
        'backend': backend,
        'mode': kReleaseMode ? 'release' : 'non-release',
        ...timings.toJson(),
        // Output fingerprint for before/after parity checks of pixel code.
        'result': {
          'initialRegions': originalDetection.regions.length,
          'allOcrBlocks': unfilteredBlocks.map((b) => b.toJson()).toList(),
          'regions':
              detection.regions
                  .map(
                    (r) => {
                      'box': [r.left, r.top, r.width, r.height],
                      'confidence': r.confidence,
                      'maskWidth': r.bubbleInterior?.width,
                      'maskHeight': r.bubbleInterior?.height,
                      if (r.bubbleInterior != null)
                        'maskPixels': base64Encode(r.bubbleInterior!.pixels),
                    },
                  )
                  .toList(),
          'blocks': blocks.map((b) => b.toJson()).toList(),
          'containers': refined,
        },
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

RgbaRaster? _decode(Uint8List bytes) => RgbaRaster.decode(bytes);
