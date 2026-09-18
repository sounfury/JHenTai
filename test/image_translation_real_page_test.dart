import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/utils/image_translation_colors.dart';
import 'package:jhentai/src/utils/image_translation_typography.dart';
import 'package:jhentai/src/utils/vertical_translation_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final File fixturePng = File(
    'test/fixtures/translation_layout/vertical_manga_original.png',
  );
  final File fixtureRegions = File(
    'test/fixtures/translation_layout/regions.json',
  );

  test('fixture manga page and region annotations are present and valid', () {
    expect(fixturePng.existsSync(), isTrue);
    expect(fixtureRegions.existsSync(), isTrue);
    expect(fixturePng.lengthSync(), greaterThan(100000));

    final List<dynamic> rawRegions =
        jsonDecode(fixtureRegions.readAsStringSync()) as List<dynamic>;
    expect(rawRegions.length, equals(7));
  });

  test(
    'real page stroke bands correctly measure glyph sizes and avoid bubble overflows',
    () {
      final bytes = fixturePng.readAsBytesSync();
      final decoded = image.decodeImage(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, equals(1206));
      expect(decoded.height, equals(2622));

      final List<dynamic> rawRegions =
          jsonDecode(fixtureRegions.readAsStringSync()) as List<dynamic>;
      final blocks = rawRegions
          .map(
            (dynamic r) => RecognizedTextBlock(
              text: r['name'] as String,
              confidence: 1.0,
              left: (r['left'] as num).toDouble(),
              top: (r['top'] as num).toDouble(),
              width: (r['width'] as num).toDouble(),
              height: (r['height'] as num).toDouble(),
            ),
          )
          .toList(growable: false);

      final detected = detectTranslationColors({
        'bytes': bytes,
        'width': decoded.width,
        'height': decoded.height,
        'blocks': blocks,
      });

      expect(detected.length, equals(7));

      final Map<String, RecognizedTextBlock> byName = {
        for (int i = 0; i < detected.length; i++)
          rawRegions[i]['name'] as String: detected[i],
      };

      // 1. Verify bright bubble background is identified.
      for (final block in detected) {
        expect(block.backgroundColor, isNotNull);
        final bg = block.backgroundColor!;
        final r = (bg >> 16) & 255;
        final g = (bg >> 8) & 255;
        final b = bg & 255;
        expect(r, greaterThan(240));
        expect(g, greaterThan(240));
        expect(b, greaterThan(240));
      }

      // 2. Large exclamation vs regular dialogue vs small dialogue.
      final largeExclamation = byName['large_exclamation']!;
      final regularDialogue = byName['regular_dialogue']!;
      final smallMiddle = byName['small_right_middle']!;
      final smallTop = byName['small_right_top']!;
      final boldDialogue = byName['bold_dialogue']!;

      expect(largeExclamation.sourceGlyphWidth, isNotNull);
      expect(regularDialogue.sourceGlyphWidth, isNotNull);
      expect(smallMiddle.sourceGlyphWidth, isNotNull);

      // Large emphasis text has significantly wider strokes than standard or small text.
      expect(
        largeExclamation.sourceGlyphWidth!,
        greaterThan(regularDialogue.sourceGlyphWidth!),
      );
      expect(
        regularDialogue.sourceGlyphWidth!,
        greaterThanOrEqualTo(smallMiddle.sourceGlyphWidth!),
      );

      // Core regression: small text OCR box (width 80) is not mistaken for 80px font.
      // Measured glyph width should be compact (~19-22px), preventing oversized font.
      expect(smallMiddle.sourceGlyphWidth!, lessThan(smallMiddle.width * 0.4));
      expect(smallTop.sourceGlyphWidth!, lessThan(smallTop.width * 0.4));

      // 3. Font size estimation respects source glyph width in vertical manga layout.
      final smallFontSize = estimateSourceTranslationFontSize(
        [smallMiddle],
        [0],
        vertical: true,
      );
      expect(smallFontSize, equals(smallMiddle.sourceGlyphWidth));
      expect(smallFontSize, lessThan(25.0));

      final boldFontSize = estimateSourceTranslationFontSize(
        [boldDialogue],
        [0],
        vertical: true,
      );
      expect(boldFontSize, greaterThan(smallFontSize));

      // 4. Fitting translated text within real regions shrinks or caps correctly.
      const sampleTranslation = '这是真实排版测试文本！';
      final fittedSize = fitTranslationFontSize(
        sampleTranslation,
        smallMiddle.width,
        smallMiddle.height,
        TextDirection.ltr,
        maxFontSize: smallFontSize,
        vertical: true,
      );

      expect(fittedSize, lessThanOrEqualTo(smallFontSize));

      final layout = VerticalTranslationLayout(
        sampleTranslation,
        fontSize: fittedSize,
        maxHeight: smallMiddle.height,
      );
      expect(layout.size.width, lessThanOrEqualTo(smallMiddle.width + 1.0));
      expect(layout.size.height, lessThanOrEqualTo(smallMiddle.height + 1.0));
      layout.dispose();
    },
  );
}
