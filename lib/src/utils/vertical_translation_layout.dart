import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A vertical run with upright characters, read downwards then right-to-left.
/// The same glyph metrics are used for fitting and painting, including fallback
/// fonts. OCR/translation line breaks are soft breaks, not new text columns.
class VerticalTranslationLayout {
  VerticalTranslationLayout(
    String text, {
    required double fontSize,
    required double maxHeight,
    Color color = Colors.black,
  }) {
    final characters = text.replaceAll(RegExp(r'\s+'), '').characters.toList();
    if (characters.isEmpty || fontSize <= 0 || maxHeight <= 0) {
      return;
    }

    double cellWidth = fontSize;
    double cellHeight = fontSize * 1.05;
    for (final character in characters.toSet()) {
      final painter = TextPainter(
        text: TextSpan(
          text: _verticalForms[character] ?? character,
          style: TextStyle(color: color, fontSize: fontSize, height: 1.05),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _painters[character] = painter;
      final rotated = _rotatedCharacters.contains(character);
      cellWidth = math.max(cellWidth, rotated ? painter.height : painter.width);
      cellHeight = math.max(cellHeight, rotated ? painter.width : painter.height);
    }
    final capacity = math.max(1, (maxHeight / cellHeight).floor());
    final columnCount = (characters.length / capacity).ceil();
    // Balance columns so a one-character final column does not look detached.
    final rows = (characters.length / columnCount).ceil();
    final columnPitch = cellWidth * 1.1;
    size = Size(cellWidth + (columnCount - 1) * columnPitch, rows * cellHeight);
    for (int i = 0; i < characters.length; i++) {
      final column = i ~/ rows;
      final row = i % rows;
      glyphs.add((
        text: characters[i],
        bounds: Rect.fromLTWH(
          size.width - cellWidth - column * columnPitch,
          row * cellHeight,
          cellWidth,
          cellHeight,
        ),
      ));
    }
  }

  Size size = Size.zero;
  final List<({String text, Rect bounds})> glyphs = [];
  final Map<String, TextPainter> _painters = {};

  void paint(Canvas canvas, Offset origin) {
    for (final glyph in glyphs) {
      final painter = _painters[glyph.text]!;
      final center = origin + glyph.bounds.center;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      if (_rotatedCharacters.contains(glyph.text)) {
        canvas.rotate(math.pi / 2);
      }
      painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
      canvas.restore();
    }
  }

  void dispose() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
  }
}

// Vertical punctuation forms; ellipses and prolonged sound marks rotate while
// CJK characters stay upright. Never rotate a whole horizontal text paragraph.
const _verticalForms = <String, String>{
  '，': '︐',
  '、': '︑',
  '。': '︒',
  '：': '︓',
  '；': '︔',
  '！': '︕',
  '？': '︖',
  '（': '︵',
  '）': '︶',
  '(': '︵',
  ')': '︶',
  '「': '﹁',
  '」': '﹂',
  '『': '﹃',
  '』': '﹄',
  '【': '︻',
  '】': '︼',
  '《': '︽',
  '》': '︾',
};
const _rotatedCharacters = {'…', '⋯', 'ー', '—', '―', '–'};
