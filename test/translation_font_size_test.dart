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
}
