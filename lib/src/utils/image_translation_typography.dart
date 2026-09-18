import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/image_translation.dart';
import 'ocr_layout_protocol.dart';
import 'vertical_translation_layout.dart';

/// Infer direction per text group, not per page: a manga page may contain
/// vertical dialogue and horizontal captions at the same time.
bool translationUsesVerticalLayout(
  List<RecognizedTextBlock> blocks,
  List<int> blockIndices,
) => classifyOcrLayout([
  for (final index in blockIndices)
    if (index >= 0 && index < blocks.length)
      OcrLayoutBox(
        sourceIndex: index,
        left: blocks[index].left,
        top: blocks[index].top,
        width: blocks[index].width,
        height: blocks[index].height,
      ),
]) == OcrLayoutMode.verticalRtl;

/// Paint using the same bounds and metrics as fitting; preserve the original
/// writing direction and never truncate a translation to an ellipsis.
void paintTranslationBubbleText(
  Canvas canvas,
  Rect rect,
  String translation,
  TextDirection textDirection, {
  double? fontSize,
  Color color = Colors.black,
  bool vertical = false,
}) {
  final content = rect.deflate(2);
  if (content.isEmpty) {
    return;
  }
  final resolved = fontSize ?? fitTranslationFontSize(
    translation,
    content.width,
    content.height,
    textDirection,
    vertical: vertical,
  );
  if (resolved <= 0) {
    return;
  }
  canvas.save();
  canvas.clipRect(content);
  if (vertical) {
    final layout = VerticalTranslationLayout(
      translation,
      fontSize: resolved,
      maxHeight: content.height,
      color: color,
    );
    layout.paint(
      canvas,
      content.center - Offset(layout.size.width / 2, layout.size.height / 2),
    );
    layout.dispose();
  } else {
    final painter = TextPainter(
      text: TextSpan(
        text: translation,
        style: TextStyle(color: color, fontSize: resolved, height: 1.05),
      ),
      textAlign: TextAlign.center,
      textDirection: textDirection,
    )..layout(maxWidth: content.width);
    painter.paint(
      canvas,
      Offset(content.left, content.center.dy - painter.height / 2),
    );
    painter.dispose();
  }
  canvas.restore();
}

/// Shrink to fit, but never enlarge beyond the source glyph size. A fixed
/// 8-pixel floor enlarged small/zoomed-out source text and could still overflow.
double fitTranslationFontSize(
  String text,
  double maxWidth,
  double maxHeight,
  TextDirection textDirection, {
  double? maxFontSize,
  bool vertical = false,
}) {
  if (maxWidth <= 0 || maxHeight <= 0) {
    return 0;
  }
  double low = 0;
  double high = maxFontSize ?? 30;
  if (!high.isFinite || high <= 0) {
    return 0;
  }
  bool fits(double fontSize) {
    final Size measured;
    if (vertical) {
      final layout = VerticalTranslationLayout(
        text,
        fontSize: fontSize,
        maxHeight: maxHeight,
      );
      measured = layout.size;
      layout.dispose();
    } else {
      final probe = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize, height: 1.05),
        ),
        textAlign: TextAlign.center,
        textDirection: textDirection,
      )..layout(maxWidth: maxWidth);
      // Long unbreakable runs can exceed the paragraph's constrained width.
      final widestLine = probe.computeLineMetrics().fold<double>(
        0,
        (width, line) => math.max(width, line.width),
      );
      measured = Size(widestLine, probe.height);
      probe.dispose();
    }
    return measured.width <= maxWidth && measured.height <= maxHeight;
  }
  if (fits(high)) {
    return high;
  }
  for (int iteration = 0; iteration < 12; iteration++) {
    final mid = (low + high) / 2;
    if (fits(mid)) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return low;
}

/// Prefer source stroke thickness: vertical column width / horizontal row
/// height, excluding OCR padding and inter-column gaps. Fall back to OCR bounds
/// only when pixels could not be measured. Keep source and display axes explicit
/// so reader zoom and original-resolution exports preserve the same scale.
double estimateSourceTranslationFontSize(
  List<RecognizedTextBlock> blocks,
  List<int> blockIndices, {
  double scaleY = 1,
  double? scaleX,
  bool? vertical,
}) {
  final isVertical =
      vertical ?? translationUsesVerticalLayout(blocks, blockIndices);
  final sizes = <double>[
    for (final index in blockIndices)
      if (index >= 0 && index < blocks.length &&
          blocks[index].width > 0 && blocks[index].height > 0)
        isVertical
            ? math.min(
                blocks[index].width,
                blocks[index].sourceGlyphWidth ?? blocks[index].width,
              ) * (scaleX ?? scaleY)
            : math.min(
                blocks[index].height,
                blocks[index].sourceGlyphHeight ?? blocks[index].height,
              ) * scaleY,
  ]..removeWhere((size) => !size.isFinite || size <= 0);
  if (sizes.isEmpty) {
    return 30;
  }
  sizes.sort();
  final middle = sizes.length ~/ 2;
  return sizes.length.isOdd
      ? sizes[middle]
      : (sizes[middle - 1] + sizes[middle]) / 2;
}


