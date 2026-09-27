import 'dart:math' as math;

import '../model/image_translation.dart';

final RegExp _shortLatinFragment = RegExp(r'^[A-Za-z]{1,3}$');
final RegExp _cjkText = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]');

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
