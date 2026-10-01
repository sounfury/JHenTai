import 'dart:math' as math;

import '../model/image_translation.dart';
import '../service/engine/engine_contract.dart';
import 'image_text_grouping.dart';
import 'inpainting_pixels.dart';
import 'rgba_raster.dart';

final RegExp _shortLatinFragment = RegExp(r'^[A-Za-z]{1,3}$');
final RegExp _cjkText = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]');
const int currentOcrArtifactCheckVersion = 4;

/// Check individual uncertain artwork fragments, including those on pages
/// with real dialogue. Container membership always protects dialogue.
bool needsOversizedOcrPageCheck(
  List<RecognizedTextBlock> blocks,
  int imageWidth,
  int imageHeight, {
  List<RecognizedTextContainer> containers = const [],
}) =>
    _suspiciousOcrBlocks(
      blocks,
      imageWidth,
      imageHeight,
      containers,
    ).isNotEmpty;

Set<int> _suspiciousOcrBlocks(
  List<RecognizedTextBlock> blocks,
  int width,
  int height,
  List<RecognizedTextContainer> containers,
) {
  if (width <= 0 || height <= 0) {
    return {};
  }
  final protected = containers.expand((c) => c.blockIndices).toSet();
  final sizes =
      blocks
          .where((b) => b.confidence >= .85 && b.text.runes.length >= 4)
          .map((b) => math.min(b.width, b.height))
          .where((s) => s > 0)
          .toList()
        ..sort();
  final minimum = math.max(
    math.min(width, height) * .04,
    sizes.isEmpty ? 0.0 : sizes[sizes.length ~/ 2] * 1.8,
  );
  return {
    for (int i = 0; i < blocks.length; i++)
      if (!protected.contains(i) &&
          RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(blocks[i].text.trim()) &&
          ((blocks[i].confidence < .8 &&
                  math.min(blocks[i].width, blocks[i].height) >= minimum) ||
              (blocks[i].width > width * .05 &&
                  blocks[i].height > height * .12)))
        i,
  };
}

/// A failed second detector or missing source is not proof of empty artwork.
/// Remove only independently disproved OCR blocks; preserve other dialogue.
ImageTranslationResult reconcileOversizedOcrPage(
  ImageTranslationResult result,
  DetectionResult? detection, {
  RgbaRaster? source,
}) {
  if (result.status != ImageTranslationStatus.success ||
      result.ocrArtifactCheckVersion >= currentOcrArtifactCheckVersion ||
      detection == null) {
    return result;
  }
  final candidates = _suspiciousOcrBlocks(
    result.blocks,
    result.imageWidth ?? 0,
    result.imageHeight ?? 0,
    result.containers,
  );
  if (candidates.isEmpty) {
    return result;
  }
  final removed = <int>{};
  for (final index in candidates) {
    final block = result.blocks[index];
    final supported =
        detection.polygonMasks.where((mask) {
          if (!mask.isValid) {
            return false;
          }
          final area = (mask.right - mask.left) * (mask.bottom - mask.top);
          final width = math.max(
            0.0,
            math.min(mask.right, block.left + block.width) -
                math.max(mask.left, block.left),
          );
          final height = math.max(
            0.0,
            math.min(mask.bottom, block.top + block.height) -
                math.max(mask.top, block.top),
          );
          return area > 0 && width * height / area >= .15;
        }).toList();
    if (supported.isEmpty) {
      removed.add(index);
      continue;
    }
    if (source == null) {
      return result;
    }
    final coarse = rasterizeInpaintingMask(
      source.width,
      source.height,
      supported.map((m) => m.points.map((p) => math.Point(p.x, p.y)).toList()),
    );
    if (!refineInpaintingMask(source.toImage(), coarse).contains(0)) {
      removed.add(index);
    }
  }
  if (removed.isEmpty) {
    return result.copyWith(
      ocrArtifactCheckVersion: currentOcrArtifactCheckVersion,
    );
  }
  if (removed.length == result.blocks.length) {
    return ImageTranslationResult(
      status: ImageTranslationStatus.noText,
      errorMessage: 'NO_TEXT',
      imageWidth: result.imageWidth,
      imageHeight: result.imageHeight,
      ocrArtifactCheckVersion: currentOcrArtifactCheckVersion,
    );
  }
  final kept = [
    for (int i = 0; i < result.blocks.length; i++)
      if (!removed.contains(i)) i,
  ];
  final remap = {for (int i = 0; i < kept.length; i++) kept[i]: i};
  final blocks = kept.map((i) => result.blocks[i]).toList();
  final containers = [
    for (final c in result.containers)
      if (c.blockIndices.any(remap.containsKey))
        RecognizedTextContainer.fromJson({
          ...c.toJson(),
          'blockIndices': [
            for (final i in c.blockIndices)
              if (remap.containsKey(i)) remap[i],
          ],
        }),
  ];
  final oldGroups = translationTextGroups(
    result.blocks,
    merge: result.mergeTextBlocks,
    containers: result.containers,
  );
  final groupText = {
    for (
      int i = 0;
      i < oldGroups.length && i < result.translatedGroups.length;
      i++
    )
      oldGroups[i].blockIndices.join(','): result.translatedGroups[i],
  };
  final groups = translationTextGroups(
    blocks,
    merge: result.mergeTextBlocks,
    containers: containers,
  );
  final lines = result.translatedText.split('\n');
  return result.copyWith(
    blocks: blocks,
    containers: containers,
    sourceText: blocks.map((b) => b.text).join('\n'),
    translatedText: [
      for (final i in kept) i < lines.length ? lines[i] : '',
    ].join('\n'),
    translatedGroups: [
      for (final g in groups)
        groupText[g.blockIndices.map((i) => kept[i]).join(',')] ?? '',
    ],
    ocrArtifactCheckVersion: currentOcrArtifactCheckVersion,
  );
}

