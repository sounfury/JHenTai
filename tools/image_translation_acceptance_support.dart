import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:image/image.dart' as img;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/service/inference/ctd_onnx_inference_engine.dart';
import 'package:jhentai/src/service/inference/inference_task.dart';
import 'package:jhentai/src/service/inference/inpainting_inference_engine.dart';
import 'package:jhentai/src/service/inference/onnx_ocr_engine.dart';
import 'package:jhentai/src/service/inference/onnx_runtime.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';
import 'package:jhentai/src/utils/ocr_artifact_filter.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';

Future<Map<String, dynamic>> runOcrArtifactCacheAcceptance({
  required String caseDirectory,
  required String modelRoot,
  required String outputDirectory,
  required OnnxRuntime runtime,
  required List<ort.OrtProvider> providers,
}) async {
  final pages =
      jsonDecode(
            await File('$caseDirectory/recorded_pages.json').readAsString(),
          )
          as List;
  final detector = CtdOnnxInferenceEngine(
    runtime: runtime,
    providerResolver: () => providers,
    modelResolver:
        () => CtdOnnxModelInfo(
          modelPath:
              '$modelRoot/comic-text-detector-beta-0.3/comictextdetector.pt.onnx',
          fingerprint: 'acceptance-ctd',
        ),
  );
  final evidence = <Map<String, dynamic>>[];
  for (final page in pages) {
    final cached = ImageTranslationResult.fromCacheJson(page['result']);
    DetectionResult? detection;
    if (needsOversizedOcrPageCheck(
      cached.blocks,
      cached.imageWidth ?? 0,
      cached.imageHeight ?? 0,
    )) {
      final detected = await detector.detect(
        '$caseDirectory/${page['sourceFile']}',
        cancellationToken: InferenceCancellationToken(),
      );
      detection = DetectionResult(
        regions: const [],
        polygonMasks: detected.polygonMasks,
      );
    }
    final checked = reconcileOversizedOcrPage(cached, detection);
    evidence.add({
      'page': page['page'],
      'before': cached.status.name,
      'after': checked.status.name,
      'checked': detection != null,
      'polygonMasks': detection?.polygonMasks.map((m) => m.toJson()).toList(),
      'passed': checked.status.name == page['expectedStatus'],
    });
  }
  await Directory(outputDirectory).create(recursive: true);
  final result = <String, dynamic>{
    'case': 'false_text_gallery_16',
    'pages': evidence,
    'passed': evidence.every((p) => p['passed'] == true),
  };
  await File(
    '$outputDirectory/acceptance.json',
  ).writeAsString(jsonEncode(result));
  return result;
}

/// Replay a background defect with recorded translated OCR geometry and fresh
/// CTD masks. The page comes from the user's actual reader cache.
Future<Map<String, dynamic>> runBackgroundAcceptance({
  required String caseDirectory,
  required String sourcePath,
  required String modelRoot,
  required String outputDirectory,
  required OnnxRuntime runtime,
  required List<ort.OrtProvider> providers,
}) async {
  final annotation = jsonDecode(
    await File('$caseDirectory/case.json').readAsString(),
  );
  final blocks =
      (annotation['translatedBlocks'] as List)
          .map((b) => RecognizedTextBlock.fromJson(b))
          .toList();
  final detector = CtdOnnxInferenceEngine(
    runtime: runtime,
    providerResolver: () => providers,
    modelResolver:
        () => CtdOnnxModelInfo(
          modelPath:
              '$modelRoot/comic-text-detector-beta-0.3/comictextdetector.pt.onnx',
          fingerprint: 'acceptance-ctd',
        ),
  );
  final detection = await detector.detect(
    sourcePath,
    cancellationToken: InferenceCancellationToken(),
  );
  final masks = filterPolygonMasksToTranslatedBlocks(
    masks: detection.polygonMasks,
    translatedBlocks: blocks,
  );
  await Directory(outputDirectory).create(recursive: true);
  await File('$outputDirectory/pipeline_snapshot.json').writeAsString(
    jsonEncode({'erasePolygons': masks.map((m) => m.toJson()).toList()}),
  );
  final engine = LamaOnnxInpaintingInferenceEngine(
    runtime: runtime,
    providerResolver: () => providers,
    modelResolver:
        () => LamaOnnxModelInfo(
          modelPath: '$modelRoot/lama-large-512px/lamalarge.onnx',
          fingerprint: 'acceptance-lama',
        ),
  );
  final clock = Stopwatch()..start();
  final output = '$outputDirectory/repaired.png';
  await engine.inpaint(
    inputPath: sourcePath,
    outputPath: output,
    polygonMasks: masks,
  );
  final source = img.decodeImage(await File(sourcePath).readAsBytes())!;
  final repaired = img.decodeImage(await File(output).readAsBytes())!;
  final bounds = annotation['textBounds'] as List;
  int white = 0, whiteResidual = 0, black = 0, blackResidual = 0;
  for (int y = bounds[1]; y < bounds[1] + bounds[3]; y++) {
    for (int x = bounds[0]; x < bounds[0] + bounds[2]; x++) {
      final before = source.getPixel(x, y).luminance;
      final after = repaired.getPixel(x, y).luminance;
      if (before > 235) {
        white++;
        if (after > 220) whiteResidual++;
      }
      if (before < 80) {
        black++;
        if (after < 100) blackResidual++;
      }
    }
  }
  final evidence = <String, dynamic>{
    'case': annotation['id'],
    'repairMilliseconds': clock.elapsedMilliseconds,
    'selectedMasks': masks.length,
    'whitePixels': white,
    'blackPixels': black,
    'whiteResidualFraction': whiteResidual / white,
    'blackResidualFraction': blackResidual / black,
    'passed':
        white > 100 &&
        black > 100 &&
        whiteResidual / white < annotation['maxResidualFraction'] &&
        blackResidual / black < annotation['maxResidualFraction'],
  };
  await File(
    '$outputDirectory/acceptance.json',
  ).writeAsString(jsonEncode(evidence));
  return evidence;
}

