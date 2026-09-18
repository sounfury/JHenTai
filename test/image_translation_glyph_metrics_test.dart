import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/utils/image_translation_colors.dart';

void main() {
  for (final inverted in [false, true]) {
    test('pixel metrics exclude padding, column gaps and small ruby ($inverted)', () {
      final source = image.Image(width: 90, height: 130);
      final bg = inverted ? 0 : 255;
      final fg = 255 - bg;
      image.fill(source, color: image.ColorRgb8(bg, bg, bg));
      // Two 14px columns inside a much wider OCR rectangle, with real gaps.
      for (final x in [20, 50]) {
        for (final y in [10, 35, 60, 85]) {
          for (int yy = y; yy < y + 18; yy++) {
            for (int xx = x; xx < x + 14; xx++) {
              // Hollow glyph-like shapes keep foreground a minority.
              if (yy < y + 3 || yy >= y + 15 || xx < x + 3 || xx >= x + 11) {
                source.setPixelRgb(xx, yy, fg, fg, fg);
              }
            }
          }
        }
      }
      // Small annotation beside the main text must not set its font size.
      for (int y = 10; y < 100; y++) {
        for (int x = 72; x < 76; x++) {
          source.setPixelRgb(x, y, fg, fg, fg);
        }
      }
      final block = detectTranslationColors({
        'bytes': Uint8List.fromList(image.encodePng(source)),
        'width': 90,
        'height': 130,
        'blocks': const [
          RecognizedTextBlock(text: 'あいうえおかきく', confidence: 1,
              width: 90, height: 130),
        ],
      }).single;
      expect(block.sourceGlyphWidth, 14);
      final restored = RecognizedTextBlock.fromJson(block.toJson());
      expect(restored.sourceGlyphWidth, block.sourceGlyphWidth);
      expect(restored.sourceGlyphHeight, block.sourceGlyphHeight);
    });
  }

  test('cached colors still acquire glyph metrics in OCR coordinate space', () {
    final source = image.Image(width: 80, height: 80);
    image.fill(source, color: image.ColorRgb8(255, 255, 255));
    for (int y = 20; y < 60; y++) {
      for (int x = 30; x < 50; x++) {
        source.setPixelRgb(x, y, 0, 0, 0);
      }
    }
    final block = detectTranslationColors({
      'bytes': Uint8List.fromList(image.encodePng(source)),
      'width': 40,
      'height': 40,
      'blocks': const [
        RecognizedTextBlock(text: 'あ', confidence: 1, width: 40, height: 40,
            backgroundColor: 0xffffffff),
      ],
    }).single;
    expect(block.sourceGlyphWidth, 10);
    expect(block.sourceGlyphHeight, 20);
  });

  test('empty source region leaves metrics absent for the geometry fallback', () {
    final source = image.Image(width: 20, height: 20);
    image.fill(source, color: image.ColorRgb8(255, 255, 255));
    final block = detectTranslationColors({
      'bytes': Uint8List.fromList(image.encodePng(source)),
      'width': 20,
      'height': 20,
      'blocks': const [
        RecognizedTextBlock(text: 'あ', confidence: 1, width: 20, height: 20),
      ],
    }).single;
    expect(block.sourceGlyphWidth, isNull);
    expect(block.sourceGlyphHeight, isNull);
  });
}
