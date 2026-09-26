import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/utils/connected_bubble_layout.dart';
import 'package:jhentai/src/utils/image_translation_typography.dart';
import 'package:jhentai/src/utils/vertical_translation_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final count in [1, 2, 3, 4]) {
    for (final stacked in [false, true]) {
      test(
        '$count connected lobes, stacked=$stacked, stay inside the mask',
        () {
          final w = stacked ? 40 : count * 32 + 8;
          final h = stacked ? count * 32 + 8 : 40;
          final mask = Uint8List(w * h);
          for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
              for (int i = 0; i < count; i++) {
                final dx = x - (stacked ? 20 : 20 + i * 32);
                final dy = y - (stacked ? 20 + i * 32 : 20);
                if (dx * dx / 225 + dy * dy / 225 <= 1) mask[y * w + x] = 1;
              }
              if (stacked
                  ? (x - 20).abs() <= 2 && y >= 20 && y <= h - 20
                  : (y - 20).abs() <= 2 && x >= 20 && x <= w - 20) {
                mask[y * w + x] = 1;
              }
            }
          }
          final regions = partitionBubbleInterior(mask, w, h);
          expect(regions.length, count);
          final source = image.Image(width: w, height: h);
          for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
              final value = mask[y * w + x] == 1 ? 250 : 30;
              source.setPixelRgb(x, y, value, value, value);
            }
          }
          final detected = detectBubbleLayoutRegions(
            source,
            RecognizedTextContainer(
              blockIndices: const [0],
              left: 0,
              top: 0,
              width: w.toDouble(),
              height: h.toDouble(),
            ),
          );
          expect(detected.length, count);
          for (final r in regions) {
            for (int y = r.top.toInt(); y < r.top + r.height; y++) {
              for (int x = r.left.toInt(); x < r.left + r.width; x++) {
                expect(mask[y * w + x], 1);
              }
            }
          }
        },
      );
    }
  }

  test('pixel refinement fills glyph holes and preserves a single oval', () {
    final source = image.Image(width: 120, height: 160);
    image.fill(source, color: image.ColorRgb8(35, 50, 65));
    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        if ((x - 60) * (x - 60) / 2500 + (y - 80) * (y - 80) / 4900 < 1) {
          source.setPixelRgb(x, y, 250, 250, 250);
        }
      }
    }
    image.fillRect(
      source,
      x1: 57,
      y1: 60,
      x2: 60,
      y2: 66,
      color: image.ColorRgb8(0, 0, 0),
    );
    final regions = detectBubbleLayoutRegions(
      source,
      const RecognizedTextContainer(
        blockIndices: [0],
        left: 10,
        top: 10,
        width: 100,
        height: 140,
      ),
    );
    expect(regions.length, 1);
    expect(regions.single.width, greaterThan(50));
    expect(regions.single.height, greaterThan(75));
  });

  for (final count in [2, 3, 4]) {
    test('$count areas balance text without loss at one fitting font size', () {
      final regions = [
        for (int i = 0; i < count; i++) Rect.fromLTWH(i * 100, 0, 80, 140),
      ];
      final text = '这是一段测试文字👨‍👩‍👧‍👦。' * 10;
      final entries = layoutTranslationInRegions(
        text,
        regions,
        TextDirection.ltr,
        maxFontSize: 24,
        vertical: true,
      );
      expect(entries.length, count);
      expect(entries.map((e) => e.$2).join(), text);
      expect(entries.first.$1, regions.last);
      expect(entries.map((e) => e.$3).toSet().length, 1);
      final lengths = entries.map((e) => e.$2.length).toList()..sort();
      expect(lengths.last - lengths.first, lessThanOrEqualTo(16));
      for (final (rect, chunk, font) in entries) {
        final layout = VerticalTranslationLayout(
          chunk,
          fontSize: font,
          maxHeight: rect.height - 4,
        );
        expect(layout.size.width, lessThanOrEqualTo(rect.width - 4));
        expect(layout.size.height, lessThanOrEqualTo(rect.height - 4));
        layout.dispose();
      }
    });
  }

  test('short translations, mixed sizes and old caches remain valid', () {
    final entries = layoutTranslationInRegions(
      '好👋',
      [
        const Rect.fromLTWH(0, 0, 50, 80),
        const Rect.fromLTWH(80, 0, 100, 80),
        const Rect.fromLTWH(190, 0, 50, 80),
        const Rect.fromLTWH(250, 0, 50, 80),
      ],
      TextDirection.ltr,
      maxFontSize: 20,
      vertical: false,
    );
    expect(entries.map((e) => e.$2).join(), '好👋');
    final old = RecognizedTextContainer.fromJson({
      'blockIndices': [0],
      'width': 30,
      'height': 40,
    });
    expect(old.layoutRegions, isEmpty);
    const container = RecognizedTextContainer(
      blockIndices: [0],
      left: 0,
      top: 0,
      width: 200,
      height: 200,
      layoutRegions: [TranslationLayoutRegion(10, 10, 50, 100)],
    );
    expect(
      RecognizedTextContainer.fromJson(container.toJson()).toJson(),
      container.toJson(),
    );
  });
}
