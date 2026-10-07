// 统一阅读页和导出图片的译文排版，按原文字色及描边绘制。
import 'package:flutter/material.dart';

import 'dart:math' as math;

import '../model/image_translation.dart';
import 'image_text_grouping.dart';
import 'image_translation_typography.dart';
import 'page_processing_strategy.dart';

typedef TranslationTextPlacement =
    ({
      Rect rect,
      String text,
      double fontSize,
      Color color,
      Color? outlineColor,
      double outlineWidth,
      bool vertical,
    });

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
  PageProcessingStrategy strategy = PageProcessingStrategy.monochrome,
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
  // 先收集每段对白的排字区域，策略需要时统一消除重叠，再逐段排字。
  final pending = <_PendingGroup>[];
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
        strategy.useContainerLayoutRegions
            ? explicitRenderBoundsForRecognizedTextGroup(
                  group,
                  result.containers,
                ) ??
                renderBoundsForRecognizedTextGroup(group, result.blocks)
            : _sourceTextBounds(group, result.blocks);
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
    final sourceStyle = _sourceTextStyleForGroup(
      result.blocks,
      group.blockIndices,
    );
    final outlineRatio = sourceStyle?.outlineWidthRatio ?? 0;
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
    final regions =
        strategy.useContainerLayoutRegions
            ? layoutRegionsForRecognizedTextGroup(
              group,
              result.containers,
              blocks: result.blocks,
            )
            : const <TranslationLayoutRegion>[];
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
    pending.add(
      _PendingGroup(
        translation: translation,
        areas: areas,
        regionTexts: translationTextsForLayoutRegions(
          translation,
          group,
          result.blocks,
          regions,
        ),
        sourceFont: sourceFont,
        vertical: vertical,
        plateColor: plateColor,
        textColor: textColor,
        outlineColor:
            sourceStyle?.outlineColor == null ||
                    !outlineRatio.isFinite ||
                    outlineRatio <= 0
                ? null
                : Color(sourceStyle!.outlineColor!),
        outlineRatio: outlineRatio,
      ),
    );
  }
  if (strategy.separateOverlappingTexts) {
    separateOverlappingTranslationAreas(pending.map((p) => p.areas).toList());
  }
  for (final group in pending) {
    for (final (rect, text, fontSize) in layoutTranslationInRegions(
      group.translation,
      group.areas,
      textDirection,
      maxFontSize: group.sourceFont,
      vertical: group.vertical,
      regionTexts: group.regionTexts,
    )) {
      backgrounds.add((rect, group.plateColor));
      texts.add((
        rect: rect,
        text: text,
        fontSize: fontSize,
        color: group.textColor,
        outlineColor: group.outlineColor,
        outlineWidth:
            group.outlineRatio.isFinite
                ? fontSize * group.outlineRatio.clamp(0, .12) * 2
                : 0,
        vertical: group.vertical,
      ));
    }
  }
  return layout;
}

/// 不同对白的排字区域互不重叠：沿重叠较窄的方向从中线切开，各自退回
/// 自己一侧。直接修改传入的区域列表；区域至少保留 8 像素，由排字缩小字号。
void separateOverlappingTranslationAreas(List<List<Rect>> groups) {
  for (int pass = 0; pass < 4; pass++) {
    bool changed = false;
    for (int i = 0; i < groups.length; i++) {
      for (int j = i + 1; j < groups.length; j++) {
        for (int a = 0; a < groups[i].length; a++) {
          for (int b = 0; b < groups[j].length; b++) {
            final first = groups[i][a], second = groups[j][b];
            final overlap = first.intersect(second);
            if (overlap.width <= 0 || overlap.height <= 0) continue;
            final (one, other) = _splitOverlap(first, second, overlap);
            groups[i][a] = one;
            groups[j][b] = other;
            changed = true;
          }
        }
      }
    }
    if (!changed) return;
  }
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
      outlineColor: placement.outlineColor,
      outlineWidth: placement.outlineWidth,
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
  final sourceStyle = _sourceTextStyleForGroup(blocks, indices);
  final sampledText = sourceStyle?.textColor;
  final preserveSource =
      configuredBackground == Colors.white ||
      opacity <= 0 ||
      sourceStyle?.outlineColor != null;
  return (
    background,
    sampledText != null && preserveSource
        ? Color(sampledText)
        : visible.computeLuminance() > .179
        ? Colors.black
        : Colors.white,
  );
}