/// Isolate entry point: component scans must not block the reader.
ImageTranslationResult reconcileOversizedOcrPageWithPixels(
  (ImageTranslationResult, DetectionResult, RgbaRaster?) input,
) => reconcileOversizedOcrPage(input.$1, input.$2, source: input.$3);

/// Fold a low-confidence Latin OCR ghost into the CJK glyph it overlaps.
/// Keeping the union box lets inpainting still cover the complete source glyph.
List<RecognizedTextBlock> mergeOverlappingOcrArtifacts(
  List<RecognizedTextBlock> blocks,
) {
  final List<RecognizedTextBlock> result = List.of(blocks);
  final Set<int> discarded = <int>{};
  for (int artifactIndex = 0; artifactIndex < blocks.length; artifactIndex++) {
    final artifact = blocks[artifactIndex];
    if (!_shortLatinFragment.hasMatch(artifact.text) ||
        artifact.confidence > 0.8 ||
        artifact.width <= 0 ||
        artifact.height <= 0) {
      continue;
    }
    int? bestIndex;
    double bestOverlap = 0;
    for (
      int candidateIndex = 0;
      candidateIndex < blocks.length;
      candidateIndex++
    ) {
      if (candidateIndex == artifactIndex ||
          discarded.contains(candidateIndex)) {
        continue;
      }
      final candidate = result[candidateIndex];
      if (!_cjkText.hasMatch(candidate.text) ||
          candidate.confidence < 0.9 ||
          candidate.confidence - artifact.confidence < 0.2) {
        continue;
      }
      final double overlapWidth = math.max(
        0,
        math.min(
              artifact.left + artifact.width,
              candidate.left + candidate.width,
            ) -
            math.max(artifact.left, candidate.left),
      );
      final double overlapHeight = math.max(
        0,
        math.min(
              artifact.top + artifact.height,
              candidate.top + candidate.height,
            ) -
            math.max(artifact.top, candidate.top),
      );
      final double covered =
          overlapWidth * overlapHeight / (artifact.width * artifact.height);
      if (covered >= 0.5 && covered > bestOverlap) {
        bestIndex = candidateIndex;
        bestOverlap = covered;
      }
    }
    if (bestIndex == null) {
      continue;
    }
    final candidate = result[bestIndex];
    final double left = math.min(candidate.left, artifact.left);
    final double top = math.min(candidate.top, artifact.top);
    result[bestIndex] = RecognizedTextBlock(
      text: candidate.text,
      confidence: candidate.confidence,
      left: left,
      top: top,
      width:
          math.max(
            candidate.left + candidate.width,
            artifact.left + artifact.width,
          ) -
          left,
      height:
          math.max(
            candidate.top + candidate.height,
            artifact.top + artifact.height,
          ) -
          top,
      backgroundColor: candidate.backgroundColor,
      sourceGlyphWidth: candidate.sourceGlyphWidth,
      sourceGlyphHeight: candidate.sourceGlyphHeight,
    );
    discarded.add(artifactIndex);
  }
  return <RecognizedTextBlock>[
    for (int index = 0; index < result.length; index++)
      if (!discarded.contains(index)) result[index],
  ];
}
