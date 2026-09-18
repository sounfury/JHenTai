import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/utils/image_translation_colors.dart';

void main() {
  test('mixed black and white bubbles keep independent text contrast', () {
    final source = image.Image(width: 100, height: 40);
    for (int y = 0; y < 40; y++) {
      for (int x = 0; x < 100; x++) {
        final background = x < 50 ? 0 : 255;
        // Thin glyph-like strokes should not change the detected fill.
        final value = y > 8 && y < 32 && x % 10 == 5
            ? 255 - background : background;
        source.setPixelRgb(x, y, value, value, value);
      }
    }
    final blocks = detectTranslationColors({
      'bytes': Uint8List.fromList(image.encodePng(source)),
      'width': 100,
      'height': 40,
      'blocks': const [
        RecognizedTextBlock(text: 'white', confidence: 1, width: 50, height: 40),
        RecognizedTextBlock(text: 'black', confidence: 1, left: 50, width: 50, height: 40),
      ],
    });
    expect(translationBubbleColors(blocks, [0], Colors.white, 0.9),
        (Colors.black, Colors.white));
    expect(translationBubbleColors(blocks, [1], Colors.white, 0.9),
        (Colors.white, Colors.black));
    // Repaired backgrounds have no backing plate; white text must stay white.
    expect(translationBubbleColors(blocks, [0], Colors.white, 0),
        (Colors.black, Colors.white));
    final restored = RecognizedTextBlock.fromJson(blocks.first.toJson());
    expect(restored.backgroundColor, 0xff000000);
  });

  test('custom plate contrast depends on its effective opacity', () {
    const blocks = [
      RecognizedTextBlock(text: 'text', confidence: 1, width: 50, height: 40,
          backgroundColor: 0xffffffff),
    ];
    expect(translationBubbleColors(blocks, [0], Colors.black, 1),
        (Colors.black, Colors.white));
    expect(translationBubbleColors(blocks, [0], Colors.black, 0),
        (Colors.black, Colors.black));
  });

  test('old cached blocks remain readable before source colors are available', () {
    final block = RecognizedTextBlock.fromJson({'text': 'old'});
    expect(block.backgroundColor, isNull);
    expect(translationBubbleColors([block], [0], Colors.white, 1),
        (Colors.white, Colors.black));
  });
}