/// Native acceptance: real OCR/bubbles -> fixed recorded translations ->
/// production CTD/LaMa -> production exporter -> OCR the rendered result.
/// No account initialization, translation API, or writes to the user's cache.
Future<Map<String, dynamic>> runImageTranslationAcceptance({
  required String caseDirectory,
  required String sourcePath,
  required String modelRoot,
  required String outputDirectory,
  required OnnxRuntime runtime,
  required List<ort.OrtProvider> providers,
  required OnnxOcrInferenceEngine ocr,
  required List<RecognizedTextBlock> blocks,
  required List<RecognizedTextContainer> containers,
}) async {
  final annotation = jsonDecode(
    await File('$caseDirectory/case.json').readAsString(),
  );
  final source = img.decodeImage(await File(sourcePath).readAsBytes())!;
  if (source.width != annotation['sourceWidth'] ||
      source.height != annotation['sourceHeight']) {
    throw StateError('Acceptance source dimensions do not match case.json');
  }
  final groups = translationTextGroups(blocks, containers: containers);
  final groupTranslations = <String>[];
  for (final group in groups) {
    final lines = <String>[];
    for (final index in group.blockIndices) {
      final String? text = annotation['translations'][blocks[index].text];
      if (text == null) {
        throw StateError(
          'No recorded translation for OCR: ${blocks[index].text}',
        );
      }
      lines.add(text);
    }
    groupTranslations.add(lines.join('\n'));
  }
  final result = ImageTranslationResult(
    status: ImageTranslationStatus.success,
    sourceText: blocks.map((b) => b.text).join('\n'),
    translatedText: expandGroupTranslationsToLines(
      blocks: blocks,
      groups: groups,
      groupTranslations: groupTranslations,
    ).join('\n'),
    translatedGroups: groupTranslations,
    blocks: blocks,
    containers: containers,
    imageWidth: source.width,
    imageHeight: source.height,
  );
  final target = blocks.singleWhere(
    (b) => b.text == annotation['targetSourceText'],
  );
  final erase = translatedBlocksEligibleForErase(result);
  final detector = CtdOnnxInferenceEngine(
    runtime: runtime,
    providerResolver: () => providers,
    modelResolver:
        () => CtdOnnxModelInfo(
          modelPath:
              '$modelRoot/comic-text-detector-beta-0.3/comictextdetector.pt.onnx',
          fingerprint: 'acceptance-ctd',
        ),
  );
  final detected = await detector.detect(
    sourcePath,
    cancellationToken: InferenceCancellationToken(),
  );
  final masks = filterPolygonMasksToTranslatedBlocks(
    masks: detected.polygonMasks,
    translatedBlocks: erase,
    protectedBlocks: blocks.where((b) => !erase.contains(b)).toList(),
  );
  await Directory(outputDirectory).create(recursive: true);
  pathService.tempDir = Directory('$outputDirectory/temp');
  pathService.jhOcrModelDir = Directory(outputDirectory);
  final repairedPath = '$outputDirectory/repaired.png';
  final lama = LamaOnnxInpaintingInferenceEngine(
    runtime: runtime,
    providerResolver: () => providers,
    modelResolver:
        () => LamaOnnxModelInfo(
          modelPath: '$modelRoot/lama-large-512px/lamalarge.onnx',
          fingerprint: 'acceptance-lama',
        ),
  );
  final repairClock = Stopwatch()..start();
  await lama.inpaint(
    inputPath: sourcePath,
    outputPath: repairedPath,
    polygonMasks: masks,
  );
  repairClock.stop();
  final lamaSessionReady = [
    '$modelRoot/lama-large-512px/lamalarge.onnx',
    '$modelRoot/lama-large-512px/lamalarge.onnx.dml-rank4-v1.onnx',
  ].any((path) => runtime.hasReadySessions([path]));
  imageTranslationSetting.translationBackgroundOpacity.value = .9;
  final service = ImageTranslationService();
  service.publishResult('acceptance', result);
  final exported = await service.exportOverlay(
    ImageTranslationRequest(cacheKey: 'acceptance', imagePath: repairedPath),
  );
  final output = await exported.copy('$outputDirectory/translated.png');
  final repaired = img.decodeImage(await File(repairedPath).readAsBytes())!;
  final rendered = img.decodeImage(await output.readAsBytes())!;
  final residuals = <Map<String, dynamic>>[];
  if (annotation['maxResidualInkFraction'] != null) {
    for (final block in erase) {
      int originalInk = 0, residualInk = 0;
      for (
        int y = block.top.floor().clamp(0, source.height);
        y < (block.top + block.height).ceil().clamp(0, source.height);
        y++
      ) {
        for (
          int x = block.left.floor().clamp(0, source.width);
          x < (block.left + block.width).ceil().clamp(0, source.width);
          x++
        ) {
          if (source.getPixel(x, y).luminance >= 140) continue;
          originalInk++;
          if (repaired.getPixel(x, y).luminance < 235) residualInk++;
        }
      }
      residuals.add({
        'sourceText': block.text,
        'originalInkPixels': originalInk,
        'residualInkPixels': residualInk,
        'fraction': originalInk == 0 ? 0.0 : residualInk / originalInk,
      });
    }
  }
  final residualPassed = residuals.every(
    (metric) => metric['fraction'] < annotation['maxResidualInkFraction'],
  );
  final speedPassed =
      annotation['expectNoLamaSession'] != true || !lamaSessionReady;
  int newInk = 0;
  for (
    int y = target.top.floor();
    y < (target.top + target.height).ceil();
    y++
  ) {
    for (
      int x = target.left.floor();
      x < (target.left + target.width).ceil();
      x++
    ) {
      if (repaired.getPixel(x, y).luminance > 180 &&
          rendered.getPixel(x, y).luminance < 120) {
        newInk++;
      }
    }
  }
  final renderedOcr = await ocr.recognize(output.path);
  final targetRect = Rect.fromLTWH(
    target.left,
    target.top,
    target.width,
    target.height,
  );
  final found =
      renderedOcr.blocks
          .where(
            (b) =>
                b.text.contains('前辈') &&
                targetRect.overlaps(
                  Rect.fromLTWH(b.left, b.top, b.width, b.height),
                ),
          )
          .toList();
  final evidence = <String, dynamic>{
    'case': annotation['id'],
    'translationSource': 'recorded fixture; no translation API',
    'ctdMasks': detected.polygonMasks.length,
    'selectedMasks': masks.length,
    'selectedPolygons': masks.map((mask) => mask.toJson()).toList(),
    'repairMilliseconds': repairClock.elapsedMilliseconds,
    'lamaSessionReady': lamaSessionReady,
    'residualInk': residuals,
    'newInkPixelsInSmallBubble': newInk,
    'targetRenderedOcr': found.map((b) => b.toJson()).toList(),
    'renderedOcr': renderedOcr.blocks.map((b) => b.toJson()).toList(),
    'translationResult': result.toJson(),
    'output': output.path,
    'passed': newInk >= 30 && found.isNotEmpty && residualPassed && speedPassed,
  };
  await File(
    '$outputDirectory/acceptance.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
  if (evidence['passed'] != true) {
    throw StateError(
      'Image translation acceptance failed; see $outputDirectory/acceptance.json',
    );
  }
  return evidence;
}