// ===== 私有工具 =====

class _PendingGroup {
  _PendingGroup({
    required this.translation,
    required this.areas,
    required this.regionTexts,
    required this.sourceFont,
    required this.vertical,
    required this.plateColor,
    required this.textColor,
    required this.outlineColor,
    required this.outlineRatio,
  });

  final String translation;
  final List<Rect> areas;
  final List<String>? regionTexts;
  final double sourceFont;
  final bool vertical;
  final Color plateColor;
  final Color textColor;
  final Color? outlineColor;
  final double outlineRatio;
}

/// 原文 OCR 框的并集，不使用气泡检测容器。
RecognizedTextGroupRenderBounds _sourceTextBounds(
  RecognizedTextGroup group,
  List<RecognizedTextBlock> blocks,
) {
  final members = [
    for (final index in group.blockIndices)
      if (index >= 0 && index < blocks.length) blocks[index],
  ];
  if (members.isEmpty) {
    return renderBoundsForRecognizedTextGroup(group, blocks);
  }
  return RecognizedTextGroupRenderBounds(
    left: members.map((b) => b.left).reduce(math.min),
    top: members.map((b) => b.top).reduce(math.min),
    right: members.map((b) => b.left + b.width).reduce(math.max),
    bottom: members.map((b) => b.top + b.height).reduce(math.max),
  );
}

(Rect, Rect) _splitOverlap(Rect first, Rect second, Rect overlap) {
  const gap = 1.0, minimum = 8.0;
  if (overlap.height <= overlap.width) {
    // 上下相叠：中心靠上的一方保留上半部分。
    final mid = overlap.center.dy;
    final firstAbove = first.center.dy <= second.center.dy;
    final upper = firstAbove ? first : second;
    final lower = firstAbove ? second : first;
    final newUpper = Rect.fromLTRB(
      upper.left,
      upper.top,
      upper.right,
      math.max(upper.top + minimum, mid - gap),
    );
    final newLower = Rect.fromLTRB(
      lower.left,
      math.min(lower.bottom - minimum, mid + gap),
      lower.right,
      lower.bottom,
    );
    return firstAbove ? (newUpper, newLower) : (newLower, newUpper);
  }
  final mid = overlap.center.dx;
  final firstLeft = first.center.dx <= second.center.dx;
  final leftRect = firstLeft ? first : second;
  final rightRect = firstLeft ? second : first;
  final newLeft = Rect.fromLTRB(
    leftRect.left,
    leftRect.top,
    math.max(leftRect.left + minimum, mid - gap),
    leftRect.bottom,
  );
  final newRight = Rect.fromLTRB(
    math.min(rightRect.right - minimum, mid + gap),
    rightRect.top,
    rightRect.right,
    rightRect.bottom,
  );
  return firstLeft ? (newLeft, newRight) : (newRight, newLeft);
}

RecognizedTextBlock? _sourceTextStyleForGroup(
  List<RecognizedTextBlock> blocks,
  List<int> indices,
) {
  RecognizedTextBlock? selected;
  double area = 0;
  for (final index in indices) {
    if (index < 0 || index >= blocks.length) continue;
    final block = blocks[index];
    final candidateArea = block.width * block.height;
    if (block.textColor != null && candidateArea > area) {
      selected = block;
      area = candidateArea;
    }
  }
  return selected;
}
