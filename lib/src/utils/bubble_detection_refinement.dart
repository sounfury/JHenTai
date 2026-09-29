import 'dart:math' as math;
import 'dart:ui';

import '../model/image_translation.dart';
import '../service/engine/engine_contract.dart';
import '../service/image_translation/onomatopoeia_filter.dart';
import 'image_text_grouping.dart';
import 'rgba_raster.dart';

Rect bubbleRegionRect(DetectedTextRegion r) =>
    Rect.fromLTWH(r.left, r.top, r.width, r.height);
Rect bubbleTextRect(RecognizedTextBlock b) =>
    Rect.fromLTWH(b.left, b.top, b.width, b.height);

double bubbleRegionCoverage(
  RecognizedTextBlock block,
  DetectedTextRegion region,
) {
  final rect = bubbleTextRect(block);
  if (rect.isEmpty) {
    return 0;
  }
  if (region.bubbleInterior != null) {
    return region.bubbleInterior!.coverage(rect);
  }
  final overlap = rect.intersect(bubbleRegionRect(region));
  return overlap.isEmpty
      ? 0
      : overlap.width * overlap.height / (rect.width * rect.height);
}

/// At most two local passes, only where OCR exposes a missing lobe or a
/// low-resolution narrow mask. A retry must preserve existing OCR support;
/// worse results and failures leave the full-page detection intact.
Future<DetectionResult> refineBubbleDetection({
  required RgbaRaster source,
  required DetectionResult initial,
  required List<RecognizedTextBlock> blocks,
  required Future<DetectionResult?> Function(RgbaRaster crop) detect,
  required bool Function() isCanceled,
}) async {
  final page = Rect.fromLTWH(
    0,
    0,
    source.width.toDouble(),
    source.height.toDouble(),
  );
  final targets =
      <
        ({
          Rect bounds,
          DetectedTextRegion? original,
          List<RecognizedTextBlock> text,
        })
      >[];
  bool dialogue(RecognizedTextBlock b) =>
      b.text.trim().runes.length >= 4 &&
      !isOnomatopoeia(b.text) &&
      b.width > 0 &&
      b.height > 0;
  for (final region in initial.regions) {
    final box = bubbleRegionRect(region);
    final text =
        blocks
            .where((b) => dialogue(b) && box.contains(bubbleTextRect(b).center))
            .toList();
    if (text.isEmpty) {
      continue;
    }
    final mask = region.bubbleInterior;
    final missing = text.any((b) => bubbleRegionCoverage(b, region) < .85);
    final narrow = mask != null && math.min(mask.width, mask.height) < 12;
    if (missing || narrow) {
      targets.add((bounds: box, original: region, text: text));
    }
  }
  final missing =
      blocks
          .where(
            (b) =>
                dialogue(b) &&
                !initial.regions.any((r) => bubbleRegionCoverage(b, r) >= .55),
          )
          .toList();
  for (final group in groupRecognizedTextBlocks(missing)) {
    final rect = Rect.fromLTRB(
      group.left,
      group.top,
      group.right,
      group.bottom,
    );
    if (targets.any((t) => t.bounds.overlaps(rect))) {
      continue;
    }
    targets.add((bounds: rect, original: null, text: group.blocksOf(missing)));
  }
  final result = [...initial.regions];
  // Completely missed dialogue gets first use of the retry budget.
  targets.sort((a, b) {
    double priority(
      DetectedTextRegion? original,
      List<RecognizedTextBlock> text,
    ) =>
        original == null
            ? 2
            : 1 -
                text
                    .map((block) => bubbleRegionCoverage(block, original))
                    .reduce(math.min);
    return priority(b.original, b.text).compareTo(priority(a.original, a.text));
  });
  final attempted = <Rect>[];
  for (final target in targets) {
    if (isCanceled() || attempted.length >= 2) {
      break;
    }
    final margin = math.max(
      24.0,
      math.max(target.bounds.width, target.bounds.height) * .25,
    );
    final padded = target.bounds.inflate(margin).intersect(page);
    final cropRect = Rect.fromLTRB(
      padded.left.floorToDouble(),
      padded.top.floorToDouble(),
      padded.right.ceilToDouble(),
      padded.bottom.ceilToDouble(),
    );
    if (cropRect.width < 32 ||
        cropRect.height < 32 ||
        cropRect.width * cropRect.height > page.width * page.height * .65 ||
        attempted.any((r) => r.contains(cropRect.center))) {
      continue;
    }
    attempted.add(cropRect);
    if (isCanceled()) {
      break;
    }
    final local = await detect(
      source.crop(
        cropRect.left.toInt(),
        cropRect.top.toInt(),
        cropRect.width.toInt(),
        cropRect.height.toInt(),
      ),
    );
    if (local == null || isCanceled()) {
      continue;
    }
    final candidates = <DetectedTextRegion>[];
    for (final region in local.regions) {
      if (region.bubbleInterior == null) {
        continue;
      }
      final box = bubbleRegionRect(region);
      // A balloon cut by the crop edge is not a trustworthy replacement.
      if (box.left <= 1 ||
          box.top <= 1 ||
          box.right >= cropRect.width - 1 ||
          box.bottom >= cropRect.height - 1) {
        continue;
      }
      final shifted = DetectedTextRegion(
        left: region.left + cropRect.left,
        top: region.top + cropRect.top,
        width: region.width,
        height: region.height,
        confidence: region.confidence,
        bubbleInterior: region.bubbleInterior!.shifted(cropRect.topLeft),
      );
      if (target.text.any((b) => bubbleRegionCoverage(b, shifted) >= .55)) {
        candidates.add(shifted);
      }
    }
    if (candidates.isEmpty) {
      continue;
    }
    final original = target.original;
    // Include every previously admitted OCR block, including short dialogue,
    // in the no-regression check, not just the long text that triggered retry.
    final checked = <RecognizedTextBlock>{
      ...target.text,
      if (original != null)
        ...blocks.where((b) => bubbleRegionCoverage(b, original) >= .55),
    };
    double support(RecognizedTextBlock b) =>
        candidates.map((r) => bubbleRegionCoverage(b, r)).reduce(math.max);
    if (checked.any((b) => support(b) < .55)) {
      continue;
    }
    final improves = target.text.any(
      (b) =>
          original == null ||
          support(b) > bubbleRegionCoverage(b, original) + .1,
    );
    final oldMask = original?.bubbleInterior;
    final finer =
        oldMask != null &&
        candidates.any(
          (r) =>
              r.bubbleInterior!.width / r.width >
              oldMask.width / oldMask.bounds.width * 1.25,
        );
    if (!improves && !finer) {
      continue;
    }
    if (original != null) {
      result.remove(original);
    }
    result.addAll(candidates);
  }
  return DetectionResult(regions: result, polygonMasks: initial.polygonMasks);
}
