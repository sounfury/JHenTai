import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fitTranslationFontSize respects source OCR height cap', () {
    // A huge bubble that could otherwise fit font size 30.
    const double bubbleWidth = 400;
    const double bubbleHeight = 400;
    const String text = '短';

    final double uncapped = fitTranslationFontSize(
      text,
      bubbleWidth,
      bubbleHeight,
      TextDirection.ltr,
    );
    expect(uncapped, greaterThan(20));

    final double capped = fitTranslationFontSize(
      text,
      bubbleWidth,
      bubbleHeight,
      TextDirection.ltr,
      maxFontSize: 12,
    );
    expect(capped, lessThanOrEqualTo(12.5));
    expect(capped, lessThan(uncapped));
  });

  test('estimateSourceTranslationFontSize uses median OCR line height', () {
    final List<RecognizedTextBlock> blocks = <RecognizedTextBlock>[
      const RecognizedTextBlock(
        text: 'a',
        confidence: 1,
        left: 0,
        top: 0,
        width: 40,
        height: 10,
      ),
      const RecognizedTextBlock(
        text: 'b',
        confidence: 1,
        left: 0,
        top: 12,
        width: 40,
        height: 20,
      ),
      const RecognizedTextBlock(
        text: 'c',
        confidence: 1,
        left: 0,
        top: 34,
        width: 40,
        height: 12,
      ),
    ];
    expect(
      estimateSourceTranslationFontSize(blocks, <int>[0, 1, 2]),
      12,
    );
    expect(
      estimateSourceTranslationFontSize(
        blocks,
        <int>[0, 1, 2],
        scaleY: 2,
      ),
      24,
    );
  });

  test('vertical column uses glyph width instead of the whole column height', () {
    const blocks = [
      RecognizedTextBlock(text: 'ほんのりあったかい', confidence: 1,
          left: 32, width: 16, height: 160),
      RecognizedTextBlock(text: 'あったかい', confidence: 1,
          left: 8, width: 18, height: 100),
      RecognizedTextBlock(text: 'horizontal', confidence: 1,
          width: 120, height: 12),
    ];
    expect(translationUsesVerticalLayout(blocks, [0, 1]), isTrue);
    expect(translationUsesVerticalLayout(blocks, [2]), isFalse);
    expect(estimateSourceTranslationFontSize(blocks, [0, 1]), 18);
    expect(estimateSourceTranslationFontSize(blocks, [0, 1],
        scaleX: 0.5, scaleY: 0.25), 9);
    expect(estimateSourceTranslationFontSize(blocks, [2],
        scaleX: 0.5, scaleY: 0.25), 3);
  });

  test('small source glyphs are never enlarged by the old 8px floor', () {
    for (final vertical in [false, true]) {
      final fitted = fitTranslationFontSize(
        '好暖和', 40, 60, TextDirection.ltr,
        maxFontSize: 5, vertical: vertical,
      );
      expect(fitted, greaterThan(0));
      expect(fitted, lessThanOrEqualTo(5));
    }
  });

  test('source-resolution fonts are not capped at 30px when exporting', () {
    expect(fitTranslationFontSize(
      '字', 200, 200, TextDirection.ltr, maxFontSize: 48,
    ), 48);
  });
}
