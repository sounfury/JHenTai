import 'package:flutter/material.dart';

import '../model/image_translation.dart';
import 'image_text_grouping.dart';
import 'image_translation_typography.dart';

typedef TranslationTextPlacement =
    ({Rect rect, String text, double fontSize, Color color, bool vertical});

/// Reader and export use the same layout; only their viewport and style differ.
class TranslationOverlayLayout {
  const TranslationOverlayLayout({
    required this.backgrounds,
    required this.texts,
  });

  final List<(Rect, Color)> backgrounds;
  final List<TranslationTextPlacement> texts;
}

TranslationOverlayLayout buildTranslationOverlayLayout({
  required ImageTranslationResult result,
  required Size sourceSize,
  required Rect visibleImage,
  required TextDirection textDirection,
  required Color backgroundColor,
  required double backgroundOpacity,
}) {
  final backgrounds = <(Rect, Color)>[];
  final texts = <TranslationTextPlacement>[];
  final layout = TranslationOverlayLayout(
    backgrounds: backgrounds,
    texts: texts,
  );
  if (sourceSize.isEmpty || visibleImage.isEmpty) {
    return layout;
  }
  final scaleX = visibleImage.width / sourceSize.width;
  final scaleY = visibleImage.height / sourceSize.height;
  Rect transform(Rect rect) => Rect.fromLTWH(
    visibleImage.left + rect.left * scaleX,
    visibleImage.top + rect.top * scaleY,
    rect.width * scaleX,
    rect.height * scaleY,
  );
  // Empty lines are OCR-index placeholders. Never remove them before grouping.
  final translations =
      result.translatedText.split('\n').map((s) => s.trim()).toList();
  final groups = translationTextGroups(
    result.blocks,
    merge: result.mergeTextBlocks,
    containers: result.containers,
  );
  for (int groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    final group = groups[groupIndex];
    final translation =
        groupIndex < result.translatedGroups.length &&
                result.translatedGroups[groupIndex].trim().isNotEmpty
            ? result.translatedGroups[groupIndex].trim()
            : group.blockIndices
                .map((i) => i < translations.length ? translations[i] : '')
                .where((text) => text.isNotEmpty)
                .join('\n');
    if (translation.isEmpty ||
        translationPreservesSource(group.textOf(result.blocks), translation) ||
        !group.blockIndices.any(
          (i) => result.blocks[i].width > 4 && result.blocks[i].height > 4,
        )) {
      continue;
    }
    final bounds =
        explicitRenderBoundsForRecognizedTextGroup(group, result.containers) ??
        renderBoundsForRecognizedTextGroup(group, result.blocks);
    // Validate against the source page before scaling into a letterboxed slot.
    final sourceRect = safeTranslationBackgroundRect(
      Rect.fromLTRB(bounds.left, bounds.top, bounds.right, bounds.bottom),
      sourceSize,
    );
    if (sourceRect == null) {
      continue;
    }
    final mapped = transform(sourceRect);
    final safeRect = Rect.fromLTRB(
      mapped.left - 4,
      mapped.top - 3,
      mapped.right + 4,
      mapped.bottom + 3,
    ).intersect(visibleImage);
    final (plateColor, textColor) = translationBubbleColors(
      result.blocks,
      group.blockIndices,
      backgroundColor,
      backgroundOpacity,
    );
    final vertical = translationUsesVerticalLayout(
      result.blocks,
      group.blockIndices,
    );
    final sourceFont = estimateSourceTranslationFontSize(
      result.blocks,
      group.blockIndices,
      vertical: vertical,
      scaleX: scaleX,
      scaleY: scaleY,
    );
    final regions = layoutRegionsForRecognizedTextGroup(
      group,
      result.containers,
      blocks: result.blocks,
    );
    if (regions.isNotEmpty) {
      // Cover source glyphs while the reader is still using backing plates.
      for (final index in group.blockIndices) {
        final block = result.blocks[index];
        backgrounds.add((
          transform(
            Rect.fromLTWH(block.left, block.top, block.width, block.height),
          ).intersect(visibleImage),
          plateColor,
        ));
      }
    }
    final areas =
        regions.isEmpty
            ? <Rect>[safeRect]
            : <Rect>[
              for (final region in regions)
                transform(
                  Rect.fromLTWH(
                    region.left,
                    region.top,
                    region.width,
                    region.height,
                  ),
                ).intersect(visibleImage),
            ];
    for (final (rect, text, fontSize) in layoutTranslationInRegions(
      translation,
      areas,
      textDirection,
      maxFontSize: sourceFont,
      vertical: vertical,
      regionTexts: translationTextsForLayoutRegions(
        translation,
        group,
        result.blocks,
        regions,
      ),
    )) {
      backgrounds.add((rect, plateColor));
      texts.add((
        rect: rect,
        text: text,
        fontSize: fontSize,
        color: textColor,
        vertical: vertical,
      ));
    }
  }
  return layout;
}

void paintTranslationOverlay(
  Canvas canvas,
  TranslationOverlayLayout layout, {
  required TextDirection textDirection,
  required double backgroundOpacity,
}) {
  final alpha = (backgroundOpacity * 255).round().clamp(0, 255);
  if (alpha > 0) {
    // Draw every plate first so a later bubble cannot cover earlier text.
    for (final (rect, color) in layout.backgrounds) {
      if (!rect.isEmpty) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()..color = color.withAlpha(alpha),
        );
      }
    }
  }
  for (final placement in layout.texts) {
    paintTranslationBubbleText(
      canvas,
      placement.rect,
      placement.text,
      textDirection,
      fontSize: placement.fontSize,
      color: placement.color,
      vertical: placement.vertical,
    );
  }
}

Rect? safeTranslationBackgroundRect(Rect rect, Size canvasSize) {
  if (!rect.left.isFinite ||
      !rect.top.isFinite ||
      !rect.right.isFinite ||
      !rect.bottom.isFinite ||
      rect.width <= 0 ||
      rect.height <= 0 ||
      canvasSize.isEmpty) {
    return null;
  }
  final clipped = rect.intersect(Offset.zero & canvasSize);
  if (clipped.isEmpty ||
      (clipped.width >= canvasSize.width * .95 &&
          clipped.height >= canvasSize.height * .95)) {
    return null;
  }
  return clipped;
}

(Color, Color) translationBubbleColors(
  List<RecognizedTextBlock> blocks,
  List<int> indices,
  Color configuredBackground,
  double opacity,
) {
  int? detected;
  double largestArea = 0;
  for (final index in indices) {
    final block = blocks[index];
    final area = block.width * block.height;
    if (block.backgroundColor != null && area > largestArea) {
      detected = block.backgroundColor;
      largestArea = area;
    }
  }
  final source = Color(detected ?? 0xffffffff);
  final background =
      configuredBackground == Colors.white ? source : configuredBackground;
  final visible = Color.alphaBlend(
    background.withValues(alpha: opacity.clamp(0.0, 1.0)),
    source,
  );
  return (
    background,
    visible.computeLuminance() > .179 ? Colors.black : Colors.white,
  );
}
